import { JournalSync, type DoseFields } from "@piru/journal-sync";

export async function recordSample(
  token: string,
  saveCheckpoint: (value: string) => Promise<void>,
) {
  const journal = await JournalSync.open(token, { saveCheckpoint });
  const recordID = crypto.randomUUID();
  const sample: DoseFields = {
    dose: { substance: "Sample", amount: 1, unit: "mg", route: "oral" },
    timestamp: Date.now(),
    timeZoneIdentifier: "UTC",
    notes: null,
    tags: [],
    medSlotMinutes: null,
    isBackgroundMed: false,
    hadGrapefruit: null,
    mealRaw: null,
  };
  await journal.write("dose", recordID, sample);
  await journal.write("dose", recordID, { notes: "Imported from the example" });
  const doses = journal.list("dose");
  await journal.delete("dose", recordID);
  return doses;
}
