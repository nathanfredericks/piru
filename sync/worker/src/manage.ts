import {
  bearer,
  body,
  canonical,
  check,
  Failure,
  field,
  hash,
  integer,
  list,
  need,
  object,
  ownerGuard,
  publicKey,
  sessionGuard,
  sql,
  uuid,
  type Env,
  type Session,
} from "./common";

async function wrap(value: unknown) {
  const w = object(value);
  await publicKey(w.enc);
  return { enc: w.enc as string, ct: field(w.ct, 80) };
}
async function grant(value: unknown) {
  const g = object(value);
  const id = uuid(g.id);
  need(
    g.scope === "owner" || g.scope === "read" || g.scope === "write",
    400,
    "Invalid scope",
  );
  await Promise.all([publicKey(g.signPublic), publicKey(g.boxPublic)]);
  return {
    id,
    scope: g.scope,
    sign: g.signPublic as string,
    box: g.boxPublic as string,
    label: field(g.labelBox, 1, 4096),
    wrapped: await wrap(g.wrapped),
  };
}
function replay(
  row: { actor: string; digest: string; response: string },
  actor: string,
  digest: string,
) {
  need(
    row.actor === actor && row.digest === digest,
    409,
    "Idempotency key reused",
  );
  return JSON.parse(row.response);
}
export async function manage(
  req: Request,
  env: Env,
  s: Session,
  profile: string | undefined,
  action: string,
) {
  const db = env.DB;
  const key = uuid(req.headers.get("Idempotency-Key"));
  const data = action === "delete" ? {} : await body(req, 1024 * 1024);
  const p = profile ?? uuid(data.profileID);
  const actor =
    action === "create"
      ? s.account
      : await bearer(req.headers.get("X-Owner-Bearer"));
  if (action === "delete") {
    const gone = await sql(
      db,
      "SELECT 1 FROM deletions WHERE profile=? AND account_id=? AND owner_digest=? AND request_id=?",
      p,
      s.account,
      actor,
      key,
    ).first();
    if (gone) return { deleted: true };
  }
  if (action !== "create") {
    need(
      await sql(
        db,
        "SELECT 1 WHERE " + ownerGuard,
        p,
        s.account,
        actor,
      ).first(),
      403,
      "Active owner and matching account required",
    );
  }
  const digest = await hash(canonical([action, data]));
  const receipt = () =>
    sql(
      db,
      "SELECT actor,digest,response FROM management_receipts WHERE profile=? AND request_id=?",
      p,
      key,
    ).first<{ actor: string; digest: string; response: string }>();
  const old = await receipt();
  if (old) return replay(old, actor, digest);
  const batch = [check(db, sessionGuard, s.digest, s.account)];
  const epoch =
    action === "create" ? 1 : action === "delete" ? 0 : integer(data.epoch);
  if (action !== "create")
    batch.push(check(db, ownerGuard, p, s.account, actor));
  if (action !== "create" && action !== "delete")
    batch.push(
      check(
        db,
        "EXISTS(SELECT 1 FROM profiles WHERE id=? AND epoch=?)",
        p,
        epoch,
      ),
    );
  if (action === "create") {
    batch.push(
      check(db, "NOT EXISTS(SELECT 1 FROM deletions WHERE profile=?)", p),
    );
    batch.push(
      sql(
        db,
        "INSERT INTO profiles VALUES(?,?,?,1,?)",
        p,
        s.account,
        uuid(object(data.grant).id),
        field(data.recoveryBox, 1, 65536),
      ),
    );
  }
  if (action === "create" || action === "grant") {
    const g = await grant(data.grant);
    need(
      action !== "create" || g.scope === "owner",
      400,
      "Bootstrap grant must be an owner",
    );
    batch.push(
      sql(
        db,
        "INSERT INTO grants(profile,id,scope,digest,sign_public,box_public,label_box,since) VALUES(?,?,?,?,?,?,?,?)",
        p,
        g.id,
        g.scope,
        await hashBytes(data.bearer),
        g.sign,
        g.box,
        g.label,
        epoch,
      ),
    );
    const history = [];
    for (const item of list(data.history ?? [])) {
      const entry = object(item),
        e = integer(entry.epoch);
      need(e < epoch, 400, "Invalid historic epoch");
      history.push({ epoch: e, wrapped: await wrap(entry.wrapped) });
    }
    history.push({ epoch, wrapped: g.wrapped });
    batch.push(
      sql(
        db,
        "INSERT INTO wraps SELECT ?,?,json_extract(value,'$.epoch'),json_extract(value,'$.wrapped') FROM json_each(?)",
        p,
        g.id,
        JSON.stringify(history),
      ),
    );
  }
  if (action === "rotate") {
    const revoke = list(data.revoke).map(uuid);
    const wraps = [];
    for (const item of list(data.wraps)) {
      const entry = object(item);
      wraps.push({
        id: uuid(entry.grantID),
        wrapped: await wrap(entry.wrapped),
      });
    }
    const ids = [...revoke, ...wraps.map((w) => w.id)];
    need(new Set(ids).size === ids.length, 400, "Duplicate grant in rotation");
    // Compare membership inside the transaction so a concurrent enrollment cannot miss its wrap.
    batch.push(
      check(
        db,
        "(SELECT count(*) FROM grants WHERE profile=? AND revoked IS NULL)=? AND NOT EXISTS(SELECT value FROM json_each(?) EXCEPT SELECT id FROM grants WHERE profile=? AND revoked IS NULL) AND (SELECT anchor_id FROM profiles WHERE id=?) NOT IN (SELECT value FROM json_each(?))",
        p,
        ids.length,
        JSON.stringify(ids),
        p,
        p,
        JSON.stringify(revoke),
      ),
    );
    batch.push(
      sql(
        db,
        "UPDATE grants SET revoked=? WHERE profile=? AND id IN (SELECT value FROM json_each(?))",
        epoch + 1,
        p,
        JSON.stringify(revoke),
      ),
    );
    batch.push(
      sql(
        db,
        "INSERT INTO wraps SELECT ?,json_extract(value,'$.id'),?,json_extract(value,'$.wrapped') FROM json_each(?)",
        p,
        epoch + 1,
        JSON.stringify(wraps),
      ),
    );
  }
  const resultEpoch = action === "rotate" ? epoch + 1 : epoch;
  if (action === "rotate" || action === "recovery") {
    batch.push(
      sql(
        db,
        "UPDATE profiles SET epoch=?,recovery=? WHERE id=?",
        resultEpoch,
        field(data.recoveryBox, 1, 65536),
        p,
      ),
    );
  }
  if (action === "delete") {
    batch.push(
      sql(
        db,
        "INSERT INTO deletions(profile,account_id,owner_digest,request_id,purge_after) VALUES(?,?,?,?,unixepoch()+3600)",
        p,
        s.account,
        actor,
        key,
      ),
    );
    batch.push(sql(db, "DELETE FROM profiles WHERE id=?", p));
  } else {
    batch.push(
      sql(
        db,
        "INSERT INTO management_receipts VALUES(?,?,?,?,?)",
        p,
        key,
        actor,
        digest,
        JSON.stringify({ epoch: resultEpoch }),
      ),
    );
  }
  try {
    await db.batch(batch);
  } catch (error) {
    const raced = await receipt();
    if (raced) return replay(raced, actor, digest);
    if (
      action === "delete" &&
      (await sql(
        db,
        "SELECT 1 FROM deletions WHERE profile=? AND account_id=? AND owner_digest=? AND request_id=?",
        p,
        s.account,
        actor,
        key,
      ).first())
    )
      return { deleted: true };
    if (/constraint|precondition/i.test(String(error)))
      throw new Failure(409, "Profile, grant or epoch changed");
    throw error;
  }
  return action === "delete" ? { deleted: true } : { epoch: resultEpoch };
}
async function hashBytes(value: unknown) {
  return bearer(field(value, 32));
}
