import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as A from "@automerge/automerge";
import {
  JournalSync,
  bytes,
  b64,
  decodeToken,
  docID,
  encodeToken,
  openDocument,
  sealDocument,
  wrapKeys,
  unwrapKeys,
  encryptToken,
  decryptToken,
  openGrantLabel,
  sealGrantLabel,
  issueGrant,
} from "../dist/index.js";

const vector = JSON.parse(
  readFileSync(new URL("../../fixtures/v1-js.json", import.meta.url)),
);
const { grant, token, recordID, kind } = vector;
const t = decodeToken(token);
const freshKeys = () => crypto.getRandomValues(new Uint8Array(64));

const dose = (amount, unit) => ({
  substance: "Fixture",
  amount,
  unit,
  route: "oral",
});
const base = {
  dose: dose(1, "mg"),
  timestamp: 1234567890,
  timeZoneIdentifier: null,
  medSlotMinutes: null,
  notes: "before",
  tags: [],
  isBackgroundMed: false,
  hadGrapefruit: null,
  mealRaw: null,
};

function relay() {
  const pages = new Map([[1, { epoch: 1, grants: [structuredClone(grant)] }]]);
  const log = [],
    posts = [];
  const server = { log, posts, pages, epoch: 1, loseReply: false };
  server.fetch = async (url, opts) => {
    assert.equal(url.origin, new URL(t.url).origin);
    assert.ok(url.pathname.startsWith("/v1/profiles/" + t.profileID));
    assert.equal(opts.headers.Authorization, "Bearer " + t.bearer);
    assert.equal(opts.redirect, "error");
    if (url.pathname.endsWith("/grants"))
      return Response.json(
        pages.get(Number(url.searchParams.get("epoch") ?? server.epoch)),
      );
    if (opts.method === "GET") {
      const after = Number(url.searchParams.get("after"));
      const changes = log.filter((c) => c.seq > after).slice(0, 2);
      return Response.json({
        changes,
        cursor: changes.at(-1)?.seq ?? after,
        hasMore: after + changes.length < log.length,
      });
    }
    const e = JSON.parse(opts.body);
    posts.push(e);
    assert.deepEqual(
      Object.keys(e).sort(),
      Object.keys(vector.envelope).sort(),
    );
    assert.equal(e.epoch, server.epoch);
    let change = log.find((c) => c.envelope.opID === e.opID);
    if (change) assert.deepEqual(change.envelope, e);
    else {
      change = { seq: log.length + 1, envelope: e };
      log.push(change);
    }
    if (server.loseReply) {
      server.loseReply = false;
      throw new Error("disconnected");
    }
    return Response.json({ seq: change.seq });
  };
  const open = (options = {}) =>
    JournalSync.open(token, { fetch: server.fetch, ...options });
  return { ...server, server, open };
}

test("wire vector opens with HPKE, verifies, decrypts and restores scalar fields", async () => {
  assert.equal(encodeToken(t), token);
  const keys = await unwrapKeys(t, 1, grant.wrapped);
  assert.equal(b64(keys.slice(0, 32)), vector.contentKey);
  assert.equal(b64(keys.slice(32)), vector.indexKey);
  assert.equal(
    await docID(keys.slice(32), kind, recordID),
    vector.envelope.docID,
  );
  const raw = await openDocument(
    vector.envelope,
    keys.slice(0, 32),
    grant.signPublic,
  );
  assert.equal(b64(raw), vector.document);
  const doc = A.load(raw);
  assert.ok(doc.kind instanceof A.ImmutableString);
  assert.equal(doc.kind.val, kind);
  for (const [k, v] of Object.entries(vector.fields))
    assert.deepEqual(JSON.parse(doc[k].val), v);
  const other = await wrapKeys(
    grant.boxPublic,
    t.profileID,
    t.grantID,
    2,
    keys,
  );
  assert.deepEqual(await unwrapKeys(t, 2, other), keys);
  await assert.rejects(unwrapKeys(t, 1, other));
  await assert.rejects(
    openDocument(
      { ...vector.envelope, opID: crypto.randomUUID() },
      keys.slice(0, 32),
      grant.signPublic,
    ),
  );
  await assert.rejects(
    openDocument(vector.envelope, freshKeys().slice(0, 32), grant.signPublic),
  );
});

test("offline branches converge on one dose tuple, retain disjoint notes, tombstone wins", async () => {
  const { open, log } = relay();
  const left = await open();
  await left.write(kind, recordID, base);
  await left.sync();
  const right = await open();
  await left.write(kind, recordID, { dose: dose(3, "g") });
  await right.write(kind, recordID, { dose: dose(4, "mg"), notes: "edited" });
  await Promise.all([left.sync(), right.sync()]);
  const a = left.read(kind, recordID).fields;
  assert.deepEqual(a, right.read(kind, recordID).fields);
  assert.ok(
    [dose(3, "g"), dose(4, "mg")].some(
      (q) => JSON.stringify(q) === JSON.stringify(a.dose),
    ),
  );
  assert.equal(a.notes, "edited");
  await left.delete(kind, recordID);
  await right.write(kind, recordID, { notes: "offline" });
  await right.sync();
  assert.deepEqual(right.list(kind), []);
  assert.equal((await open()).read(kind, recordID), undefined);
  await assert.rejects(
    right.write(kind, recordID, { notes: "again" }),
    /deleted/,
  );
  assert.equal(log.length, 5);
});

test("persist before POST, recover a lost acknowledgement after restart, exact retry", async () => {
  const { open, server, log, posts } = relay();
  let checkpoint;
  const client = await open({
    saveCheckpoint: async (cp) => {
      checkpoint = cp;
    },
  });
  server.loseReply = true;
  await assert.rejects(
    client.write(kind, recordID, { ...base, notes: "a private note" }),
    /disconnected/,
  );
  const restored = await open({ checkpoint });
  assert.equal(restored.read(kind, recordID).fields.notes, "a private note");
  assert.equal(log.length, 1);
  assert.equal(posts.length, 2);
  assert.deepEqual(posts[0], posts[1]);
  assert.equal(checkpoint.includes("a private note"), false);
  const damaged = checkpoint.slice(0, -5) + "AAAAA";
  await assert.rejects(open({ checkpoint: damaged }));
});

test("read permissions, stable index key, signer scope and historic epoch checks", async () => {
  const { open, server, log, pages } = relay();
  await (await open()).write(kind, recordID, { ...base, notes: "fixture" });
  const old = await unwrapKeys(t, 1, grant.wrapped);
  const rotated = freshKeys();
  rotated.set(old.slice(32), 32);
  pages.set(2, {
    epoch: 2,
    grants: [
      {
        ...grant,
        scope: "read",
        wrapped: await wrapKeys(
          grant.boxPublic,
          t.profileID,
          t.grantID,
          2,
          rotated,
        ),
      },
    ],
  });
  const readerGrant = pages.get(2).grants[0];
  readerGrant.labelBox = await sealGrantLabel(
    t.profileID,
    readerGrant,
    old.slice(32),
    t.signPrivate,
    "Reader",
  );
  server.epoch = 2;
  const reader = await open();
  assert.equal(reader.read(kind, recordID).fields.notes, "fixture");
  await assert.rejects(reader.delete(kind, recordID), /Read-only/);
  pages.get(1).grants[0] = { ...readerGrant, wrapped: grant.wrapped };
  await assert.rejects(open(), /Unauthorized/);
  pages.get(1).grants[0] = grant;
  pages.get(1).epoch = 2;
  await assert.rejects(open(), /epoch/);
  pages.get(1).epoch = 1;
  pages.get(2).grants[0].wrapped = await wrapKeys(
    grant.boxPublic,
    t.profileID,
    t.grantID,
    2,
    freshKeys(),
  );
  await assert.rejects(open());
});

test("reject malformed tokens, reserved fields, invalid identity and wire tampering", async () => {
  const { open, log } = relay();
  assert.throws(() => decodeToken(token + "="));
  assert.throws(() => encodeToken({ ...t, url: "http://example.org/v1" }));
  assert.throws(() => encodeToken({ ...t, grantID: "BAD" }));
  const client = await open();
  await assert.rejects(client.write(kind, recordID, { kind: "x" }), /Reserved/);
  await assert.rejects(
    client.write(kind, recordID, { notes: undefined }),
    /JSON/,
  );
  log.push({
    seq: 1,
    envelope: { ...vector.envelope, profileID: crypto.randomUUID() },
  });
  await assert.rejects(client.sync(), /profile/);
  assert.equal(client.cursor, 0);
  const { nonce, ciphertext, signature, ...h } = vector.envelope;
  log[0].envelope = await sealDocument(
    { ...h, docID: b64(freshKeys().slice(0, 32)) },
    bytes(vector.contentKey),
    t.signPrivate,
    bytes(vector.document),
  );
  await assert.rejects(client.sync(), /identity/);
  assert.equal(client.cursor, 0);
});

test("passphrase-encrypted compound token round trip", async () => {
  const box = await encryptToken(token, "local synthetic test");
  assert.equal(await decryptToken(box, "local synthetic test"), token);
  await assert.rejects(decryptToken(box, "wrong passphrase"));
});

test("Swift CryptoKit rewraps keys, edits the JS Automerge document and signs a new envelope", async () => {
  const swift = JSON.parse(
    readFileSync(new URL("../../fixtures/v1-swift.json", import.meta.url)),
  );
  const keys = await unwrapKeys(
    decodeToken(swift.token),
    swift.envelope.epoch,
    swift.grant.wrapped,
  );
  assert.equal(b64(keys.slice(0, 32)), vector.contentKey);
  assert.equal(b64(keys.slice(32)), vector.indexKey);
  assert.equal(swift.envelope.docID, vector.envelope.docID);
  const raw = await openDocument(
    swift.envelope,
    keys.slice(0, 32),
    swift.grant.signPublic,
  );
  assert.equal(b64(raw), swift.document);
  const original = A.load(bytes(vector.document)),
    edited = A.load(raw);
  assert.ok(A.getChanges(original, edited).length > 0);
  const joined = A.merge(original, edited);
  assert.deepEqual(A.getHeads(joined), A.getHeads(edited));
  assert.equal(joined.notes.val, JSON.stringify("from Swift"));
});

test("directory validates every grant's signed label and rejects substitution, duplicates and scope changes", async () => {
  const { open, pages } = relay();
  const keys = await unwrapKeys(t, 1, grant.wrapped);
  const issued = await issueGrant(
    t.url,
    t.profileID,
    "write",
    "External writer",
    1,
    keys,
  );
  assert.equal(
    await openGrantLabel(t.profileID, issued.grant, keys.slice(32)),
    "External writer",
  );
  const { wrapped, ...signer } = issued.grant;
  pages.get(1).grants.push(signer);
  await open();
  pages.get(1).grants.push(signer);
  await assert.rejects(open(), /entry/);
  pages.get(1).grants.pop();
  signer.scope = "owner";
  await assert.rejects(open());
  signer.scope = "write";
  pages.get(1).grants[0].wrapped = await wrapKeys(
    grant.boxPublic,
    t.profileID,
    t.grantID,
    1,
    freshKeys(),
  );
  await assert.rejects(open());
  assert.equal(
    await openGrantLabel(t.profileID, grant, keys.slice(32)),
    "Interop owner",
  );
  // Someone able to encrypt a replacement label still needs the grant's signature.
  const aad = [
    "piru-sync-grant-label-v1",
    t.profileID,
    grant.id,
    grant.scope,
    grant.signPublic,
    grant.boxPublic,
  ].join("\n");
  const utf = (s) => new TextEncoder().encode(s);
  const secret = await crypto.subtle.importKey(
    "raw",
    keys.slice(32),
    "HKDF",
    false,
    ["deriveKey"],
  );
  const k = await crypto.subtle.deriveKey(
    {
      name: "HKDF",
      hash: "SHA-256",
      salt: new Uint8Array(),
      info: utf("piru-sync-grant-label-v1"),
    },
    secret,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt"],
  );
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: utf(aad) },
    k,
    utf(JSON.stringify({ label: "Impostor", proof: b64(new Uint8Array(64)) })),
  );
  await assert.rejects(
    openGrantLabel(
      t.profileID,
      {
        ...grant,
        labelBox: b64(new Uint8Array([...iv, ...new Uint8Array(ct)])),
      },
      keys.slice(32),
    ),
    /proof/,
  );
});

test("ambiguous write across rotation replays first and reseals only if the receipt is absent", async () => {
  for (const committed of [true, false]) {
    const { open, server, log, posts, pages } = relay();
    const client = await open();
    server.loseReply = true;
    await assert.rejects(client.write(kind, recordID, base), /disconnected/);
    if (!committed) log.length = 0;
    const keys = freshKeys();
    keys.set(bytes(vector.indexKey), 32);
    pages.set(2, {
      epoch: 2,
      grants: [
        {
          ...grant,
          wrapped: await wrapKeys(
            grant.boxPublic,
            t.profileID,
            t.grantID,
            2,
            keys,
          ),
        },
      ],
    });
    server.epoch = 2;
    const restored = await open({ checkpoint: await client.checkpoint() });
    assert.equal(restored.read(kind, recordID).fields.notes, base.notes);
    assert.equal(log.length, 1);
    assert.equal(posts.length, committed ? 1 : 2);
    assert.equal(log[0].envelope.opID, posts[0].opID);
    assert.equal(log[0].envelope.epoch, committed ? 1 : 2);
  }
});

test("journal rejects incomplete Swift dose groups and feed gaps without advancing", async () => {
  const { open, log } = relay();
  const client = await open();
  await assert.rejects(
    client.write(kind, recordID, { ...base, dose: { amount: 10, unit: "mg" } }),
    /dose group/,
  );
  await assert.rejects(
    client.write(kind, recordID, { dose: base.dose }),
    /dose fields/,
  );
  assert.equal(log.length, 0);
  log.push({ seq: 2, envelope: vector.envelope });
  await assert.rejects(client.sync(), /incomplete feed/);
  assert.equal(client.cursor, 0);
});

test("checkpoint replay refreshes a same-epoch directory once for a newly enrolled signer", async () => {
  const { open, fetch: request, log, pages } = relay();
  const client = await open();
  await client.write(kind, recordID, base);
  await client.sync();
  const checkpoint = await client.checkpoint();

  const keys = await unwrapKeys(t, 1, grant.wrapped);
  const issued = await issueGrant(
    t.url,
    t.profileID,
    "write",
    "New writer",
    1,
    keys,
  );
  const writer = decodeToken(issued.token);
  const original = log[0].envelope;
  const raw = await openDocument(original, keys.slice(0, 32), grant.signPublic);
  let doc = A.load(raw);
  const changes = [];
  for (const note of ["first", "second", "third"]) {
    doc = A.change(doc, (draft) => {
      draft.notes = new A.ImmutableString(JSON.stringify(note));
    });
    const header = {
      profileID: t.profileID,
      grantID: writer.grantID,
      epoch: 1,
      docID: original.docID,
      opID: crypto.randomUUID(),
    };
    changes.push(
      await sealDocument(
        header,
        keys.slice(0, 32),
        writer.signPrivate,
        A.save(doc),
      ),
    );
  }

  const directories = [];
  const restored = await open({
    checkpoint,
    fetch: async (url, opts) => {
      if (url.pathname.endsWith("/grants")) directories.push(url.search);
      if (url.pathname.endsWith("/changes") && log.length === 1) {
        // The feed sees an enrollment committed after the directory request.
        const { wrapped, ...signer } = issued.grant;
        pages.get(1).grants.push(signer);
        for (const envelope of changes)
          log.push({ seq: log.length + 1, envelope });
      }
      return request(url, opts);
    },
  });
  assert.equal(restored.cursor, 4);
  assert.equal(restored.read(kind, recordID).fields.notes, "third");
  assert.deepEqual(directories, ["", "?epoch=1"]);
});

test("unrecognized signer gets one directory lookup and leaves the replay cursor intact", async () => {
  const { open, fetch: request, log } = relay();
  let refreshes = 0;
  let revoked = false;
  const client = await open({
    fetch: async (url, opts) => {
      if (url.pathname.endsWith("/grants") && url.search) {
        refreshes++;
        if (revoked) return new Response(null, { status: 401 });
      }
      return request(url, opts);
    },
  });
  log.push({
    seq: 1,
    envelope: { ...vector.envelope, grantID: crypto.randomUUID() },
  });
  await assert.rejects(client.sync(), /Unauthorized envelope signer/);
  assert.equal(client.cursor, 0);
  assert.equal(refreshes, 1);

  revoked = true;
  await assert.rejects(client.sync(), { status: 401 });
  assert.equal(client.cursor, 0);
  assert.equal(refreshes, 2);
});

test("disconnect after authorizing a write leaves a durable pending operation for restart", async () => {
  const { open, fetch: request, posts } = relay();
  let checkpoint;
  let disconnect = false;
  let authorized = false;
  const client = await open({
    saveCheckpoint: async (value) => {
      checkpoint = value;
    },
    fetch: async (url, opts) => {
      if (disconnect && authorized) throw new Error("offline");
      if (disconnect && url.pathname.endsWith("/grants")) authorized = true;
      return request(url, opts);
    },
  });
  const before = checkpoint;
  disconnect = true;
  await assert.rejects(client.write(kind, recordID, base), /offline/);
  assert.notEqual(checkpoint, before);
  assert.equal(posts.length, 0);
  const restored = await open({ checkpoint });
  assert.equal(posts.length, 1);
  assert.equal(restored.read(kind, recordID).fields.notes, base.notes);
});
