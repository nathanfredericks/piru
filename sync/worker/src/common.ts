export interface Env {
  DB: D1Database;
  BLOBS: R2Bucket;
  APPLE_AUDIENCE: string;
}
export class Failure extends Error {
  constructor(
    public status: number,
    message: string,
  ) {
    super(message);
  }
}
export function need(
  test: unknown,
  status: number,
  message: string,
): asserts test {
  if (!test) throw new Failure(status, message);
}
export function object(x: unknown): Record<string, unknown> {
  need(
    x !== null && typeof x === "object" && !Array.isArray(x),
    400,
    "Expected an object",
  );
  return x as Record<string, unknown>;
}
export function list(x: unknown): unknown[] {
  need(Array.isArray(x), 400, "Expected a list");
  return x;
}
export function uuid(x: unknown): string {
  need(
    typeof x === "string" &&
      /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(x),
    400,
    "Invalid UUID",
  );
  return x;
}
export function integer(x: unknown, min = 1): number {
  need(
    typeof x === "number" && Number.isSafeInteger(x) && x >= min,
    400,
    "Invalid integer",
  );
  return x;
}
export function encode(data: Uint8Array): string {
  let raw = "";
  for (let i = 0; i < data.length; i += 8192)
    raw += String.fromCharCode(...data.subarray(i, i + 8192));
  return btoa(raw).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}
export function binary(
  x: unknown,
  min: number,
  max = min,
): Uint8Array<ArrayBuffer> {
  need(
    typeof x === "string" &&
      x.length <= Math.ceil((max * 4) / 3) &&
      /^[A-Za-z0-9_-]+$/.test(x),
    400,
    "Invalid base64url",
  );
  let raw: string;
  try {
    raw = atob(x.replace(/-/g, "+").replace(/_/g, "/"));
  } catch {
    throw new Failure(400, "Invalid base64url");
  }
  const data = Uint8Array.from(raw, (c) => c.charCodeAt(0));
  need(
    data.length >= min && data.length <= max && encode(data) === x,
    400,
    "Invalid binary length or encoding",
  );
  return data;
}
export function field(x: unknown, min: number, max = min): string {
  binary(x, min, max);
  return x as string;
}
export const utf8 = (s: string) => new TextEncoder().encode(s);
export async function hash(
  x: string | Uint8Array<ArrayBuffer>,
): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    typeof x === "string" ? utf8(x) : x,
  );
  return Array.from(new Uint8Array(digest), (b) =>
    b.toString(16).padStart(2, "0"),
  ).join("");
}
export async function bearer(raw: string | null): Promise<string> {
  try {
    return await hash(binary(raw, 32));
  } catch {
    throw new Failure(401, "Invalid credential");
  }
}
export function authorization(req: Request): Promise<string> {
  return bearer(
    req.headers.get("Authorization")?.match(/^Bearer ([A-Za-z0-9_-]+)$/)?.[1] ??
      null,
  );
}
export function sql(
  db: D1Database,
  query: string,
  ...args: unknown[]
): D1PreparedStatement {
  return db.prepare(query).bind(...args);
}
export function check(db: D1Database, condition: string, ...args: unknown[]) {
  return sql(
    db,
    "INSERT INTO assertions(ok) SELECT CASE WHEN (" +
      condition +
      ") THEN 1 ELSE 0 END",
    ...args,
  );
}
export async function body(req: Request, limit: number) {
  const reader = req.body?.getReader();
  need(reader, 400, "Missing body");
  const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false });
  let size = 0,
    text = "";
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > limit) {
        await reader.cancel();
        throw new Failure(413, "Request too large");
      }
      text += decoder.decode(value, { stream: true });
    }
    return object(JSON.parse(text + decoder.decode()));
  } catch (error) {
    if (error instanceof Failure) throw error;
    throw new Failure(400, "Invalid JSON");
  }
}
export function canonical(x: unknown): string {
  if (Array.isArray(x)) return "[" + x.map(canonical).join(",") + "]";
  if (x !== null && typeof x === "object") {
    const o = object(x);
    return (
      "{" +
      Object.keys(o)
        .sort()
        .map((k) => JSON.stringify(k) + ":" + canonical(o[k]))
        .join(",") +
      "}"
    );
  }
  return JSON.stringify(x);
}
export async function publicKey(x: unknown) {
  const raw = binary(x, 65);
  need(raw[0] === 4, 400, "Expected uncompressed P256 point");
  try {
    return await crypto.subtle.importKey(
      "raw",
      raw,
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["verify"],
    );
  } catch {
    throw new Failure(400, "Invalid P256 public key");
  }
}
export const sessionGuard =
  "EXISTS(SELECT 1 FROM sessions WHERE digest=? AND account_id=? AND expires>unixepoch())";
export const ownerGuard =
  "EXISTS(SELECT 1 FROM grants g JOIN profiles p ON p.id=g.profile WHERE g.profile=? AND p.account_id=? AND g.digest=? AND g.scope='owner' AND g.revoked IS NULL)";
export interface Session {
  account: string;
  digest: string;
}
export async function session(req: Request, db: D1Database): Promise<Session> {
  const digest = await authorization(req);
  const row = await sql(
    db,
    "SELECT account_id FROM sessions WHERE digest=? AND expires>unixepoch()",
    digest,
  ).first<string>("account_id");
  need(row, 401, "Account sign-in required");
  return { account: row, digest };
}
