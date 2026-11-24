export type Json =
  | string
  | number
  | boolean
  | null
  | Json[]
  | { [key: string]: Json };
export type Fields = Record<string, Json>;
export interface RecordValue<F = Fields> {
  kind: string;
  recordID: string;
  fields: F;
}
export interface Token {
  url: string;
  profileID: string;
  grantID: string;
  bearer: string;
  signPrivate: string;
  boxPrivate: string;
}
export interface Wrapped {
  enc: string;
  ct: string;
}
export interface Grant {
  id: string;
  scope: "owner" | "write" | "read";
  signPublic: string;
  boxPublic: string;
  labelBox: string;
  wrapped?: Wrapped;
  revoked?: boolean;
  since?: number;
}
export interface Directory {
  epoch: number;
  grants: Grant[];
}
export interface Header {
  profileID: string;
  docID: string;
  opID: string;
  grantID: string;
  epoch: number;
}
export interface Envelope extends Header {
  nonce: string;
  ciphertext: string;
  signature: string;
}
export function check(ok: unknown, message: string): asserts ok {
  if (!ok) throw new Error(message);
}
export function object(x: unknown): x is Record<string, unknown> {
  return typeof x === "object" && x !== null && !Array.isArray(x);
}
export function uuid(x: unknown): asserts x is string {
  check(
    typeof x === "string" &&
      /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(x),
    "Expected lowercase UUID",
  );
}
export function natural(x: unknown, minimum = 1): asserts x is number {
  check(
    typeof x === "number" && Number.isSafeInteger(x) && x >= minimum,
    "Invalid integer",
  );
}
export function kindName(k: unknown): asserts k is string {
  check(
    typeof k === "string" && k.length > 0 && !/[\x00-\x1f]/.test(k),
    "Invalid record kind",
  );
}
export const utf8 = (s: string) => new TextEncoder().encode(s);
export const decodeText = (b: ArrayBuffer | Uint8Array) =>
  new TextDecoder("utf-8", { fatal: true }).decode(b);
export function b64(bytes: ArrayBuffer | Uint8Array): string {
  const a = new Uint8Array(bytes);
  let s = "";
  for (let i = 0; i < a.length; i += 8192)
    s += String.fromCharCode(...a.subarray(i, i + 8192));
  return btoa(s).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}
export function bytes(s: unknown, length?: number): Uint8Array<ArrayBuffer> {
  check(
    typeof s === "string" && /^[A-Za-z0-9_-]+$/.test(s),
    "Invalid base64url",
  );
  const a = Uint8Array.from(
    atob(s.replaceAll("-", "+").replaceAll("_", "/")),
    (c) => c.charCodeAt(0),
  );
  check(
    b64(a) === s && (length === undefined || a.length === length),
    "Invalid base64url length or padding bits",
  );
  return a;
}
export function validateHeader(h: Header) {
  uuid(h.profileID);
  uuid(h.opID);
  uuid(h.grantID);
  bytes(h.docID, 32);
  natural(h.epoch);
}
export function validateToken(t: Token): Token {
  check(object(t) && typeof t.url === "string", "Invalid token");
  const url = new URL(t.url);
  const loopback = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
  check(
    (url.protocol === "https:" || (loopback && url.protocol === "http:")) &&
      !url.username &&
      !url.password &&
      !url.search &&
      !url.hash &&
      ["/", "/v1", "/v1/"].includes(url.pathname),
    "Invalid service URL",
  );
  uuid(t.profileID);
  uuid(t.grantID);
  bytes(t.bearer, 32);
  bytes(t.signPrivate, 32);
  bytes(t.boxPrivate, 32);
  return t;
}
export function encodeToken(t: Token): string {
  const { url, profileID, grantID, bearer, signPrivate, boxPrivate } =
    validateToken(t);
  return (
    "piru1." +
    b64(
      utf8(
        JSON.stringify({
          url,
          profileID,
          grantID,
          bearer,
          signPrivate,
          boxPrivate,
        }),
      ),
    )
  );
}
export function decodeToken(token: string): Token {
  check(token.startsWith("piru1."), "Invalid token prefix");
  return validateToken(JSON.parse(decodeText(bytes(token.slice(6)))));
}
