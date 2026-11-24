# Piru Journal Sync SDK

Use Node 22 or newer. From this directory, run `npm ci` and `npm test`. The build emits ESM JavaScript and TypeScript declarations in `dist/`. The library uses WebCrypto, fetch and the pinned Automerge and HPKE packages.

## Read and edit a journal

```ts
import { JournalSync } from "@piru/journal-sync";

const client = await JournalSync.open(token, { checkpoint, saveCheckpoint });
const rows = client.list("dose");
const entry = client.read("dose", recordID);
if (entry) await client.write("dose", recordID, { notes: "Updated entry" });
await client.sync();
```

`open` restores an optional encrypted checkpoint, retries an outstanding operation and pulls through the end of the feed. `read` and `list` return local snapshots. `sync` pulls subsequent remote changes. `write` patches the named field registers and returns an operation UUID after the relay acknowledges it. Each complete group passed to `write` replaces that group atomically. To edit the dose amount, preserve every other member with `{ dose: { ...entry.fields.dose, amount: value } }`. An explicit JSON null clears a nullable value. `delete(kind, recordID)` writes a tombstone. Assign a new record UUID to create another record after deletion.

The default schema types doses and session notes. Other kinds have JSON-valued field maps and can use an application-specific schema via `JournalSync.open<MySchema>(...)` and a `validate(record)` callback. The SDK checks scalar types, document identities and reserved keys. A complete live dose or session note must satisfy the Swift projection’s field types. Timestamps are Unix milliseconds. See `examples/journal.ts` for a complete dose insert and delete.

## Credentials and checkpoints

A compound token contains the service origin, profile and grant IDs, bearer and two private keys. Treat it as a secret. Only the bearer goes in the Authorization header. `encryptToken(token, passphrase)` and `decryptToken(box, passphrase)` use PBKDF2-SHA256 and AES-256-GCM for local storage. Swift's recovery code is a separate format.

The client checks the token's signing and box public keys against its directory entry, unwraps the epoch content and stable index keys, and verifies every encrypted grant label and its signing-key proof. The relay supplies membership for the envelope's epoch. For a replay use `GET /v1/profiles/:p/grants?epoch=N`. An active later grant sees records from earlier epochs only when the owner included a wrap for it. The SDK verifies the envelope signature even for an epoch it cannot decrypt.

`issueGrant(url, profileID, scope, label, epoch, keys)` generates a compound token and the `{grant,bearer}` for owner enrollment. The 64-byte keys are the content key followed by the stable index key. To provide historical access, wrap each prior key pair for the new grant's box public key using that historical epoch in `wrapKeys`. Submit `{epoch,grant,bearer,history:[{epoch,wrapped}]}` to the enrollment endpoint. Deliver the compound token to its recipient separately.

Opening a checkpoint requires relay access to reconcile its pending write and cursor. An already-open client can read its last local snapshot offline. During replay, a signer missing from the cached directory triggers one lookup for the envelope’s epoch. Replay advances past the operation only after the SDK verifies its signer.

Use one writer per checkpoint file. Supply an asynchronous `saveCheckpoint` callback that atomically replaces the previous file or database value. The client invokes it before sending a signed operation, after its receipt, and after pulling a page. `await client.checkpoint()` exports the same encrypted state, bound to the token, profile and service origin. After a lost response, call `await client.retry()` or reopen the last saved checkpoint. The retry reuses the signed bytes and opID. A rotation triggers replay before a still-unsent operation is sealed for the current epoch.

## Local verification

`npm test` uses the two synthetic wire vectors in `../fixtures/` and a local in-memory relay. `v1-js.json` contains a wire-level sample document. `v1-swift.json` contains Swift's edit of that save, its CryptoKit envelope and its fresh HPKE wrap. Both use the same signed owner label. The fixtures contain public test credentials.

The parent integration harness in `../worker/test/simulator-relay.mjs` runs the Worker on loopback and exchanges changes between the SDK and two simulator test hosts. For a direct update to an existing synthetic dose, use `node examples/update-dose.mjs TOKEN_FILE RECORD_UUID "New note"`.
