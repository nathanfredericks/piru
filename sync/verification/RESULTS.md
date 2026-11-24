# Encrypted sync verification

Verification used synthetic profiles, local workerd with D1 and R2, Xcode 27.2 (27B52), and the iOS 27.0 simulator runtime. Apple authentication tests used a test issuer key at the Apple JWKS endpoint inside the local runtime. The production Worker verifies Apple's signature, issuer, configured audience, expiration and nonce.

| Check | Result |
| --- | --- |
| Worker type checking and local integration | TypeScript passed. All 10 tests passed. |
| SDK build and tests | TypeScript passed. All 13 tests passed, including Swift-to-JavaScript and JavaScript-to-Swift fixtures. |
| iOS tests | Swift Testing ran 2,912 tests across 322 suites. All passed. |
| Cross-device convergence | On an iPhone simulator and an iPad simulator, both app test hosts passed. An independent SDK client verified the merged edits, dose group and tombstone against the same Worker. |
| Legacy SwiftData migration | A separate process wrote a store with the original 17 models. The new 19-model schema preserved the dose, session relationship and both schedules for one substance. Backfilled schedule IDs remained distinct after reopening. |
| Photo replication | Independent tests exercised both delivery orders, reuse of an earlier photo, and the 1 MB input limit. The local Worker stored the Swift-generated metadata and photo as separate encrypted R2 records. |
| Keychain availability | Injected Security errors exercised locked-keychain handling. |
| Recovery and authorization | The two-simulator test exercises separate owner devices, a writable SDK token, acknowledged revocation, a sealed offline write crossing rotation, and recovery into a new profile. |
| Relay confidentiality | The end-to-end test scans D1 rows and R2 objects for known private field names and synthetic plaintext markers. |
| Release archive | Xcode archived Piru 1.10 build 81 for iOS with signing disabled. The weak-import gate reported zero errors and zero warnings across the app and four companion binaries. The bundled substance database matched the tracked SHA-256 and the archive included the Automerge license. |
| SDK handoff | The packed SDK installed and imported in a fresh Node project. The package contains JavaScript, TypeScript declarations and read/write examples. |

The relay can observe account associations, grant metadata, timing, ciphertext sizes, and stable opaque document IDs. A client receiving a read grant obtains access to the entire linked profile. Revocation protects future writes under the new key. Material already decrypted by a recipient remains with that recipient.

On the iOS simulator, initial capture of 3,000 synthetic doses took 3.26 s and produced 1,560,472 bytes of serialized Automerge documents. A subsequent idle history capture took 0.73 ms. Capturing a single note edit took 2.93 ms and produced a 1,135-byte signed JSON envelope. The timings cover local capture. The envelope size excludes HTTP and TLS overhead.

A separate 3,000-dose SwiftData run measured the foreground monitor against an instrumented local transport. In 69 seconds it issued four feed reads, two during startup and two at roughly 30-second intervals. It sent zero uploads, wrote zero additional history transactions and made zero requests in the 36 seconds after cancellation.

Ten fresh-process launches of the unlinked 3,000-dose journal on an iPhone 17 Pro Max simulator reached the Debug startup marker in 6.61 s median and 39.44 s p95. This includes host, simulator and console overhead. The Release archive was compiling during every sample. All ten screenshots showed Journal navigation and seven already showed dose rows. Time to a fully populated timeline was unmeasured. The attempted Instruments first-frame trace timed out.

The local handoff directory is `output/release-candidate/`. It contains the unsigned device archive, a Debug simulator app configured for the local Worker, the SDK tarball, Xcode results, Worker and SDK logs, and launch evidence. Live Apple sign-in and physical-device iCloud Keychain recovery remain unverified. A signed device build requires provisioning and an HTTPS relay URL. No build or service was deployed.

The reproducible test commands are in the [sync guide](../README.md). Cross-platform fixture inputs are in [the fixture directory](../fixtures).
