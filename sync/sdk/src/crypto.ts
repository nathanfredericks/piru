import {
  Aes256Gcm,
  CipherSuite,
  DhkemP256HkdfSha256,
  HkdfSha256,
} from "@hpke/core";
import {
  b64,
  bytes,
  check,
  decodeText,
  decodeToken,
  encodeToken,
  kindName,
  natural,
  utf8,
  uuid,
  validateHeader,
} from "./wire.js";
import type { Envelope, Grant, Header, Token, Wrapped } from "./wire.js";

const suite = new CipherSuite({
  kem: new DhkemP256HkdfSha256(),
  kdf: new HkdfSha256(),
  aead: new Aes256Gcm(),
});
const ecdsa = { name: "ECDSA", namedCurve: "P-256" };
const signatureAlg = { name: "ECDSA", hash: "SHA-256" };
export const randomBytes = (n: number) =>
  crypto.getRandomValues(new Uint8Array(n));
export type KeyMaterial = Uint8Array<ArrayBuffer>;
const subtle = crypto.subtle;

export async function keyPair() {
  const pair = await suite.kem.generateKeyPair();
  return {
    publicKey: b64(await suite.kem.serializePublicKey(pair.publicKey)),
    privateKey: b64(await suite.kem.serializePrivateKey(pair.privateKey)),
  };
}
async function jwk(raw: string) {
  return subtle.exportKey(
    "jwk",
    await suite.kem.deserializePrivateKey(bytes(raw, 32)),
  );
}
export async function publicKey(raw: string) {
  const { x, y } = await jwk(raw);
  return b64(new Uint8Array([4, ...bytes(x, 32), ...bytes(y, 32)]));
}
function info(profileID: string, grantID: string, epoch: number) {
  uuid(profileID);
  uuid(grantID);
  natural(epoch);
  return utf8(["piru-sync-key-v1", profileID, grantID, epoch].join("\n"));
}
export async function wrapKeys(
  pub: string,
  profileID: string,
  grantID: string,
  epoch: number,
  keys: KeyMaterial,
): Promise<Wrapped> {
  check(keys.length === 64, "Invalid key material");
  const recipientPublicKey = await suite.kem.deserializePublicKey(
    bytes(pub, 65),
  );
  const ctx = await suite.createSenderContext({
    recipientPublicKey,
    info: info(profileID, grantID, epoch),
  });
  return { enc: b64(ctx.enc), ct: b64(await ctx.seal(keys)) };
}
export async function unwrapKeys(
  token: Token,
  epoch: number,
  wrap: Wrapped,
): Promise<KeyMaterial> {
  const recipientKey = await suite.kem.deserializePrivateKey(
    bytes(token.boxPrivate, 32),
  );
  const ctx = await suite.createRecipientContext({
    recipientKey,
    enc: bytes(wrap.enc, 65),
    info: info(token.profileID, token.grantID, epoch),
  });
  return new Uint8Array(await ctx.open(bytes(wrap.ct, 80)));
}
export async function docID(
  indexKey: KeyMaterial,
  kind: string,
  recordID: string,
) {
  kindName(kind);
  uuid(recordID);
  check(indexKey.length === 32, "Invalid index key");
  const key = await subtle.importKey(
    "raw",
    indexKey,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return b64(await subtle.sign("HMAC", key, utf8(kind + "\n" + recordID)));
}
function aad(h: Header) {
  validateHeader(h);
  return [
    "piru-sync-v1",
    h.profileID,
    h.docID,
    h.opID,
    h.grantID,
    h.epoch,
  ].join("\n");
}
function signed(e: Omit<Envelope, "signature">) {
  return utf8([aad(e), e.nonce, e.ciphertext].join("\n"));
}
async function aes(key: KeyMaterial) {
  check(key.length === 32, "Invalid AES key");
  return subtle.importKey("raw", key, "AES-GCM", false, ["encrypt", "decrypt"]);
}
export async function sealDocument(
  h: Header,
  contentKey: KeyMaterial,
  signPrivate: string,
  plaintext: Uint8Array,
): Promise<Envelope> {
  check(
    plaintext.length > 0 && plaintext.length <= 2 * 1024 * 1024 - 16,
    "Document exceeds relay envelope limit",
  );
  const nonce = randomBytes(12);
  const ciphertext = await subtle.encrypt(
    { name: "AES-GCM", iv: nonce, additionalData: utf8(aad(h)) },
    await aes(contentKey),
    new Uint8Array(plaintext),
  );
  const entry = { ...h, nonce: b64(nonce), ciphertext: b64(ciphertext) };
  return { ...entry, signature: await signBytes(signPrivate, signed(entry)) };
}
export async function verifyEnvelope(e: Envelope, signPublic: string) {
  bytes(e.nonce, 12);
  check(
    typeof e.ciphertext === "string" &&
      e.ciphertext.length <= Math.ceil((2 * 1024 * 1024 * 4) / 3) &&
      bytes(e.ciphertext).length > 16,
    "Invalid envelope ciphertext",
  );
  const verifier = await subtle.importKey(
    "raw",
    bytes(signPublic, 65),
    ecdsa,
    false,
    ["verify"],
  );
  check(
    await subtle.verify(
      signatureAlg,
      verifier,
      bytes(e.signature, 64),
      signed(e),
    ),
    "Invalid envelope signature",
  );
}
export async function openDocument(
  e: Envelope,
  contentKey: KeyMaterial,
  signPublic: string,
) {
  await verifyEnvelope(e, signPublic);
  return new Uint8Array(
    await subtle.decrypt(
      { name: "AES-GCM", iv: bytes(e.nonce, 12), additionalData: utf8(aad(e)) },
      await aes(contentKey),
      bytes(e.ciphertext),
    ),
  );
}
async function passwordKey(password: string, salt: KeyMaterial) {
  check(password.length > 0, "Empty passphrase");
  const secret = await subtle.importKey(
    "raw",
    utf8(password),
    "PBKDF2",
    false,
    ["deriveKey"],
  );
  return subtle.deriveKey(
    { name: "PBKDF2", salt, iterations: 600000, hash: "SHA-256" },
    secret,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}
export async function encryptToken(token: string, password: string) {
  decodeToken(token);
  const salt = randomBytes(16),
    iv = randomBytes(12);
  const ct = await subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: utf8("piru-token-v1") },
    await passwordKey(password, salt),
    utf8(token),
  );
  return ["pirubox1", b64(salt), b64(iv), b64(ct)].join(".");
}
export async function decryptToken(box: string, password: string) {
  const [version, salt, nonce, ct, ...rest] = box.split(".");
  check(version === "pirubox1" && !rest.length, "Invalid token box");
  const raw = await subtle.decrypt(
    {
      name: "AES-GCM",
      iv: bytes(nonce, 12),
      additionalData: utf8("piru-token-v1"),
    },
    await passwordKey(password, bytes(salt, 16)),
    bytes(ct),
  );
  const token = decodeText(raw);
  decodeToken(token);
  return token;
}
export async function checkpointKey(t: Token) {
  const secret = await subtle.importKey(
    "raw",
    bytes(t.boxPrivate, 32),
    "HKDF",
    false,
    ["deriveKey"],
  );
  return subtle.deriveKey(
    {
      name: "HKDF",
      hash: "SHA-256",
      salt: utf8(t.profileID),
      info: utf8(
        "piru-checkpoint-v1\n" + t.grantID + "\n" + new URL(t.url).origin,
      ),
    },
    secret,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

async function signBytes(privateKey: string, message: KeyMaterial) {
  const { x, y, d } = await jwk(privateKey);
  const signer = await subtle.importKey(
    "jwk",
    { kty: "EC", crv: "P-256", x, y, d },
    ecdsa,
    false,
    ["sign"],
  );
  return b64(await subtle.sign(signatureAlg, signer, message));
}

type GrantIdentity = Pick<Grant, "id" | "scope" | "signPublic" | "boxPublic">;
async function labelContext(
  profileID: string,
  grant: GrantIdentity,
  indexKey: KeyMaterial,
) {
  uuid(profileID);
  uuid(grant.id);
  check(
    ["owner", "read", "write"].includes(grant.scope),
    "Invalid grant scope",
  );
  check(
    bytes(grant.signPublic, 65)[0] === 4 && bytes(grant.boxPublic, 65)[0] === 4,
    "Invalid grant public key",
  );
  check(indexKey.length === 32, "Invalid label index key");
  const domain = "piru-sync-grant-label-v1";
  const aad = [
    domain,
    profileID,
    grant.id,
    grant.scope,
    grant.signPublic,
    grant.boxPublic,
  ].join("\n");
  const keyMaterial = await subtle.importKey("raw", indexKey, "HKDF", false, [
    "deriveKey",
  ]);
  const key = await subtle.deriveKey(
    {
      name: "HKDF",
      salt: new Uint8Array(),
      info: utf8(domain),
      hash: "SHA-256",
    },
    keyMaterial,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
  const digest = b64(await subtle.digest("SHA-256", indexKey));
  return { key, aad: utf8(aad), message: utf8(aad + "\n" + digest) };
}
export async function sealGrantLabel(
  profileID: string,
  grant: GrantIdentity,
  indexKey: KeyMaterial,
  privateKey: string,
  label: string,
) {
  check(
    typeof label === "string" &&
      label.trim().length > 0 &&
      utf8(label).length <= 1024,
    "Invalid grant label",
  );
  check(
    (await publicKey(privateKey)) === grant.signPublic,
    "Grant signing key mismatch",
  );
  const ctx = await labelContext(profileID, grant, indexKey);
  const proof = await signBytes(privateKey, ctx.message);
  const iv = randomBytes(12);
  const ct = await subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: ctx.aad },
    ctx.key,
    utf8(JSON.stringify({ label, proof })),
  );
  return b64(new Uint8Array([...iv, ...new Uint8Array(ct)]));
}
export async function openGrantLabel(
  profileID: string,
  grant: Grant,
  indexKey: KeyMaterial,
): Promise<string> {
  const ctx = await labelContext(profileID, grant, indexKey);
  const combined = bytes(grant.labelBox);
  check(
    combined.length > 28 && combined.length <= 4096,
    "Invalid encrypted grant label",
  );
  const raw = await subtle.decrypt(
    { name: "AES-GCM", iv: combined.slice(0, 12), additionalData: ctx.aad },
    ctx.key,
    combined.slice(12),
  );
  const { label, proof } = JSON.parse(decodeText(raw));
  check(
    typeof label === "string" &&
      label.trim().length > 0 &&
      utf8(label).length <= 1024,
    "Invalid grant label",
  );
  const verifier = await subtle.importKey(
    "raw",
    bytes(grant.signPublic, 65),
    ecdsa,
    false,
    ["verify"],
  );
  check(
    await subtle.verify(signatureAlg, verifier, bytes(proof, 64), ctx.message),
    "Invalid grant label proof",
  );
  return label;
}
/** Create keys and an encrypted label for an owner to enroll via the management API. */
export async function issueGrant(
  url: string,
  profileID: string,
  scope: Grant["scope"],
  label: string,
  epoch: number,
  keys: KeyMaterial,
) {
  const [sign, box] = await Promise.all([keyPair(), keyPair()]);
  const id = crypto.randomUUID();
  const identity = {
    id,
    scope,
    signPublic: sign.publicKey,
    boxPublic: box.publicKey,
  };
  const token: Token = {
    url,
    profileID,
    grantID: id,
    bearer: b64(randomBytes(32)),
    signPrivate: sign.privateKey,
    boxPrivate: box.privateKey,
  };
  const [wrapped, labelBox] = await Promise.all([
    wrapKeys(box.publicKey, profileID, id, epoch, keys),
    sealGrantLabel(profileID, identity, keys.slice(32), sign.privateKey, label),
  ]);
  return {
    token: encodeToken(token),
    grant: { ...identity, wrapped, labelBox },
    bearer: token.bearer,
  };
}
