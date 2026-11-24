# Piru sync v1

All paths below are relative to /v1. IDs are lowercase UUIDs except docID, a base64url HMAC-SHA256 (32 bytes). All binary fields are canonical unpadded base64url. All success and error responses are JSON; errors have an error string. Apple sessions and grant bearers are separate random 32-byte values. Authorization: Bearer carries the credential for the endpoint.

| Route | Credentials | Body | Success |
|---|---|---|---|
| POST /auth/nonce | none | none | {nonce} |
| POST /auth/apple | none | {identityToken,nonce} | {session,accountID} |
| GET /profiles | session | | {profiles:[{profileID,epoch,anchorGrantID}]} |
| POST /profiles | session | {profileID,grant,bearer,recoveryBox} | {epoch:1} |
| POST /profiles/:p/grants | session + X-Owner-Bearer | {epoch,grant,bearer,history?:[{epoch,wrapped}]} | {epoch} |
| POST /profiles/:p/rotate | session + X-Owner-Bearer | {epoch,revoke:[grantID],wraps:[{grantID,wrapped}],recoveryBox} | {epoch:newEpoch} |
| PUT /profiles/:p/recovery | session + X-Owner-Bearer | {epoch,recoveryBox} | {epoch} |
| DELETE /profiles/:p | session + X-Owner-Bearer + Idempotency-Key | none | {deleted:true} |
| GET /profiles/:p/recovery | session | | {epoch,recoveryBox} |
| GET /profiles/:p/grants?epoch=N | active grant | | {epoch,anchorGrantID,grants} |
| POST /profiles/:p/changes | active owner/write grant | signed envelope | {seq} |
| GET /profiles/:p/changes?after=N | active grant | | {changes:[{seq,envelope}],cursor,hasMore} |

Generate the Apple request nonce as lowercase hex SHA256(UTF8(nonce)). The Worker verifies the Apple signature, issuer, configured audience, expiry and nonce. Challenges are single-use. Account ownership comes from the verified Apple subject. Management writes require an Idempotency-Key header (lowercase UUID); retry the identical request with the same key. Feed writes use opID directly. Session recovery only returns an opaque client-encrypted package (recoveryBox, base64url, up to 64 KiB decoded); its separate recovery secret never reaches the Worker. To restore on another device, sign in as the same Apple account, list profiles, download and decrypt the recovery box. The client package must permit restoration of owner grant credentials and decryption of retained history. A lost recovery secret and lost owner device cannot be replaced by Apple sign-in alone.

The bootstrap owner is the immutable recovery anchor. Additional owner grants can administer the profile and may be revoked. Rotations require an epoch match, the anchor as a survivor, and exactly one fresh wrap per survivor. Omit revoked grants from wraps. The recoveryBox must reflect the new epoch. Empty revoke rotates without revoking. A new grant receives only explicitly wrapped epochs. A historical directory includes public keys of signers active at the requested epoch and, if supplied later, the requesting grant's own historical wrap. Other grants' wraps are always omitted. Use the epoch of each envelope when looking up historical signers. Old ciphertext and previously distributed keys cannot be recalled.

Grant: {id,scope,signPublic,boxPublic,labelBox,wrapped:{enc,ct}}. Raw uncompressed P256 public keys are 65 bytes. HPKE wraps are enc=65 and ct=80 bytes for the 64-byte content-key + stable-index-key plaintext. The service accepts only opaque keys/labels/recovery data. Never send the compound SDK token, private keys, plaintext labels or decrypted Automerge data.

**Grant label encoding.** Both clients use the stable 32-byte profile index key for labels across epochs. In the following expressions, `b64u` means unpadded base64url, `||` concatenates bytes, and `\n` is one LF byte. Public keys in the context are their wire-format strings. There is no trailing LF.

```text
domain    = "piru-sync-grant-label-v1"
labelKey  = HKDF-SHA256(ikm=indexKey, salt=empty bytes, info=UTF8(domain), length=32)
context   = [domain, profileID, id, scope, signPublic, boxPublic].join("\n")
aad       = UTF8(context)
message   = UTF8(context + "\n" + b64u(SHA256(indexKey)))
proof     = b64u(ECDSA-P256-SHA256(signPrivate, message))   # raw 64-byte r || s
plaintext = UTF8(JSON.stringify({label, proof}))
nonce     = 12 fresh random bytes
(ciphertext, tag) = AES-256-GCM.seal(labelKey, nonce, plaintext, aad)
labelBox  = b64u(nonce || ciphertext || tag)                # 16-byte tag
```

Consumers pin their own grant's signing and box public keys to the keys derived from their local token. To accept a label, authenticate and decrypt the box with the grant context, parse the two JSON strings, and verify the proof over `message` using that grant's `signPublic`. JSON member order is immaterial. The Worker checks the base64url encoding and decoded size (1–4096 bytes) and stores the opaque box. Clients perform all decryption and proof verification.

Envelope: {profileID,docID,opID,grantID,epoch,nonce,ciphertext,signature}. Nonce is 12 bytes, ciphertext includes its 16-byte GCM tag. Raw64 ECDSA P256-SHA256 signs UTF8 of newline-joined piru-sync-v1, profileID, docID, opID, grantID, decimal epoch, nonce, ciphertext. The first six lines are the AES-GCM AAD. Each op contains the encrypted full incremental Automerge document. Consumers verify before decrypting and merge every envelope, including concurrent versions of the same document. The encrypted _deleted field represents a tombstone.

The accountID is a stable opaque UUID for the Apple subject. The account session expires after 30 days. Nonces expire after five minutes. The grant bearer digest is SHA256 of the decoded 32 bytes. The client never sends a compound SDK token. Deleting a profile atomically removes access and D1 data; scheduled cleanup purges its R2 prefix. The profile ID stays reserved for delete replay. Same-account recovery and management return 404/403 on wrong ownership.

Feed sequences start at 1 per profile. after defaults to 0. Optional limit=1..100, default 16; pages also have a 4 MiB encoded envelope budget. Consumers must use hasMore and cursor, including after short pages. Maximum ciphertext is 2 MiB per operation. R2 stores signed envelopes. Full aligned 16-operation replay segments can be served from R2 checkpoints. Checkpoints preserve every operation in order. The feed remains the same API for initial restore and incremental reads. A noncurrent epoch returns 409 even for a previous op receipt; revoked credentials lose all access. A reused opID with different envelope bytes returns 409. Reuse the identical signed envelope after an ambiguous write.

Staging D1 ID is a placeholder. Local development uses npm ci, npm run migrate:local, npm run dev, npm run typecheck and npm test from this directory. Integration tests use isolated local workerd, D1 and R2 and substitute an in-process Apple JWKS endpoint. No cloud credentials are required.
