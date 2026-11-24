import { before, after, test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import {
  randomBytes,
  randomUUID,
  createHash,
  generateKeyPairSync,
  sign,
} from "node:crypto";
import { Miniflare } from "miniflare";
import { build } from "esbuild";
import { SignJWT } from "jose";

const b64 = (n) => randomBytes(n).toString("base64url");
const id = randomUUID;
const digest = (s) => createHash("sha256").update(s).digest("hex");
const apple = generateKeyPairSync("rsa", { modulusLength: 2048 });
const jwk = {
  ...apple.publicKey.export({ format: "jwk" }),
  kid: "test",
  alg: "RS256",
  use: "sig",
};
let mf, db, bucket;
before(async () => {
  const script = await build({
    entryPoints: ["src/index.ts"],
    bundle: true,
    format: "esm",
    platform: "browser",
    write: false,
  });
  mf = new Miniflare({
    modules: true,
    script: script.outputFiles[0].text,
    compatibilityDate: "2026-06-01",
    d1Databases: ["DB"],
    r2Buckets: ["BLOBS"],
    bindings: { APPLE_AUDIENCE: "test.piru" },
    outboundService(request) {
      assert.equal(request.url, "https://appleid.apple.com/auth/keys");
      return Response.json({ keys: [jwk] });
    },
  });
  db = await mf.getD1Database("DB");
  bucket = await mf.getR2Bucket("BLOBS");
  const migration = await readFile("migrations/0001_sync.sql", "utf8");
  const statements = migration
    .replace(/^--.*$/gm, "")
    .trim()
    .split(/;\s*\n/)
    .map((s) => s.trim())
    .filter(Boolean);
  await db.batch(statements.map((s) => db.prepare(s)));
});
after(async () => {
  await mf?.dispose();
});
async function call(path, method = "GET", body, token, extras = {}) {
  const headers = { "Content-Type": "application/json", ...extras };
  if (token) headers.Authorization = "Bearer " + token;
  const r = await mf.dispatchFetch("http://local/v1/" + path, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: r.status, data: await r.json() };
}
function ok(r) {
  assert.equal(r.status, 200, JSON.stringify(r.data));
  return r.data;
}
async function token(nonce, subject, audience = "test.piru") {
  return new SignJWT({ nonce: digest(nonce) })
    .setProtectedHeader({ alg: "RS256", kid: "test" })
    .setSubject(subject)
    .setAudience(audience)
    .setIssuer("https://appleid.apple.com")
    .setIssuedAt()
    .setExpirationTime("5m")
    .sign(apple.privateKey);
}
async function login(subject = id()) {
  const { nonce } = ok(await call("auth/nonce", "POST"));
  return ok(
    await call("auth/apple", "POST", {
      nonce,
      identityToken: await token(nonce, subject),
    }),
  );
}
function keys() {
  const k = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const jwk = k.publicKey.export({ format: "jwk" });
  return {
    privateKey: k.privateKey,
    raw: Buffer.concat([
      Buffer.from([4]),
      Buffer.from(jwk.x, "base64url"),
      Buffer.from(jwk.y, "base64url"),
    ]).toString("base64url"),
  };
}
function wrap() {
  return { enc: keys().raw, ct: b64(80) };
}
function device(scope = "owner") {
  const k = keys();
  return {
    sign: k.privateKey,
    bearer: b64(32),
    grant: {
      id: id(),
      scope,
      signPublic: k.raw,
      boxPublic: keys().raw,
      labelBox: b64(32),
      wrapped: wrap(),
    },
  };
}
const header = (owner, key = id()) => ({
  "X-Owner-Bearer": owner.bearer,
  "Idempotency-Key": key,
});
async function profile() {
  const auth = await login(),
    p = id(),
    owner = device(),
    recoveryBox = b64(64);
  const bootstrap = {
    profileID: p,
    grant: owner.grant,
    bearer: owner.bearer,
    recoveryBox,
  };
  const headers = { "Idempotency-Key": id() };
  ok(await call("profiles", "POST", bootstrap, auth.session, headers));
  ok(await call("profiles", "POST", bootstrap, auth.session, headers));
  return { auth, p, owner, recoveryBox, route: "profiles/" + p };
}
function envelope(p, owner, epoch = 1) {
  const e = {
    profileID: p,
    docID: b64(32),
    opID: id(),
    grantID: owner.grant.id,
    epoch,
    nonce: b64(12),
    ciphertext: b64(128),
  };
  e.signature = sign(
    "sha256",
    Buffer.from(
      [
        "piru-sync-v1",
        p,
        e.docID,
        e.opID,
        e.grantID,
        epoch,
        e.nonce,
        e.ciphertext,
      ].join("\n"),
    ),
    { key: owner.sign, dsaEncoding: "ieee-p1363" },
  ).toString("base64url");
  return e;
}
async function enroll(f, dev, epoch = 1, history = []) {
  return call(
    f.route + "/grants",
    "POST",
    { grant: dev.grant, bearer: dev.bearer, epoch, history },
    f.auth.session,
    header(f.owner),
  );
}

test("Apple nonce, audience, single use and stable account binding", async () => {
  const { nonce } = ok(await call("auth/nonce", "POST")),
    sub = id();
  const bad = await token(nonce, sub, "wrong");
  assert.equal(
    (await call("auth/apple", "POST", { nonce, identityToken: bad })).status,
    401,
  );
  const body = { nonce, identityToken: await token(nonce, sub) };
  const replies = await Promise.all([
    call("auth/apple", "POST", body),
    call("auth/apple", "POST", body),
  ]);
  assert.deepEqual(replies.map((r) => r.status).sort(), [200, 401]);
  assert.equal(
    (await login(sub)).accountID,
    replies.find((r) => r.status === 200).data.accountID,
  );
});

test("recovery and management bind both the Apple account and an active profile owner", async () => {
  const f = await profile(),
    other = await profile(),
    reader = device("read");
  assert.deepEqual(
    ok(await call("profiles", "GET", undefined, f.auth.session)).profiles,
    [{ profileID: f.p, epoch: 1, anchorGrantID: f.owner.grant.id }],
  );
  assert.equal(
    ok(await call(f.route + "/recovery", "GET", undefined, f.auth.session))
      .recoveryBox,
    f.recoveryBox,
  );
  assert.equal(
    (await call(f.route + "/recovery", "GET", undefined, other.auth.session))
      .status,
    404,
  );
  const update = { epoch: 1, recoveryBox: b64(64) },
    headers = header(f.owner);
  for (const [session, owner] of [
    [other.auth.session, f.owner],
    [f.auth.session, other.owner],
  ]) {
    assert.equal(
      (await call(f.route + "/recovery", "PUT", update, session, header(owner)))
        .status,
      403,
    );
  }
  ok(await enroll(f, reader));
  assert.equal(
    (
      await call(
        f.route + "/recovery",
        "PUT",
        update,
        f.auth.session,
        header(reader),
      )
    ).status,
    403,
  );
  assert.deepEqual(
    ok(
      await call(f.route + "/recovery", "PUT", update, f.auth.session, headers),
    ),
    { epoch: 1 },
  );
  ok(await call(f.route + "/recovery", "PUT", update, f.auth.session, headers));
  assert.equal(
    (
      await call(
        f.route + "/recovery",
        "PUT",
        { ...update, recoveryBox: b64(70) },
        f.auth.session,
        headers,
      )
    ).status,
    409,
  );
});

test("signed append, concurrent duplicate receipts, binding, tamper rejection and missing R2 data", async () => {
  const f = await profile(),
    other = await profile(),
    writer = device("write"),
    reader = device("read");
  ok(await enroll(f, writer));
  ok(await enroll(f, reader));
  const e = envelope(f.p, writer);
  const send = (body, token = writer.bearer) =>
    call(f.route + "/changes", "POST", body, token);
  const pairs = await Promise.all([send(e), send(e)]);
  assert.deepEqual(pairs.map(ok), [{ seq: 1 }, { seq: 1 }]);
  assert.equal((await send({ ...e, signature: b64(64) })).status, 403);
  assert.equal((await send({ ...e, docID: e.docID + "=" })).status, 400);
  assert.equal((await send(e, f.owner.bearer)).status, 403);
  assert.equal((await send(envelope(f.p, reader), reader.bearer)).status, 403);
  assert.equal((await send(envelope(other.p, writer))).status, 403);
  const changed = { ...e, ciphertext: b64(64) };
  changed.signature = sign(
    "sha256",
    Buffer.from(
      [
        "piru-sync-v1",
        f.p,
        changed.docID,
        e.opID,
        e.grantID,
        1,
        e.nonce,
        changed.ciphertext,
      ].join("\n"),
    ),
    { key: writer.sign, dsaEncoding: "ieee-p1363" },
  ).toString("base64url");
  assert.equal((await send(changed)).status, 409);
  const page = ok(
    await call(f.route + "/changes?after=0", "GET", undefined, reader.bearer),
  );
  assert.deepEqual(page, {
    changes: [{ seq: 1, envelope: e }],
    cursor: 1,
    hasMore: false,
  });
  assert.equal(
    (await call(f.route + "/changes", "GET", undefined, other.owner.bearer))
      .status,
    403,
  );
  const blob = await db
    .prepare("SELECT blob FROM changes WHERE profile=?")
    .bind(f.p)
    .first("blob");
  await bucket.delete(blob);
  assert.equal(
    (await call(f.route + "/changes", "GET", undefined, reader.bearer)).status,
    503,
  );
});

test("atomic rotation retains historic signers, scopes wraps, and supports secondary owners", async () => {
  const f = await profile(),
    admin = device(),
    writer = device("write");
  ok(await enroll(f, admin));
  ok(await enroll(f, writer));
  const e = envelope(f.p, writer);
  ok(await call(f.route + "/changes", "POST", e, writer.bearer));
  const rotate = {
    epoch: 1,
    revoke: [writer.grant.id],
    wraps: [f.owner, admin].map((d) => ({
      grantID: d.grant.id,
      wrapped: wrap(),
    })),
    recoveryBox: b64(64),
  };
  const send = (body, h = header(admin)) =>
    call(f.route + "/rotate", "POST", body, f.auth.session, h);
  assert.equal(
    (await send({ ...rotate, wraps: rotate.wraps.slice(1) })).status,
    409,
  );
  assert.equal(
    (
      await send({
        ...rotate,
        revoke: [f.owner.grant.id],
        wraps: [{ grantID: writer.grant.id, wrapped: wrap() }, rotate.wraps[1]],
      })
    ).status,
    409,
  );
  assert.equal(
    ok(await call(f.route + "/recovery", "GET", undefined, f.auth.session))
      .epoch,
    1,
  );
  const key = header(admin);
  assert.deepEqual(ok(await send(rotate, key)), { epoch: 2 });
  ok(await send(rotate, key));
  assert.equal((await send(rotate)).status, 409);
  assert.equal(
    (await call(f.route + "/changes", "POST", e, writer.bearer)).status,
    403,
  );
  assert.equal(
    (
      await call(
        f.route + "/changes",
        "POST",
        envelope(f.p, admin),
        admin.bearer,
      )
    ).status,
    409,
  );
  assert.equal(
    (await call(f.route + "/grants?epoch=1", "GET", undefined, writer.bearer))
      .status,
    403,
  );
  const reader = device("read"),
    historic = wrap();
  ok(await enroll(f, reader, 2, [{ epoch: 1, wrapped: historic }]));
  const old = ok(
    await call(f.route + "/grants?epoch=1", "GET", undefined, reader.bearer),
  );
  assert.deepEqual(
    old.grants.filter((g) => g.wrapped).map((g) => g.wrapped),
    [historic],
  );
  assert.equal(
    old.grants.find((g) => g.id === writer.grant.id).signPublic,
    writer.grant.signPublic,
  );
  const current = ok(
    await call(f.route + "/grants", "GET", undefined, admin.bearer),
  );
  assert(!current.grants.some((g) => g.id === writer.grant.id));
  assert.deepEqual(
    current.grants.filter((g) => g.wrapped).map((g) => g.wrapped),
    [rotate.wraps[1].wrapped],
  );
  assert.equal(
    ok(await call(f.route + "/recovery", "GET", undefined, f.auth.session))
      .recoveryBox,
    rotate.recoveryBox,
  );
});

test("ordered pagination and reusable R2 checkpoint retain every op", async () => {
  const f = await profile();
  const path = f.route + "/changes";
  const envs = Array.from({ length: 18 }, () => envelope(f.p, f.owner));
  for (const [i, e] of envs.entries())
    assert.equal(ok(await call(path, "POST", e, f.owner.bearer)).seq, i + 1);
  const read = (q) => call(path + q, "GET", undefined, f.owner.bearer);
  const page = ok(await read("?after=0"));
  assert.equal(page.hasMore, true);
  assert.equal(page.cursor, 16);
  assert.deepEqual(
    page.changes.map((c) => c.envelope),
    envs.slice(0, 16),
  );
  assert(await bucket.head(f.p + "/checkpoints/16"));
  assert.deepEqual(ok(await read("?after=0")), page);
  assert.deepEqual(
    ok(await read("?after=16")).changes.map((c) => c.seq),
    [17, 18],
  );
  assert.deepEqual(ok(await read("?after=18")), {
    changes: [],
    cursor: 18,
    hasMore: false,
  });
  assert.equal((await read("?after=-1")).status, 400);
  assert.equal((await read("?limit=101")).status, 400);
});

test("deletion cuts off all profile data and supports receipt replay and R2 purge", async () => {
  const f = await profile(),
    headers = header(f.owner);
  ok(
    await call(
      f.route + "/changes",
      "POST",
      envelope(f.p, f.owner),
      f.owner.bearer,
    ),
  );
  const del = () => call(f.route, "DELETE", undefined, f.auth.session, headers);
  assert.deepEqual(ok(await del()), { deleted: true });
  ok(await del());
  assert.equal(
    (await call(f.route + "/changes", "GET", undefined, f.owner.bearer)).status,
    403,
  );
  assert.equal(
    (await call(f.route + "/recovery", "GET", undefined, f.auth.session))
      .status,
    404,
  );
  await db
    .prepare("UPDATE deletions SET purge_after=0 WHERE profile=?")
    .bind(f.p)
    .run();
  const worker = await mf.getWorker();
  await worker.scheduled();
  assert.equal((await bucket.list({ prefix: f.p + "/" })).objects.length, 0);
});

test("SDK v1 golden envelope is accepted unchanged by the relay", async () => {
  const vector = JSON.parse(await readFile("../fixtures/v1-js.json", "utf8"));
  const credential = JSON.parse(
    Buffer.from(vector.token.slice("piru1.".length), "base64url"),
  );
  const auth = await login(),
    grant = vector.grant,
    route = "profiles/" + vector.profileID;
  ok(
    await call(
      "profiles",
      "POST",
      {
        profileID: vector.profileID,
        grant,
        bearer: credential.bearer,
        recoveryBox: b64(64),
      },
      auth.session,
      { "Idempotency-Key": id() },
    ),
  );
  const stored = await db
    .prepare("SELECT digest FROM grants WHERE profile=? AND id=?")
    .bind(vector.profileID, grant.id)
    .first("digest");
  assert.equal(stored, digest(Buffer.from(credential.bearer, "base64url")));
  ok(
    await call(route + "/changes", "POST", vector.envelope, credential.bearer),
  );
  assert.deepEqual(
    ok(await call(route + "/changes", "GET", undefined, credential.bearer))
      .changes,
    [{ seq: 1, envelope: vector.envelope }],
  );
});

test("a racing enrollment and rotation cannot leave any active grant without the new wrap", async () => {
  const f = await profile(),
    addition = device("read");
  const rotation = {
    epoch: 1,
    revoke: [],
    wraps: [{ grantID: f.owner.grant.id, wrapped: wrap() }],
    recoveryBox: b64(64),
  };
  const raced = await Promise.all([
    enroll(f, addition),
    call(
      f.route + "/rotate",
      "POST",
      rotation,
      f.auth.session,
      header(f.owner),
    ),
  ]);
  assert.deepEqual(raced.map((r) => r.status).sort(), [200, 409]);
  const directory = ok(
    await call(f.route + "/grants", "GET", undefined, f.owner.bearer),
  );
  if (directory.epoch === 1) {
    assert(directory.grants.some((g) => g.id === addition.grant.id));
  } else {
    assert.equal(directory.epoch, 2);
    assert.deepEqual(
      directory.grants.map((g) => g.id),
      [f.owner.grant.id],
    );
  }
});

test("an expired nonce or account session cannot authorize operations", async () => {
  const { nonce } = ok(await call("auth/nonce", "POST"));
  await db
    .prepare("UPDATE challenges SET expires=0 WHERE nonce_hash=?")
    .bind(digest(nonce))
    .run();
  assert.equal(
    (
      await call("auth/apple", "POST", {
        nonce,
        identityToken: await token(nonce, id()),
      })
    ).status,
    401,
  );
  const identity = await login();
  await db
    .prepare("UPDATE sessions SET expires=0 WHERE account_id=?")
    .bind(identity.accountID)
    .run();
  assert.equal(
    (await call("profiles", "GET", undefined, identity.session)).status,
    401,
  );
});

test("failed D1 append leaves no feed row and cleanup removes only the abandoned R2 object", async () => {
  const f = await profile();
  const e = envelope(f.p, f.owner);
  const send = () => call(f.route + "/changes", "POST", e, f.owner.bearer);
  await db
    .prepare(
      "CREATE TRIGGER interrupt_append BEFORE INSERT ON changes BEGIN SELECT RAISE(ABORT,'interrupted test write'); END",
    )
    .run();
  try {
    assert.equal((await send()).status, 503);
    assert.deepEqual(
      ok(await call(f.route + "/changes", "GET", undefined, f.owner.bearer))
        .changes,
      [],
    );
  } finally {
    await db.prepare("DROP TRIGGER interrupt_append").run();
  }
  const abandoned = await db
    .prepare("SELECT blob FROM uploads WHERE blob LIKE ?")
    .bind(f.p + "/%")
    .first("blob");
  assert(await bucket.head(abandoned));
  assert.deepEqual(ok(await send()), { seq: 1 });
  await db
    .prepare("UPDATE uploads SET expires=0 WHERE blob=?")
    .bind(abandoned)
    .run();
  await (await mf.getWorker()).scheduled();
  assert.equal(await bucket.head(abandoned), null);
  assert.deepEqual(
    ok(await call(f.route + "/changes", "GET", undefined, f.owner.bearer))
      .changes,
    [{ seq: 1, envelope: e }],
  );
});
