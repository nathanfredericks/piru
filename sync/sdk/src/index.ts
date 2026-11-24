import * as A from "@automerge/automerge";
import {
  checkpointKey,
  openGrantLabel,
  docID,
  openDocument,
  publicKey,
  randomBytes,
  sealDocument,
  unwrapKeys,
  verifyEnvelope,
} from "./crypto.js";
import { validateRecordFields, type JournalSchema } from "./schema.js";
export type {
  DoseFields,
  DoseGroup,
  SessionNoteFields,
  JournalSchema,
} from "./schema.js";
import { inspect, patch } from "./record.js";
import type { RecordDoc } from "./record.js";
import {
  b64,
  bytes,
  check,
  decodeText,
  decodeToken,
  kindName,
  natural,
  object,
  utf8,
  uuid,
  validateHeader,
} from "./wire.js";
import type {
  Directory,
  Envelope,
  Fields,
  Grant,
  RecordValue,
  Token,
} from "./wire.js";
export * from "./wire.js";
export {
  docID,
  openDocument,
  sealDocument,
  issueGrant,
  openGrantLabel,
  sealGrantLabel,
  keyPair,
  publicKey,
  wrapKeys,
  unwrapKeys,
  encryptToken,
  decryptToken,
} from "./crypto.js";

export interface ClientOptions {
  fetch?: typeof fetch;
  checkpoint?: string;
  /** Atomically replace the previous checkpoint. Called before sending a pending operation. */
  saveCheckpoint?: (encrypted: string) => Promise<void>;
  /** Validate a materialized live record against the application's domain schema. */
  validate?: (record: RecordValue) => void;
}
interface ResolvedDirectory {
  signers: Map<string, Grant>;
  keys?: Uint8Array<ArrayBuffer>;
}
export class RelayError extends Error {
  constructor(public readonly status: number) {
    super("Sync relay returned HTTP " + status);
  }
}

/** A single serialized writer per checkpoint. Each device opens an independent client. */
export class JournalSync<Schema extends object = JournalSchema> {
  #token: Token;
  #options: ClientOptions;
  #key!: CryptoKey;
  #ownSign = "";
  #ownBox = "";
  #docs = new Map<string, RecordDoc>();
  #directories = new Map<number, ResolvedDirectory>();
  #epoch = 0;
  #feedEpoch = 0;
  #indexKey?: string;
  #cursor = 0;
  #pending?: Envelope;
  #tail: Promise<unknown> = Promise.resolve();

  private constructor(token: string, options: ClientOptions) {
    this.#token = decodeToken(token);
    this.#options = options;
  }
  static async open<S extends object = JournalSchema>(
    compoundToken: string,
    options: ClientOptions = {},
  ) {
    const client = new JournalSync<S>(compoundToken, options);
    const t = client.#token;
    [client.#key, client.#ownSign, client.#ownBox] = await Promise.all([
      checkpointKey(t),
      publicKey(t.signPrivate),
      publicKey(t.boxPrivate),
    ]);
    if (options.checkpoint) await client.#restore(options.checkpoint);
    await client.sync();
    return client;
  }
  get cursor() {
    return this.#cursor;
  }
  #serial<T>(operation: () => Promise<T>): Promise<T> {
    const next = this.#tail.then(operation, operation);
    this.#tail = next.catch(() => {});
    return next;
  }
  async #request(path: string, body?: Envelope) {
    const t = this.#token;
    const url = new URL("/v1/profiles/" + t.profileID + path, t.url);
    const response = await (this.#options.fetch ?? fetch)(url, {
      method: body ? "POST" : "GET",
      redirect: "error",
      credentials: "omit",
      cache: "no-store",
      headers: {
        Authorization: "Bearer " + t.bearer,
        ...(body && { "Content-Type": "application/json" }),
      },
      body: body && JSON.stringify(body),
    });
    if (!response.ok) throw new RelayError(response.status);
    return response.json();
  }
  async #directory(
    epoch?: number,
    signerID?: string,
  ): Promise<ResolvedDirectory> {
    const cached = epoch && this.#directories.get(epoch);
    // Grants can be enrolled after this epoch was cached, even between feed pages.
    if (cached && (signerID === undefined || cached.signers.has(signerID)))
      return cached;
    const d: Directory = await this.#request(
      "/grants" + (epoch ? "?epoch=" + epoch : ""),
    );
    natural(d.epoch);
    check(
      epoch ? d.epoch === epoch : d.epoch >= this.#epoch,
      "Unexpected directory epoch",
    );
    check(Array.isArray(d.grants), "Invalid grant directory");
    const signers = new Map<string, Grant>();
    for (const g of d.grants) {
      uuid(g.id);
      check(
        !signers.has(g.id) && ["owner", "read", "write"].includes(g.scope),
        "Invalid grant directory entry",
      );
      bytes(g.signPublic, 65);
      bytes(g.boxPublic, 65);
      signers.set(g.id, g);
    }
    const own = signers.get(this.#token.grantID);
    if (own)
      check(
        own.signPublic === this.#ownSign && own.boxPublic === this.#ownBox,
        "Token key mismatch",
      );
    if (!epoch || epoch === this.#epoch)
      check(own?.wrapped && !own.revoked, "Grant unavailable");
    const keys = own?.wrapped
      ? await unwrapKeys(this.#token, d.epoch, own.wrapped)
      : undefined;
    const index = keys ? b64(keys.slice(32)) : this.#indexKey;
    check(
      index && (!this.#indexKey || this.#indexKey === index),
      "Inconsistent profile index key",
    );
    // Authenticate the key bundle against the token-pinned signing key before accepting
    // any signer or caching the stable index key, including on first enrollment.
    await Promise.all(
      d.grants.map((g) =>
        openGrantLabel(this.#token.profileID, g, bytes(index, 32)),
      ),
    );
    this.#indexKey = index;
    if (!epoch) this.#epoch = d.epoch;
    const entry = { signers, keys };
    this.#directories.set(d.epoch, entry);
    return entry;
  }
  async #merge(e: Envelope, directory: ResolvedDirectory) {
    const signer = directory.signers.get(e.grantID);
    check(
      signer &&
        !signer.revoked &&
        signer.scope !== "read" &&
        (signer.since === undefined || signer.since <= e.epoch),
      "Unauthorized envelope signer",
    );
    // A later grant can read exactly the historical epochs wrapped for it.
    if (!directory.keys) {
      await verifyEnvelope(e, signer.signPublic);
      return;
    }
    const raw = await openDocument(
      e,
      directory.keys.slice(0, 32),
      signer.signPublic,
    );
    const incoming: RecordDoc = A.load(raw);
    const r = inspect(incoming);
    check(
      (await docID(directory.keys.slice(32), r.kind, r.recordID)) === e.docID,
      "Record identity mismatch",
    );
    const prior = this.#docs.get(e.docID);
    const next = prior ? A.merge(A.clone(prior), incoming) : incoming;
    const merged = inspect(next);
    check(
      merged.kind === r.kind &&
        merged.recordID === r.recordID &&
        (!prior?._deleted || merged.deleted),
      "Invalid record merge",
    );
    if (!merged.deleted) {
      validateRecordFields(merged);
      this.#options.validate?.(merged);
    }
    this.#docs.set(e.docID, next);
  }
  async #pull() {
    await this.#directory();
    while (true) {
      const page = await this.#request("/changes?after=" + this.#cursor);
      check(
        Array.isArray(page.changes) &&
          typeof page.hasMore === "boolean" &&
          (!page.hasMore || page.changes.length > 0),
        "Invalid feed page",
      );
      let last = this.#cursor;
      for (const change of page.changes) {
        natural(change.seq);
        check(change.seq === last + 1, "Unordered or incomplete feed");
        last = change.seq;
      }
      check(page.cursor === last, "Invalid feed cursor");
      for (const { seq, envelope: e } of page.changes) {
        validateHeader(e);
        check(e.profileID === this.#token.profileID, "Wrong profile");
        if (e.epoch > this.#epoch) await this.#directory();
        check(e.epoch <= this.#epoch, "Unknown feed epoch");
        check(e.epoch >= this.#feedEpoch, "Feed epoch went backwards");
        if (e.opID === this.#pending?.opID)
          check(
            e.signature === this.#pending?.signature,
            "Operation ID collision",
          );
        await this.#merge(e, await this.#directory(e.epoch, e.grantID));
        this.#cursor = seq;
        this.#feedEpoch = e.epoch;
        if (e.opID === this.#pending?.opID) {
          this.#pending = undefined;
        }
      }
      await this.#persist();
      if (!page.hasMore) return;
    }
  }
  async #flush(current?: ResolvedDirectory) {
    const pending = this.#pending;
    if (!pending) return;
    current ??= await this.#directory();
    check(
      current.signers.get(this.#token.grantID)?.scope !== "read",
      "Read-only grant",
    );
    if (pending.epoch !== this.#epoch) {
      // A lost acknowledgement may already be in the feed under the old epoch.
      await this.#pull();
      if (!this.#pending) return;
      current = await this.#directory(this.#epoch);
      const old = await this.#directory(pending.epoch);
      check(old.keys && current.keys, "Missing pending-operation keys");
      const raw = await openDocument(
        pending,
        old.keys.slice(0, 32),
        this.#ownSign,
      );
      const { profileID, docID, opID, grantID } = pending;
      this.#pending = await sealDocument(
        { profileID, docID, opID, grantID, epoch: this.#epoch },
        current.keys.slice(0, 32),
        this.#token.signPrivate,
        raw,
      );
    }
    await this.#persist();
    const e = this.#pending!;
    const receipt = await this.#request("/changes", e);
    natural(receipt.seq);
    await this.#merge(e, await this.#directory(e.epoch));
    this.#pending = undefined;
    await this.#persist();
  }
  /** Replay pending writes, then merge all available feed pages. */
  sync() {
    return this.#serial(async () => {
      await this.#flush();
      await this.#pull();
    });
  }
  retry() {
    return this.sync();
  }
  read<K extends keyof Schema & string>(
    kind: K,
    recordID: string,
  ): RecordValue<Schema[K]> | undefined {
    uuid(recordID);
    return this.list(kind).find((row) => row.recordID === recordID);
  }
  list<K extends keyof Schema & string>(kind: K): RecordValue<Schema[K]>[] {
    kindName(kind);
    const rows: RecordValue<Schema[K]>[] = [];
    for (const doc of this.#docs.values()) {
      if (doc.kind.val !== kind || doc._deleted) continue;
      const { fields, recordID } = inspect(doc);
      rows.push({ kind, recordID, fields: fields as Schema[K] });
    }
    return rows.sort((a, b) => a.recordID.localeCompare(b.recordID));
  }
  write<K extends keyof Schema & string>(
    kind: K,
    recordID: string,
    fields: Partial<Schema[K]>,
  ) {
    return this.#edit(kind, recordID, fields as Fields);
  }
  delete<K extends keyof Schema & string>(kind: K, recordID: string) {
    return this.#edit(kind, recordID, null);
  }
  #edit(kind: string, recordID: string, fields: Fields | null) {
    return this.#serial(async () => {
      await this.#flush();
      const d = await this.#directory();
      check(
        d.keys && d.signers.get(this.#token.grantID)?.scope !== "read",
        "Read-only grant",
      );
      const id = await docID(d.keys.slice(32), kind, recordID);
      const next = patch(this.#docs.get(id), kind, recordID, fields);
      const record = inspect(next);
      if (!record.deleted) {
        validateRecordFields(record);
        this.#options.validate?.(record);
      }
      const opID = crypto.randomUUID();
      this.#pending = await sealDocument(
        {
          profileID: this.#token.profileID,
          docID: id,
          grantID: this.#token.grantID,
          epoch: this.#epoch,
          opID,
        },
        d.keys.slice(0, 32),
        this.#token.signPrivate,
        A.save(next),
      );
      await this.#flush(d);
      return opID;
    });
  }
  checkpoint() {
    return this.#serial(() => this.#snapshot());
  }
  async #snapshot() {
    const iv = randomBytes(12);
    const state = {
      cursor: this.#cursor,
      feedEpoch: this.#feedEpoch,
      epoch: this.#epoch,
      index: this.#indexKey,
      pending: this.#pending,
      docs: Array.from(this.#docs, ([id, doc]) => [id, b64(A.save(doc))]),
    };
    const ct = await crypto.subtle.encrypt(
      { name: "AES-GCM", iv },
      this.#key,
      utf8(JSON.stringify(state)),
    );
    return ["pirucp1", b64(iv), b64(ct)].join(".");
  }
  async #persist() {
    if (this.#options.saveCheckpoint)
      await this.#options.saveCheckpoint(await this.#snapshot());
  }
  async #restore(checkpoint: string) {
    const [v, nonce, ct, ...rest] = checkpoint.split(".");
    check(v === "pirucp1" && !rest.length, "Invalid checkpoint");
    const raw = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: bytes(nonce, 12) },
      this.#key,
      bytes(ct),
    );
    const state = JSON.parse(decodeText(raw));
    natural(state.cursor, 0);
    natural(state.epoch, 0);
    check(
      object(state) && Array.isArray(state.docs),
      "Invalid checkpoint payload",
    );
    this.#cursor = state.cursor as number;
    this.#epoch = state.epoch as number;
    natural(state.feedEpoch, 0);
    this.#feedEpoch = state.feedEpoch;
    this.#indexKey = state.index as string | undefined;
    this.#pending = state.pending as Envelope | undefined;
    for (const [id, rawDoc] of state.docs)
      this.#docs.set(id, A.load(bytes(rawDoc)));
  }
}
