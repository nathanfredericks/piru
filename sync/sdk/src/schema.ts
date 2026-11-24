import { check, object, uuid } from "./wire.js";
import type { Fields, RecordValue } from "./wire.js";

const routes = [
  "oral",
  "sublingual",
  "buccal",
  "insufflation",
  "inhalation",
  "intravenous",
  "intramuscular",
  "subcutaneous",
  "transdermal",
  "rectal",
  "other",
] as const;
export type DoseGroup = {
  substance: string;
  amount: number;
  unit: string;
  route: (typeof routes)[number];
  saltForm?: string | null;
  isomer?: string | null;
  releaseForm?: string | null;
  substanceUID?: string | null;
  productName?: string | null;
  displayNameSnapshot?: string | null;
  isApproximate?: boolean;
  isUnknownDose?: boolean;
  volumeML?: number | null;
  abv?: number | null;
  drinkName?: string | null;
  combinationName?: string | null;
  injectionSiteRaw?: string | null;
};
export type DoseFields = {
  dose: DoseGroup;
  timestamp: number;
  timeZoneIdentifier: string | null;
  medSlotMinutes: number | null;
  notes: string | null;
  tags: string[];
  isBackgroundMed: boolean;
  hadGrapefruit: boolean | null;
  mealRaw: string | null;
  sessionID?: string | null;
};
export type SessionNoteFields = {
  timestamp: number;
  text: string;
  shulgin: number | null;
  mood: number | null;
  energy: number | null;
  social: number | null;
  worked: number | null;
  descriptors: string[];
  kindRaw: string;
  sessionID?: string | null;
};
export type JournalSchema = {
  dose: DoseFields;
  sessionNote: SessionNoteFields;
  [kind: string]: Fields;
};

const nullableString = (x: unknown) => x === null || typeof x === "string";
const strings = (x: unknown) =>
  Array.isArray(x) && x.every((v) => typeof v === "string");
function validateRecordFields({ kind, fields: f }: RecordValue) {
  if (kind === "dose") {
    const g = f.dose;
    check(
      object(g) &&
        typeof g.substance === "string" &&
        Number.isFinite(g.amount) &&
        typeof g.unit === "string" &&
        routes.some((route) => route === g.route),
      "Invalid dose group",
    );
    for (const k of [
      "saltForm",
      "isomer",
      "releaseForm",
      "substanceUID",
      "productName",
      "displayNameSnapshot",
      "drinkName",
      "combinationName",
      "injectionSiteRaw",
    ]) {
      check(!(k in g) || nullableString(g[k]), "Invalid dose group field " + k);
    }
    for (const k of ["isApproximate", "isUnknownDose"])
      check(!(k in g) || typeof g[k] === "boolean", "Invalid dose group flag");
    for (const k of ["volumeML", "abv"])
      check(
        !(k in g) || g[k] === null || Number.isFinite(g[k]),
        "Invalid dose group measurement",
      );
    check(
      nullableString(f.notes) &&
        nullableString(f.timeZoneIdentifier) &&
        nullableString(f.mealRaw) &&
        strings(f.tags) &&
        (f.medSlotMinutes === null || Number.isSafeInteger(f.medSlotMinutes)) &&
        typeof f.isBackgroundMed === "boolean" &&
        (f.hadGrapefruit === null || typeof f.hadGrapefruit === "boolean"),
      "Invalid dose fields",
    );
  } else if (kind === "sessionNote") {
    check(
      typeof f.text === "string" &&
        strings(f.descriptors) &&
        typeof f.kindRaw === "string",
      "Invalid session note fields",
    );
    for (const k of ["shulgin", "mood", "energy", "social", "worked"])
      check(f[k] === null || Number.isSafeInteger(f[k]), "Invalid note rating");
  } else return;
  check(Number.isFinite(f.timestamp), "Invalid timestamp");
  if (f.sessionID != null) uuid(f.sessionID);
}
export { validateRecordFields };
