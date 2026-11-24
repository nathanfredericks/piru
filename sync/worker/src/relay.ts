import {
  authorization,
  binary,
  body,
  check,
  Failure,
  field,
  hash,
  integer,
  need,
  publicKey,
  sql,
  utf8,
  uuid,
  type Env,
} from "./common";

interface Principal {
  id: string;
  scope: string;
  sign_public: string;
  epoch: number;
  anchor_id: string;
  digest: string;
}
export async function principal(
  req: Request,
  env: Env,
  p: string,
): Promise<Principal> {
  const digest = await authorization(req);
  const row = await sql(
    env.DB,
    `SELECT g.id,g.scope,g.sign_public,p.epoch,p.anchor_id FROM profiles p JOIN grants g ON g.profile=p.id
    WHERE p.id=? AND g.digest=? AND g.revoked IS NULL`,
    p,
    digest,
  ).first<Omit<Principal, "digest">>();
  need(row, 403, "Active profile grant required");
  return { ...row, digest };
}
export function parameter(
  url: URL,
  name: string,
  fallback: number,
  min: number,
) {
  const raw = url.searchParams.get(name);
  if (raw === null) return fallback;
  need(/^(0|[1-9][0-9]*)$/.test(raw), 400, "Invalid " + name);
  return integer(Number(raw), min);
}
export async function directory(
  req: Request,
  env: Env,
  p: string,
  who: Principal,
) {
  const epoch = parameter(new URL(req.url), "epoch", who.epoch, 1);
  need(epoch <= who.epoch, 404, "Unknown epoch");
  const rows = await sql(
    env.DB,
    `SELECT g.id,g.scope,g.sign_public AS signPublic,g.box_public AS boxPublic,g.label_box AS labelBox,w.wrapped
    FROM grants g LEFT JOIN wraps w ON w.profile=g.profile AND w.grant_id=g.id AND w.grant_id=? AND w.epoch=?
    WHERE g.profile=? AND ((g.since<=? AND (g.revoked IS NULL OR g.revoked>?)) OR w.wrapped IS NOT NULL)
    ORDER BY g.id`,
    who.id,
    epoch,
    p,
    epoch,
    epoch,
  ).all();
  await principal(req, env, p);
  return {
    epoch,
    anchorGrantID: who.anchor_id,
    grants: rows.results.map(({ wrapped, ...g }) =>
      wrapped ? { ...g, wrapped: JSON.parse(String(wrapped)) } : g,
    ),
  };
}
const MAX_CIPHER = 2 * 1024 * 1024;
export async function append(
  req: Request,
  env: Env,
  p: string,
  who: Principal,
) {
  need(who.scope !== "read", 403, "Write grant required");
  const data = await body(req, 3 * 1024 * 1024);
  need(
    data.profileID === p && data.grantID === who.id,
    403,
    "Envelope grant or profile mismatch",
  );
  const opID = uuid(data.opID),
    epoch = integer(data.epoch);
  need(epoch === who.epoch, 409, "Epoch changed");
  const envelope = {
    profileID: p,
    docID: field(data.docID, 32),
    opID,
    grantID: who.id,
    epoch,
    nonce: field(data.nonce, 12),
    ciphertext: field(data.ciphertext, 16, MAX_CIPHER),
    signature: field(data.signature, 64),
  };
  need(
    Object.keys(data).length === Object.keys(envelope).length,
    400,
    "Unknown envelope field",
  );
  const signed = [
    "piru-sync-v1",
    p,
    envelope.docID,
    opID,
    who.id,
    String(epoch),
    envelope.nonce,
    envelope.ciphertext,
  ].join("\n");
  const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    await publicKey(who.sign_public),
    binary(envelope.signature, 64),
    utf8(signed),
  );
  need(ok, 403, "Invalid signature");
  const bytes = JSON.stringify(envelope),
    digest = await hash(bytes);
  const db = env.DB;
  const receipt = async () => {
    const row = await sql(
      db,
      "SELECT seq,digest FROM changes WHERE profile=? AND op_id=?",
      p,
      opID,
    ).first<{ seq: number; digest: string }>();
    if (!row) return null;
    const latest = await principal(req, env, p);
    need(latest.epoch === epoch, 409, "Epoch changed");
    need(row.digest === digest, 409, "Operation ID reused");
    return { seq: row.seq };
  };
  const existing = await receipt();
  if (existing) return existing;
  // Give each upload its own immutable key. A failed or losing D1 commit leaves a
  // persisted cleanup ticket, never a reference to an incomplete or mutable object.
  const blob = p + "/ops/" + crypto.randomUUID();
  await sql(db, "INSERT INTO uploads VALUES(?,unixepoch()+3600)", blob).run();
  await env.BLOBS.put(blob, bytes);
  const active =
    "EXISTS(SELECT 1 FROM grants g JOIN profiles p ON p.id=g.profile WHERE g.profile=? AND g.id=? AND g.digest=? AND g.revoked IS NULL AND g.scope!='read' AND p.epoch=?)";
  try {
    const result = await db.batch<{ seq: number }>([
      check(db, active, p, who.id, who.digest, epoch),
      check(
        db,
        "EXISTS(SELECT 1 FROM uploads WHERE blob=? AND expires>unixepoch())",
        blob,
      ),
      sql(
        db,
        "INSERT INTO changes(profile,seq,op_id,digest,blob,size) SELECT ?,coalesce(max(seq),0)+1,?,?,?,? FROM changes WHERE profile=? RETURNING seq",
        p,
        opID,
        digest,
        blob,
        bytes.length,
        p,
      ),
      sql(db, "DELETE FROM uploads WHERE blob=?", blob),
    ]);
    return { seq: result[1].results[0].seq };
  } catch (error) {
    const raced = await receipt();
    if (raced) return raced;
    if (String(error).includes("precondition"))
      throw new Failure(409, "Grant or epoch changed");
    throw error;
  }
}

const PAGE = 16;
const BYTE_BUDGET = 4 * 1024 * 1024;
interface Row {
  seq: number;
  digest: string;
  blob: string;
  size: number;
}
export async function feed(req: Request, env: Env, p: string) {
  const url = new URL(req.url);
  const after = parameter(url, "after", 0, 0),
    limit = parameter(url, "limit", PAGE, 1);
  need(limit <= 100, 400, "Limit exceeds 100");
  const result = await sql(
    env.DB,
    "SELECT seq,digest,blob,size FROM changes WHERE profile=? AND seq>? ORDER BY seq LIMIT ?",
    p,
    after,
    limit + 1,
  ).all<Row>();
  const rows: Row[] = [];
  let size = 0;
  for (const row of result.results) {
    if (rows.length === limit || (rows.length && size + row.size > BYTE_BUDGET))
      break;
    size += row.size;
    rows.push(row);
  }
  const cursor = rows.at(-1)?.seq ?? after,
    hasMore = rows.length < result.results.length;
  // Full aligned segments never change. Keep the authenticated cursor and hasMore
  // outside the checkpoint because more operations may arrive after it is written.
  const checkpoint =
    after % PAGE === 0 && rows.length === PAGE
      ? p + "/checkpoints/" + cursor
      : undefined;
  const manifest = await hash(
    JSON.stringify(rows.map((r) => [r.seq, r.digest])),
  );
  let changes: { seq: number; envelope: unknown }[] | undefined;
  const cached = checkpoint && (await env.BLOBS.get(checkpoint));
  if (cached && cached.customMetadata?.manifest === manifest) {
    try {
      const segment: unknown = await cached.json();
      if (Array.isArray(segment) && segment.length === rows.length) {
        const valid = await Promise.all(
          rows.map(
            async (r, i) =>
              segment[i]?.seq === r.seq &&
              (await hash(JSON.stringify(segment[i].envelope))) === r.digest,
          ),
        );
        if (valid.every(Boolean)) changes = segment;
      }
    } catch {
      // The D1 receipts and individual blobs can rebuild a damaged checkpoint.
    }
  }
  if (!changes) {
    changes = await Promise.all(
      rows.map(async (r) => {
        const blob = await env.BLOBS.get(r.blob);
        need(blob, 503, "Record blob unavailable");
        const bytes = await blob.text();
        need(
          (await hash(bytes)) === r.digest,
          503,
          "Record blob verification failed",
        );
        return { seq: r.seq, envelope: JSON.parse(bytes) };
      }),
    );
    if (checkpoint) {
      const raw = JSON.stringify(changes);
      await env.BLOBS.put(checkpoint, raw, { customMetadata: { manifest } });
    }
  }
  await principal(req, env, p);
  return { changes, cursor, hasMore };
}
