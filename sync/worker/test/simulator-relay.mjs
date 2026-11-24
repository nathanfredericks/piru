// Local-only, in-memory relay and rendezvous for two simulator test hosts.
import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, randomUUID } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { setTimeout as sleep } from "node:timers/promises";
import { build } from "esbuild";
import { SignJWT } from "jose";
import { Miniflare } from "miniflare";
import { JournalSync } from "../../sdk/dist/index.js";

const key = generateKeyPairSync("rsa", { modulusLength: 2048 });
const audience = "simulator.piru";
const bundle = await build({ entryPoints: ["src/index.ts"], write: false, platform: "browser", bundle: true, format: "esm" });
const mf = new Miniflare({
  modules: true, script: bundle.outputFiles[0].text, compatibilityDate: "2026-06-01",
  host: "127.0.0.1", port: 0, d1Databases: ["DB"], r2Buckets: ["BLOBS"],
  bindings: { APPLE_AUDIENCE: audience },
  outboundService(req) {
    assert.equal(req.url, "https://appleid.apple.com/auth/keys");
    return Response.json({ keys: [{ ...key.publicKey.export({ format: "jwk" }), alg: "RS256", kid: "test" }] });
  },
});
const db = await mf.getD1Database("DB");
const sql = await readFile("migrations/0001_sync.sql", "utf8");
await db.batch(sql.replace(/^--.*$/gm, "").trim().split(/;\s*\n/).filter(s => s.trim()).map(s => db.prepare(s)));
const origin = (await mf.ready).origin;
async function post(path, body) {
  const response = await fetch(origin + "/v1/" + path, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: body && JSON.stringify(body),
  });
  assert.equal(response.status, 200);
  return response.json();
}
const { nonce } = await post("auth/nonce");
const jwt = await new SignJWT({ nonce: createHash("sha256").update(nonce).digest("hex") })
  .setProtectedHeader({ alg: "RS256", kid: "test" }).setSubject(randomUUID()).setAudience(audience)
  .setIssuer("https://appleid.apple.com").setIssuedAt().setExpirationTime("5m").sign(key.privateKey);
const slots = new Map([["session", { ...await post("auth/apple", { nonce, identityToken: jwt }), url: origin }]]);
const prefix = "/" + randomUUID() + "/";
const server = createServer(async (req, res) => {
  if (req.headers.origin || !req.url?.startsWith(prefix)) { res.writeHead(403).end(); return; }
  const name = req.url.slice(prefix.length);
  if (req.method === "POST") {
    let raw = "";
    for await (const part of req) raw += part;
    slots.set(name, JSON.parse(raw));
  }
  res.writeHead(slots.has(name) ? 200 : 404, { "Cache-Control": "no-store", "Content-Type": "application/json" });
  res.end(JSON.stringify(slots.get(name) ?? {}));
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
await writeFile(process.argv[2], "http://127.0.0.1:" + server.address().port + prefix, { mode: 0o600 });
async function slot(name) {
  const until = Date.now() + 300000;
  while (!slots.has(name)) {
    if (Date.now() > until) throw Error("Timed out waiting for " + name);
    await sleep(250);
  }
  return slots.get(name);
}
try {
  const { token, dose } = await slot("linked");
  const sdk = await JournalSync.open(token);
  assert.equal(sdk.read("dose", dose).fields.dose.amount, 100);
  slots.set("sdk-open", {});
  await slot("a-edit");
  await sdk.write("dose", dose, { tags: ["from-sdk"] });
  slots.set("sdk-edit", {});
  await slot("b-edit");
  await sdk.sync();
  const { fields } = sdk.read("dose", dose);
  assert.equal(fields.notes, "From B");
  assert.deepEqual(fields.tags, ["from-sdk"]);
  assert.equal(fields.dose.amount, 0.2);
  assert.equal(fields.dose.unit, "g");
  assert.ok(!("locationName" in fields));
  slots.set("sdk-merged", {});
  await slot("b-deleted");
  await sdk.sync();
  assert.equal(sdk.read("dose", dose), undefined);
  slots.set("sdk-deleted", {});
  await slot("rotated");
  await assert.rejects(sdk.sync(), error => error.status === 403);
  await slot("a-done");
  function checkStored(raw) {
    for (const forbidden of ["LOCAL ONLY", "From B", "Pending across rotation", "from-sdk", "signPrivate", "boxPrivate"]) {
      assert.ok(!raw.includes(forbidden), "Unexpected plaintext in relay storage");
    }
  }
  for (const table of ["accounts", "sessions", "profiles", "grants", "wraps", "changes", "management_receipts"]) {
    checkStored(JSON.stringify((await db.prepare("SELECT * FROM " + table).all()).results));
  }
  const bucket = await mf.getR2Bucket("BLOBS");
  const objects = await bucket.list();
  assert.ok(!objects.truncated);
  assert.ok(objects.objects.length > 0);
  for (const { key } of objects.objects) checkStored(await (await bucket.get(key)).text());
  console.log("SDK observed both simulator edits, intact dose units, and the tombstone.");
} finally {
  server.close();
  await mf.dispose();
}
