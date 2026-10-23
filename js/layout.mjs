// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//
// The layout half of the Bun port: FORMAT.md § 3–§ 8 and § 12 — the constants, the 64-byte entry codec, the
// sidekick document and the validation rules. `fsmeta.mjs` adds the file system side (scan, publish, diff,
// repair) on top of it, the way the Java port splits FsMetaCodec/FsMetaConfig/FsMetaValidator from
// FsMetaScanner/FsMetaWriter/FsMetaDiff.
//
// A u64 field is a BigInt here and a `long` in Java: a content hash does not fit in a double, and the entry
// is unsigned on the wire, so BigInt is the honest representation rather than a lossy Number. `hex64`
// formats one the way the documents and the CLI do.

// The one hash, from the project that owns it: `wyhash` defines the algorithm, its reference is the Zig
// builtin, and this port asserts the same vectors as that project (plus its own, which pin the hash as part of
// this format's contract). `fs-meta` has no hash implementation of its own on purpose — a second copy would be
// a second thing to keep equal to the first.
// The one hash, and the reference implementation of it, when the runtime has one.
//
// Bun is built on Zig, and `Bun.hash.wyhash` is the same `std.hash.Wyhash` the engine calls: it agrees with the
// JS port bit-for-bit on empty input, on short strings, on a 4 KiB buffer, and above 2^53 (it returns a bigint).
// So under Bun there is no second implementation to drift — the native function is used directly, and Node and CI
// fall back to the JS port. The export names are unchanged, so every call site in this module and its consumers
// keeps working.
const nativeWyhash = globalThis.Bun?.hash?.wyhash ?? null;
if (!nativeWyhash) {
  throw new Error(
    'the fs-meta Bun/Node port hashes with Bun.hash.wyhash, which is the same std.hash.Wyhash the engine calls. ' +
      'Run it under Bun, or supply the wyhash project\'s JavaScript port explicitly: the published wyhash repository ' +
      'ships only the Java implementation today.',
  );
}
const jsWyhash = null;

/** wyhash of `bytes`, seed 0 by default: Bun’s built-in under Bun, the JS port everywhere else. */
export const wyhash64 = (bytes, seed = 0n) =>
  nativeWyhash ? BigInt(nativeWyhash(bytes, Number(seed))) : jsWyhash.wyhash64(bytes, seed);

/** `wyhash64`, as sixteen hex characters. */
export const wyhash64Hex = (bytes, seed = 0n) =>
  nativeWyhash ? BigInt(nativeWyhash(bytes, Number(seed))).toString(16).padStart(16, '0') : jsWyhash.wyhash64Hex(bytes, seed);

/** Which implementation answers `wyhash64` here — reported by the port so a run says what it used. */
export const wyhashProvider = () => (nativeWyhash ? 'bun (native std.hash.Wyhash)' : 'js port (wyhash/js/wyhash64.mjs)');

export const FORMAT = 'fs-meta';
export const VERSION = 1;
export const ENTRY_SIZE = 64;
export const DIRECTORY_NAME = '.fs-meta';
export const META_FILE = 'files.meta';
export const TXT_FILE = 'files.txt';
export const JSON_FILE = 'files.json';
export const ORDER = 'utf8-bytes';
export const HASH_ALGO = 'wyhash64';
export const HASH_SEED = 0;
export const LF = 0x0a;

export const FLAG_CONTENT_KNOWN = 0x01;
export const FLAG_REGULAR_FILE = 0x02;
/** A directory entry (§ 6): listed for its mtime, never carrying a content hash. */
export const FLAG_IS_DIR = 0x04;
/** The hash was taken over LF-normalised bytes (§ 12). */
export const FLAG_HASH_LF = 0x08;
/** A symlink, listed and never followed (§ 16). */
export const FLAG_SYMLINK = 0x10;
/** Exactly one of these must be set on every entry. */
export const FLAG_TYPE_MASK = FLAG_REGULAR_FILE | FLAG_IS_DIR | FLAG_SYMLINK;
export const FLAG_KNOWN_MASK = FLAG_CONTENT_KNOWN | FLAG_TYPE_MASK | FLAG_HASH_LF;

export const HASH_MODES = ['none', 'lf', 'text'];

/** Every verdict this version defines, in the order the vectors use them. */
export const VERDICTS = [
  'ok',
  'unsupported-format',
  'unsupported-version',
  'unsupported-entry-size',
  'unsupported-hash',
  'meta-size-mismatch',
  'txt-size-mismatch',
  'entry-out-of-range',
  'name-hash-mismatch',
];

/** The format's name order (§ 3): unsigned byte comparison of the UTF-8 encoding, i.e. `memcmp`. */
export const compareNames = (left, right) => Buffer.compare(Buffer.from(left, 'utf8'), Buffer.from(right, 'utf8'));

/** The UTF-8 byte length of a name, which is its `nameLength` in an entry. */
export const utf8Length = (name) => Buffer.byteLength(name, 'utf8');

/** Entry count of a `files.meta`: a shift, not a division. Throws when the size is not a whole entry. */
export function entryCount(metaBytes) {
  if (metaBytes < 0 || metaBytes % ENTRY_SIZE !== 0) {
    throw new Error(`files.meta is ${metaBytes} bytes, which is not a whole number of ${ENTRY_SIZE}-byte entries`);
  }
  return metaBytes / ENTRY_SIZE;
}

/** The byte offset of entry `index`: `index << 6`. */
export function entryOffset(index) {
  return index * ENTRY_SIZE;
}

export const contentKnown = (entry) => (entry.flags & FLAG_CONTENT_KNOWN) !== 0;
export const hashLf = (entry) => (entry.flags & FLAG_HASH_LF) !== 0;

/** § 6: an unknown flag bit means the entry's fingerprint is not to be trusted. */
export const trusted = (entry) => (entry.flags & ~FLAG_KNOWN_MASK) === 0;

/** § 11 step 2: whether there is a fingerprint to compare at all. */
export const usableFingerprint = (entry) => trusted(entry) && contentKnown(entry);

/** The 16 lowercase hex characters a hash is written as. */
export function hex64(value) {
  return BigInt.asUintN(64, BigInt(value)).toString(16).padStart(16, '0');
}

// ------------------------------------------------------------------ the entry codec

/** A u64 as the wire wants it: an unsigned BigInt in `[0, 2^64)`. A negative input wraps rather than throwing. */
const u64 = (value) => BigInt.asUintN(64, BigInt(value));

/**
 * The 64 bytes of one entry at `offset` in `buffer`.
 *
 * Every u64 is wrapped to its unsigned form, because that is what the wire holds and what a caller comparing
 * an entry against `wyhash64(...)` sees: `putEntry` with a negative value writes the same bytes as Java's
 * `long`, and reading them back gives the unsigned BigInt rather than an error.
 */
export function putEntry(buffer, offset, entry) {
  const at = Number(offset);
  buffer.writeBigUInt64LE(u64(entry.mtimeMillis), at + 0); // mtime in ns on the wire (§ 5)
  buffer.writeBigUInt64LE(u64(entry.sizeBytes), at + 8);
  buffer.writeBigUInt64LE(u64(entry.contentHash), at + 16);
  buffer.writeBigUInt64LE(u64(entry.nameHash), at + 24);
  buffer.writeBigUInt64LE(u64(entry.nameOffset), at + 32);
  buffer.writeUInt32LE(entry.nameLength, at + 40);
  buffer.writeUInt32LE(entry.flags, at + 44);
  buffer.writeBigUInt64LE(u64(entry.fileId ?? 0n), at + 48);
  buffer.writeBigUInt64LE(u64(entry.reserved ?? 0n), at + 56);
}

/** One entry read from `buffer` at `offset`. */
export function getEntry(buffer, offset) {
  const at = Number(offset);
  return {
    mtimeMillis: buffer.readBigUInt64LE(at + 0),
    sizeBytes: buffer.readBigUInt64LE(at + 8),
    contentHash: buffer.readBigUInt64LE(at + 16),
    nameHash: buffer.readBigUInt64LE(at + 24),
    nameOffset: buffer.readBigUInt64LE(at + 32),
    nameLength: buffer.readUInt32LE(at + 40),
    flags: buffer.readUInt32LE(at + 44),
    fileId: buffer.readBigUInt64LE(at + 48),
    reserved: buffer.readBigUInt64LE(at + 56),
  };
}

/** The whole `files.meta` for `entries`, in the order given. */
export function encodeEntries(entries) {
  const buffer = Buffer.alloc(entries.length * ENTRY_SIZE);
  entries.forEach((entry, index) => putEntry(buffer, entryOffset(index), entry));
  return buffer;
}

/** The entries of a `files.meta`. Throws when the size is not a whole number of entries. */
export function decodeEntries(meta) {
  const count = entryCount(meta.length);
  const entries = [];
  for (let index = 0; index < count; index++) {
    entries.push(getEntry(meta, entryOffset(index)));
  }
  return entries;
}

/** `files.txt` for `names`: every name followed by LF, including the last (§ 4). */
export function encodeNames(names) {
  const parts = [];
  let bytes = 0;
  for (const name of names) {
    const encoded = Buffer.from(name, 'utf8');
    parts.push(encoded, Buffer.from([LF]));
    bytes += encoded.length + 1;
  }
  return Buffer.concat(parts, bytes);
}

/** One entry for a hashed regular file. */
export function entryForFile(name, mtimeMillis, sizeBytes, contentHash, nameOffset, lfNormalised) {
  return {
    mtimeMillis: BigInt(mtimeMillis),
    nameHash: nameHashOf(name),
    contentHash: BigInt(contentHash),
    sizeBytes: BigInt(sizeBytes),
    nameOffset: BigInt(nameOffset),
    nameLength: utf8Length(name),
    flags: FLAG_CONTENT_KNOWN | FLAG_REGULAR_FILE | (lfNormalised ? FLAG_HASH_LF : 0),
    fileId: 0n,
    reserved: 0n,
  };
}

/** A listing-only entry (§ 6): the name is known, no fingerprint was taken. */
export function listingOnlyEntry(name, nameOffset) {
  return {
    mtimeMillis: 0n,
    nameHash: nameHashOf(name),
    contentHash: 0n,
    sizeBytes: 0n,
    nameOffset: BigInt(nameOffset),
    nameLength: utf8Length(name),
    flags: FLAG_REGULAR_FILE,
    fileId: 0n,
    reserved: 0n,
  };
}

// ------------------------------------------------------------------ hashing (§ 12)

export const nameHashOf = (name) => wyhash64(Buffer.from(name, 'utf8'));

/** `\r\n` and a lone `\r` become `\n`; every other byte is untouched. */
export function normalizeLf(bytes) {
  const out = Buffer.alloc(bytes.length);
  let at = 0;
  for (let i = 0; i < bytes.length; i++) {
    if (bytes[i] === 0x0d) {
      out[at++] = LF;
      if (i + 1 < bytes.length && bytes[i + 1] === LF) {
        i++;
      }
    } else {
      out[at++] = bytes[i];
    }
  }
  return out.subarray(0, at);
}

/** Whether content looks like text: no NUL byte, the test git applies before treating a file as text. */
export function looksLikeText(bytes) {
  return !bytes.includes(0);
}

/** Hashes content under a mode, deciding per file for `text`. */
export function hashBytes(bytes, mode = 'text') {
  const normalise = mode === 'lf' || (mode === 'text' && looksLikeText(bytes));
  return normalise
    ? { hash: wyhash64(normalizeLf(bytes)), lfNormalised: true }
    : { hash: wyhash64(bytes), lfNormalised: false };
}

/** The content hash of a text fixture, for a test or a tool. */
export const contentHashOf = (bytes) => wyhash64Hex(bytes);

// ------------------------------------------------------------------ the sidekick document (§ 7)

const REQUIRED_KEYS = ['format', 'version', 'entrySize', 'count', 'meta', 'txt', 'hash'];
const KNOWN_KEYS = ['format', 'version', 'entrySize', 'order', 'generation', 'count', 'meta', 'txt', 'hash',
  'updated', 'writer', 'created', 'root'];

/**
 * Parses a `files.json`.
 *
 * Throws when the text is not JSON, or a required key is missing or has the wrong type — the caller reports
 * that as `unsupported-format`, exactly as § 8 check 1 says.
 */
export function parseConfig(text) {
  let document;
  try {
    document = JSON.parse(text);
  } catch (malformed) {
    throw new Error(`files.json is not JSON: ${malformed.message}`);
  }
  if (document === null || typeof document !== 'object' || Array.isArray(document)) {
    throw new Error('files.json must be a JSON object');
  }
  for (const key of REQUIRED_KEYS) {
    if (!(key in document)) {
      throw new Error(`files.json is missing '${key}'`);
    }
  }
  const meta = requireObject(document, 'meta');
  const txt = requireObject(document, 'txt');
  const hash = requireObject(document, 'hash');

  const extra = {};
  for (const [key, value] of Object.entries(document)) {
    if (!KNOWN_KEYS.includes(key)) {
      extra[key] = value;
    }
  }

  return {
    format: requireString(document, 'format'),
    version: requireInteger(document, 'version'),
    entrySize: requireInteger(document, 'entrySize'),
    order: typeof document.order === 'string' ? document.order : ORDER,
    generation: document.generation === undefined ? 0 : requireInteger(document, 'generation'),
    count: requireInteger(document, 'count'),
    meta: { bytes: requireInteger(meta, 'bytes'), wyhash: typeof meta.wyhash === 'string' ? meta.wyhash : null },
    txt: { bytes: requireInteger(txt, 'bytes'), wyhash: typeof txt.wyhash === 'string' ? txt.wyhash : null },
    hash: {
      content: requireString(hash, 'content'),
      name: requireString(hash, 'name'),
      seed: requireInteger(hash, 'seed'),
      normalize: typeof hash.normalize === 'string' ? hash.normalize : 'none',
    },
    updated: typeof document.updated === 'string' ? document.updated : '',
    writer: typeof document.writer === 'string' ? document.writer : '',
    created: typeof document.created === 'string' ? document.created : '',
    root: typeof document.root === 'string' ? document.root : '',
    extra,
  };
}

function requireObject(document, key) {
  const value = document[key];
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`files.json needs an object at '${key}'`);
  }
  return value;
}

function requireString(document, key) {
  const value = document[key];
  if (typeof value !== 'string') {
    throw new Error(`files.json needs a string at '${key}'`);
  }
  return value;
}

function requireInteger(document, key) {
  const value = document[key];
  if (typeof value !== 'number' || !Number.isInteger(value)) {
    throw new Error(`files.json needs an integer at '${key}'`);
  }
  return value;
}

/** The document as JSON, known keys first and the unknown ones preserved after them. */
export function configToJson(config) {
  const document = {
    format: config.format,
    version: config.version,
    entrySize: config.entrySize,
    order: config.order,
    generation: config.generation,
    count: config.count,
    meta: { bytes: config.meta.bytes },
    txt: { bytes: config.txt.bytes },
    hash: {
      content: config.hash.content,
      name: config.hash.name,
      seed: config.hash.seed,
      normalize: config.hash.normalize,
    },
    updated: config.updated,
    writer: config.writer,
    ...(config.created ? { created: config.created } : {}),
    ...(config.extra ?? {}),
  };
  return JSON.stringify(document);
}

/**
 * A document for a trio about to be written.
 *
 * There is no root argument: a trio contains no absolute path (FORMAT.md § 3.1), so where the tree was scanned is
 * not something a publish may record. The engine writes `root` as the root's `{ dev, ino }` identity, which is the
 * only root fact a trio carries.
 */
export function configForPublish({ count, metaBytes, txtBytes, generation, mode, writer, created, updated }) {
  return {
    format: FORMAT,
    version: VERSION,
    entrySize: ENTRY_SIZE,
    order: ORDER,
    generation,
    count,
    meta: { bytes: metaBytes },
    txt: { bytes: txtBytes },
    hash: { content: HASH_ALGO, name: HASH_ALGO, seed: HASH_SEED, normalize: mode },
    updated,
    writer,
    created,
    extra: {},
  };
}

/** The current instant in the shape § 7 asks for: RFC 3339 with milliseconds. */
export const now = () => new Date().toISOString();

/** The writer's hash mode, falling back to `none` for a value this version does not define. */
export const configHashMode = (config) => (HASH_MODES.includes(config.hash.normalize) ? config.hash.normalize : 'none');

// ------------------------------------------------------------------ validation (§ 8)

function ok(untrusted = []) {
  return { verdict: 'ok', firstBadEntry: -1, untrusted, detail: '', ok: true };
}

function failure(verdict, firstBadEntry, detail) {
  return { verdict, firstBadEntry, untrusted: [], detail, ok: false };
}

/** One line for a log or a terminal. */
export function describeValidation(validation) {
  if (validation.ok) {
    return validation.untrusted.length === 0
      ? 'ok'
      : `ok (${validation.untrusted.length} untrusted entry/entries: [${validation.untrusted.join(', ')}])`;
  }
  return `${validation.verdict}${validation.firstBadEntry >= 0 ? ` at entry ${validation.firstBadEntry}` : ''}`
    + (validation.detail ? `: ${validation.detail}` : '');
}

/**
 * Validates the two data files against the document, in § 8's order: the first failure wins, and every
 * implementation reports the same verdict for the same bytes.
 */
export function validate(meta, txt, config) {
  if (config.format !== FORMAT) {
    return failure('unsupported-format', -1, `the document's format is '${config.format}', not '${FORMAT}'`);
  }
  if (config.version !== VERSION) {
    return failure('unsupported-version', -1, `version ${config.version} is not implemented`);
  }
  if (config.entrySize !== ENTRY_SIZE) {
    return failure('unsupported-entry-size', -1, `entrySize ${config.entrySize} is not this version's ${ENTRY_SIZE}`);
  }
  if (config.hash.content !== HASH_ALGO || config.hash.name !== HASH_ALGO || config.hash.seed !== HASH_SEED) {
    return failure('unsupported-hash', -1,
      `the document's hash is ${config.hash.content}/${config.hash.name} with seed ${config.hash.seed}`);
  }

  const metaBytes = meta.length;
  if (metaBytes % ENTRY_SIZE !== 0) {
    return failure('meta-size-mismatch', -1,
      `files.meta is ${metaBytes} bytes, not a whole number of ${ENTRY_SIZE}-byte entries`);
  }
  if (metaBytes !== config.count * ENTRY_SIZE) {
    return failure('meta-size-mismatch', -1,
      `files.meta holds ${metaBytes / ENTRY_SIZE} entries but the document says ${config.count}`);
  }
  if (metaBytes !== config.meta.bytes) {
    return failure('meta-size-mismatch', -1,
      `files.meta is ${metaBytes} bytes but the document records ${config.meta.bytes}`);
  }
  // 6b: the size is not a claim about the bytes; this is. Before any entry check, or a corrupted meta would be
  // reported as the first thing *inside* it that looks wrong.
  if (typeof config.meta.wyhash === 'string' && hex64(wyhash64(meta)) !== config.meta.wyhash) {
    return failure('meta-hash-mismatch', -1,
      `wyhash(files.meta) is ${hex64(wyhash64(meta))}, meta.wyhash says ${config.meta.wyhash}`);
  }

  const txtBytes = txt.length;
  if (txtBytes !== config.txt.bytes) {
    return failure('txt-size-mismatch', -1,
      `files.txt is ${txtBytes} bytes but the document records ${config.txt.bytes}`);
  }
  if (config.count === 0) {
    if (txtBytes !== 0) {
      return failure('txt-size-mismatch', -1, `the document says there are no entries, but files.txt holds ${txtBytes} bytes`);
    }
  } else {
    if (txtBytes === 0 || txt[txtBytes - 1] !== LF) {
      return failure('txt-size-mismatch', -1, 'files.txt does not end with LF, so its last name is unterminated');
    }
    let lines = 0;
    for (const byte of txt) {
      if (byte === LF) {
        lines++;
      }
    }
    if (lines !== config.count) {
      return failure('txt-size-mismatch', -1, `files.txt holds ${lines} names but the document says ${config.count}`);
    }
    // 7b: the text file's own hash, before the names are read out of it.
    if (typeof config.txt.wyhash === 'string' && hex64(wyhash64(txt)) !== config.txt.wyhash) {
      return failure('txt-hash-mismatch', -1,
        `wyhash(files.txt) is ${hex64(wyhash64(txt))}, txt.wyhash says ${config.txt.wyhash}`);
    }
  }

  const entries = decodeEntries(meta);
  for (let index = 0; index < entries.length; index++) {
    const entry = entries[index];
    const offset = Number(entry.nameOffset);
    const length = entry.nameLength;
    if (length === 0) {
      return failure('entry-out-of-range', index, "the entry's nameLength is 0, which names nothing");
    }
    if (offset < 0 || offset >= txtBytes || offset + length >= txtBytes) {
      return failure('entry-out-of-range', index,
        `the entry's name slice (${offset} + ${length}) is not inside files.txt (${txtBytes} bytes)`);
    }
    if (txt[offset + length] !== LF) {
      return failure('entry-out-of-range', index, "the byte after the entry's name is not LF");
    }
    for (let i = 0; i < length; i++) {
      if (txt[offset + i] === LF) {
        return failure('entry-out-of-range', index, "the entry's name slice contains an LF");
      }
    }
    // § 6: exactly one kind bit, nothing undefined, and HASH_LF only where CONTENT_KNOWN says a hash was taken.
    // A reader that trusts an entry's kind must not be able to be told 'this is a file' and 'this is a directory'
    // at the same time, nor be handed a flag this version has never defined.
    const kindBits = entry.flags & 0x16; // REGULAR_FILE | IS_DIR | SYMLINK
    if ((entry.flags & ~0x1f) !== 0 || (kindBits !== 0x02 && kindBits !== 0x04 && kindBits !== 0x10)) {
      return failure('invalid-flags', index,
        `the entry's flags are 0x${(entry.flags >>> 0).toString(16)}: not exactly one of file/dir/symlink`);
    }
    if ((entry.flags & 0x01) === 0 && (entry.flags & 0x08) !== 0) {
      return failure('invalid-flags', index, 'HASH_LF is set without CONTENT_KNOWN');
    }
  }

  for (let index = 0; index < entries.length; index++) {
    const entry = entries[index];
    const name = txt.subarray(Number(entry.nameOffset), Number(entry.nameOffset) + entry.nameLength);
    // § 4: a directory's stored name ends with `/`; the hash is over the name without it, because a lookup is given
    // a path and the path of the folder has no slash. Both forms are accepted here, so a trio written before the
    // rule still validates.
    const hashed = name.length > 1 && name[name.length - 1] === 0x2f && (entry.flags & 0x04) !== 0 ? name.subarray(0, name.length - 1) : name;
    const actual = wyhash64(hashed);
    if (actual !== entry.nameHash) {
      return failure('name-hash-mismatch', index,
        `the name at the entry's offset hashes to ${hex64(actual)}, not ${hex64(entry.nameHash)}`);
    }
  }

  const untrusted = [];
  entries.forEach((entry, index) => {
    if (!trusted(entry)) {
      untrusted.push(index);
    }
  });
  return ok(untrusted);
}