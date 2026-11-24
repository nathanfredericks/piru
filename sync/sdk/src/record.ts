import * as A from "@automerge/automerge";
import { check, kindName, object, uuid } from "./wire.js";
import type { Fields, Json, RecordValue } from "./wire.js";

export type RecordDoc = A.Doc<Record<string, A.ImmutableString>>;
const reserved = new Set([
  "kind",
  "recordID",
  "_deleted",
  "__proto__",
  "constructor",
  "prototype",
]);
function fieldName(k: string) {
  check(k.length > 0 && !reserved.has(k), "Reserved or empty domain field");
}
function jsonValue(x: unknown): asserts x is Json {
  if (
    x === null ||
    typeof x === "boolean" ||
    typeof x === "string" ||
    Number.isFinite(x)
  )
    return;
  if (Array.isArray(x)) {
    for (const item of x) jsonValue(item);
    return;
  }
  check(
    object(x) && [Object.prototype, null].includes(Object.getPrototypeOf(x)),
    "Expected JSON field value",
  );
  for (const value of Object.values(x)) jsonValue(value);
}
export function patch(
  existing: RecordDoc | undefined,
  kind: string,
  id: string,
  fields: Fields | null,
): RecordDoc {
  kindName(kind);
  uuid(id);
  check(!existing?._deleted || fields === null, "Record is deleted");
  if (fields !== null) check(object(fields), "Expected domain fields");
  return A.change(
    existing ? A.clone(existing) : A.init<Record<string, A.ImmutableString>>(),
    (d) => {
      if (!existing) {
        d.kind = new A.ImmutableString(kind);
        d.recordID = new A.ImmutableString(id);
      }
      if (fields === null) d._deleted = new A.ImmutableString("true");
      else
        for (const [name, value] of Object.entries(fields)) {
          fieldName(name);
          jsonValue(value);
          const encoded = JSON.stringify(value);
          if (d[name]?.val !== encoded)
            d[name] = new A.ImmutableString(encoded);
        }
    },
  );
}
export function inspect(doc: RecordDoc): RecordValue & { deleted: boolean } {
  const fields: Fields = Object.create(null);
  for (const [k, value] of Object.entries(doc)) {
    check(
      value instanceof A.ImmutableString,
      "Expected Automerge scalar string",
    );
    if (k === "kind" || k === "recordID" || k === "_deleted") {
      for (const candidate of Object.values(A.getConflicts(doc, k) ?? {})) {
        check(
          candidate instanceof A.ImmutableString && candidate.val === value.val,
          "Conflicting record identity or tombstone",
        );
      }
      if (k !== "_deleted") continue;
    }
    if (k === "_deleted") {
      check(value.val === "true", "Invalid tombstone");
      continue;
    }
    fieldName(k);
    const parsed = JSON.parse(value.val);
    jsonValue(parsed);
    fields[k] = parsed;
  }
  const kind = doc.kind?.val,
    recordID = doc.recordID?.val;
  kindName(kind);
  uuid(recordID);
  return { kind, recordID, fields, deleted: Boolean(doc._deleted) };
}
