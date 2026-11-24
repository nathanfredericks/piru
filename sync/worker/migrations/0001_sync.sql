CREATE TABLE accounts (id TEXT PRIMARY KEY, apple_subject TEXT NOT NULL UNIQUE);
CREATE TABLE challenges (nonce_hash TEXT PRIMARY KEY, expires INTEGER NOT NULL);
CREATE TABLE sessions (digest TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts, expires INTEGER NOT NULL);
CREATE INDEX sessions_expiry ON sessions(expires);
CREATE INDEX challenges_expiry ON challenges(expires);
CREATE TABLE profiles (
  id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts,
  anchor_id TEXT NOT NULL, epoch INTEGER NOT NULL CHECK(epoch >= 1), recovery TEXT NOT NULL
);
CREATE INDEX profiles_account ON profiles(account_id,id);
CREATE TABLE grants (
  profile TEXT NOT NULL REFERENCES profiles ON DELETE CASCADE, id TEXT NOT NULL,
  scope TEXT NOT NULL CHECK(scope IN ('owner','read','write')),
  digest TEXT NOT NULL UNIQUE, sign_public TEXT NOT NULL, box_public TEXT NOT NULL,
  label_box TEXT NOT NULL, since INTEGER NOT NULL, revoked INTEGER,
  PRIMARY KEY(profile,id)
);
CREATE TABLE wraps (
  profile TEXT NOT NULL, grant_id TEXT NOT NULL, epoch INTEGER NOT NULL, wrapped TEXT NOT NULL,
  PRIMARY KEY(profile,grant_id,epoch),
  FOREIGN KEY(profile,grant_id) REFERENCES grants(profile,id) ON DELETE CASCADE
);
-- A change row is also the permanent op receipt. Blobs are immutable by digest.
CREATE TABLE changes (
  seq INTEGER NOT NULL, profile TEXT NOT NULL REFERENCES profiles ON DELETE CASCADE,
  op_id TEXT NOT NULL, digest TEXT NOT NULL, blob TEXT NOT NULL, size INTEGER NOT NULL, PRIMARY KEY(profile,seq), UNIQUE(profile,op_id)
);
CREATE TABLE uploads (blob TEXT PRIMARY KEY, expires INTEGER NOT NULL);
CREATE INDEX uploads_expiry ON uploads(expires);
CREATE TABLE management_receipts (
  profile TEXT NOT NULL REFERENCES profiles ON DELETE CASCADE, request_id TEXT NOT NULL,
  actor TEXT NOT NULL, digest TEXT NOT NULL, response TEXT NOT NULL, PRIMARY KEY(profile,request_id)
);
-- A deleted ID stays reserved; the delete receipt survives cascading profile removal.
CREATE TABLE deletions (
  profile TEXT PRIMARY KEY, account_id TEXT NOT NULL, owner_digest TEXT NOT NULL,
  request_id TEXT NOT NULL, purge_after INTEGER NOT NULL, purged INTEGER NOT NULL DEFAULT 0
);
-- A failed assertion aborts the entire D1 batch, including any preceding writes.
CREATE TABLE assertions (ok INTEGER NOT NULL CONSTRAINT precondition CHECK(ok=1));
CREATE TRIGGER clear_assertion AFTER INSERT ON assertions BEGIN DELETE FROM assertions; END;
