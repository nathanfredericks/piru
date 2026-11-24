import { nonce, signIn } from "./account";
import { Failure, need, session, sql, uuid, type Env } from "./common";
import { manage } from "./manage";
import { append, directory, feed, principal } from "./relay";

async function route(req: Request, env: Env) {
  const path = new URL(req.url).pathname;
  const method = req.method;
  if (path === "/v1/auth/nonce" && method === "POST") return nonce(env.DB);
  if (path === "/v1/auth/apple" && method === "POST") return signIn(req, env);
  if (path === "/v1/profiles") {
    const s = await session(req, env.DB);
    if (method === "POST") return manage(req, env, s, undefined, "create");
    if (method === "GET") {
      const rows = await sql(
        env.DB,
        "SELECT id AS profileID,epoch,anchor_id AS anchorGrantID FROM profiles WHERE account_id=? ORDER BY id",
        s.account,
      ).all();
      return { profiles: rows.results };
    }
  }
  const parts =
    /^\/v1\/profiles\/([^/]+)(?:\/(changes|grants|rotate|recovery))?$/.exec(
      path,
    );
  need(parts, 404, "Unknown route");
  const p = uuid(parts[1]),
    action = parts[2];
  if (action === "changes" || (action === "grants" && method === "GET")) {
    const who = await principal(req, env, p);
    if (action === "grants") return directory(req, env, p, who);
    if (method === "POST") return append(req, env, p, who);
    if (method === "GET") return feed(req, env, p);
  }
  const s = await session(req, env.DB);
  if (action === "recovery" && method === "GET") {
    const recovery = await sql(
      env.DB,
      "SELECT epoch,recovery AS recoveryBox FROM profiles WHERE id=? AND account_id=?",
      p,
      s.account,
    ).first();
    need(recovery, 404, "Profile unavailable");
    return recovery;
  }
  if (action === "grants" && method === "POST")
    return manage(req, env, s, p, "grant");
  if (action === "rotate" && method === "POST")
    return manage(req, env, s, p, "rotate");
  if (action === "recovery" && method === "PUT")
    return manage(req, env, s, p, "recovery");
  if (!action && method === "DELETE") return manage(req, env, s, p, "delete");
  throw new Failure(405, "Method unavailable");
}
export async function cleanup(env: Env) {
  const db = env.DB;
  await db.batch([
    sql(db, "DELETE FROM sessions WHERE expires<=unixepoch()"),
    sql(db, "DELETE FROM challenges WHERE expires<=unixepoch()"),
  ]);
  const abandoned = await sql(
    db,
    "SELECT blob FROM uploads WHERE expires<=unixepoch() LIMIT 100",
  ).all<{ blob: string }>();
  if (abandoned.results.length) {
    const blobs = abandoned.results.map((r) => r.blob);
    await env.BLOBS.delete(blobs);
    await sql(
      db,
      "DELETE FROM uploads WHERE blob IN (SELECT value FROM json_each(?))",
      JSON.stringify(blobs),
    ).run();
  }
  const deleted = await sql(
    db,
    "SELECT profile FROM deletions WHERE purged=0 AND purge_after<=unixepoch() LIMIT 10",
  ).all<{ profile: string }>();
  for (const { profile } of deleted.results) {
    const page = await env.BLOBS.list({ prefix: profile + "/", limit: 1000 });
    if (page.objects.length)
      await env.BLOBS.delete(page.objects.map((o) => o.key));
    if (!page.truncated)
      await sql(
        db,
        "UPDATE deletions SET purged=1 WHERE profile=?",
        profile,
      ).run();
  }
}

export default {
  async fetch(req: Request, env: Env) {
    try {
      return Response.json(await route(req, env), {
        headers: { "Cache-Control": "no-store" },
      });
    } catch (error) {
      const known = error instanceof Failure;
      return Response.json(
        { error: known ? error.message : "Service unavailable" },
        {
          status: known ? error.status : 503,
          headers: { "Cache-Control": "no-store" },
        },
      );
    }
  },
  async scheduled(_event: ScheduledController, env: Env) {
    await cleanup(env);
  },
} satisfies ExportedHandler<Env>;
