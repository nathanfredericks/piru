import { createRemoteJWKSet, jwtVerify } from "jose";
import {
  bearer,
  body,
  check,
  encode,
  Failure,
  field,
  hash,
  need,
  sql,
  type Env,
} from "./common";

const appleKeys = createRemoteJWKSet(
  new URL("https://appleid.apple.com/auth/keys"),
);
const secret = () => encode(crypto.getRandomValues(new Uint8Array(32)));

export async function nonce(db: D1Database) {
  const value = secret();
  await sql(
    db,
    "INSERT INTO challenges VALUES(?,unixepoch()+300)",
    await hash(value),
  ).run();
  return { nonce: value };
}

export async function signIn(req: Request, env: Env) {
  const data = await body(req, 16384);
  const challenge = await hash(field(data.nonce, 32));
  need(typeof data.identityToken === "string", 400, "Missing identity token");
  let subject: string;
  try {
    const { payload } = await jwtVerify(data.identityToken, appleKeys, {
      issuer: "https://appleid.apple.com",
      audience: env.APPLE_AUDIENCE,
      algorithms: ["RS256"],
      requiredClaims: ["sub", "iat", "exp", "nonce"],
      maxTokenAge: "5m",
    });
    need(
      payload.nonce === challenge &&
        typeof payload.sub === "string" &&
        payload.sub.length,
      401,
      "Incorrect challenge",
    );
    subject = payload.sub;
  } catch {
    throw new Failure(401, "Apple sign-in failed");
  }
  const token = secret();
  const db = env.DB;
  try {
    const result = await db.batch<{ id: string }>([
      sql(
        db,
        "DELETE FROM challenges WHERE nonce_hash=? AND expires>unixepoch()",
        challenge,
      ),
      check(db, "changes()=1"),
      sql(
        db,
        "INSERT INTO accounts(id,apple_subject) VALUES(?,?) ON CONFLICT(apple_subject) DO NOTHING",
        crypto.randomUUID(),
        subject,
      ),
      sql(
        db,
        "INSERT INTO sessions SELECT ?,id,unixepoch()+2592000 FROM accounts WHERE apple_subject=?",
        await bearer(token),
        subject,
      ),
      sql(db, "SELECT id FROM accounts WHERE apple_subject=?", subject),
    ]);
    return { accountID: result[4].results[0].id, session: token };
  } catch (error) {
    if (String(error).includes("precondition"))
      throw new Failure(401, "Challenge expired or already used");
    throw error;
  }
}
