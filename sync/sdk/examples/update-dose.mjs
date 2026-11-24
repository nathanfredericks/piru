// Run from sync/sdk after npm run build. Read the compound token from a private file.
import { readFile } from "node:fs/promises";
import { JournalSync } from "../dist/index.js";

const [tokenFile, recordID, notes] = process.argv.slice(2);
if (!tokenFile || !recordID || notes === undefined)
  throw new Error("Expected token file, dose UUID, and new note");
const client = await JournalSync.open(
  (await readFile(tokenFile, "utf8")).trim(),
);
if (!client.read("dose", recordID)) throw new Error("Dose not found");
const opID = await client.write("dose", recordID, { notes });
await client.sync();
console.log(JSON.stringify({ opID, recordID, cursor: client.cursor }));
