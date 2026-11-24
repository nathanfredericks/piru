# Encrypted profile sync

Piru keeps one cloud journal per linked local profile. Settings → Data & Backup → Journal Sync opens enrollment, recovery, integration tokens, and sync history. Enrollment creates device keys and a recovery code before uploading records. A download can link an empty local profile or create a separate profile. The SDK works with the same encrypted record format as the iOS app.

## Local development

1. In `worker/`, run `npm ci`, `npm run migrate:local`, then `npm run dev`. Wrangler starts a local D1 database and R2 bucket.
2. In `sdk/`, run `npm ci` and `npm run build`. Examples use the built JavaScript package and TypeScript declarations.
3. Build Piru from Xcode. Debug simulator builds use the relay on loopback port 8787. For another service, set the app target's `PIRU_SYNC_URL` build setting and configure the matching Apple audience in the Worker. Release builds require HTTPS. Apple sign-in needs the app's Sign in with Apple capability and provisioning.

The app and SDK encrypt a saved Automerge document for each changed record. A keyed document identifier lets the relay group changes without learning record IDs. Signed changes include the profile, operation, grant, key epoch, and ciphertext. The append-only change feed retains concurrent edits and tombstones. Clients checkpoint the feed after applying a change and retry signed writes against the same receipt. An owner rotates the content key when revoking a grant. The stable index key keeps the same document discoverable after rotation.

SwiftData history identifies committed changes from the app and its extensions. Replication uses the selected profile's store. A foreground poll also checks profile metadata owned by the registry. Recovery credentials and per-device keys are held in Keychain. The recovery code and the original Apple account can enroll a new device.

Each avatar is a separate encrypted, content-addressed record. The relay currently accepts up to 2 MiB of ciphertext per operation. For other record types that limit includes the record’s Automerge history. An oversized iOS document remains pending while other records upload.

The Worker contract describes authenticated endpoints, limits, and storage. The SDK guide includes read and write examples. [Worker contract](worker/CONTRACT.md) and [SDK guide](sdk/README.md).

## Verification

Run `npm run typecheck && npm test` from `worker/` and `npm test` from `sdk/`. The suites use local services and synthetic keys. The iOS target consumes the fixtures in `fixtures/`. Build the Piru scheme for testing with an installed iOS simulator runtime, then run the Swift Testing suites.

For the cross-device test, pass the resulting test plan and two distinct simulator UDIDs to the harness. Use a new results directory for each run.

```sh
python3 sync/verification/two_simulators.py /path/to/Piru.xctestrun \
  FIRST_SIMULATOR_UDID SECOND_SIMULATOR_UDID --logs /tmp/piru-sync-results
```

The harness starts local workerd, a synthetic Apple signing key, and a loopback rendezvous. Both simulator test hosts enroll through the account layer and sync with a third SDK client. The test checks a concurrent edit and deletion, rotates the key with a sealed write still pending, and restores into a fresh profile. Only the test target imports the synthetic session. All worker, D1 and R2 state in this run is ephemeral. The simulator test creates a profile named Synthetic A or Synthetic B. Each result bundle and the relay log go in the requested results directory.

Set `PIRU_SYNC_BENCHMARK=1` in the test plan environment to run the 3,000-record journal benchmark. It reports initial capture time, idle history capture time, one-edit capture time and encrypted transfer size.

The launch benchmark imports 3,000 synthetic doses on a disposable simulator and verifies the row count before and after timing. Each sample starts a fresh app process on the booted simulator. The default metric measures elapsed host time from the launch request to a Debug console marker after Piru's catalog, store and reminder startup passes. It includes simulator command and console overhead. The runner captures a Journal screenshot after each marker for visual verification and excludes one warm-up from the summary. Use a built Debug simulator app and a new output directory for each run.

```sh
python3 sync/verification/launch_benchmark.py --app /path/to/Piru.app \
  --like SIMULATOR_UDID --out /tmp/piru-launch-results --runs 10
```
