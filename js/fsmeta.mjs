// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//
// The Bun port of fs-meta: the file-system half that `layout.mjs` does not hold — reading a trio, scanning a
// tree with `.gitignore` honoured, publishing a generation, diffing two of them and repairing a broken
// pairing. It is the counterpart of the Java port's FsMetaPair / FsMetaScanner / FsMetaWriter / FsMetaDiff /
// FsMetaRepair, and both ports assert the same conformance vectors in
// `conformance/fsmeta-vectors.json`.
//
// The publishing rules are FORMAT.md § 9: files.txt, then files.meta, then files.json LAST, each through a
// temporary file in the same directory, fsynced and renamed — because the sidekick is the commit record, and
// a reader that finds it older than the data files sees sizes that disagree and rescans instead of trusting
// a half-published generation.

import {
  closeSync, existsSync, fsyncSync, mkdirSync, openSync, readFileSync, readdirSync, renameSync, statSync, writeSync,
} from 'node:fs';
import { join, relative, sep } from 'node:path';

import {
  DIRECTORY_NAME, FORMAT, JSON_FILE, META_FILE, TXT_FILE, VERSION, compareNames, configForPublish, configHashMode,
  configToJson, contentKnown, decodeEntries, describeValidation, encodeEntries, encodeNames, entryCount, entryForFile,
  hashBytes, hashLf, hex64, listingOnlyEntry, nameHashOf, now, parseConfig, trusted, utf8Length, validate,
} from './layout.mjs';
import { GitIgnoreRules, readGitignore } from './gitignore.mjs';

/** The `writer` field this port writes. */
export const WRITER = 'fsmeta-js/1';

/**
 * One entry as the `query` and `dump` commands print it: name, mtime, size, content hash, name hash, flags —
 * the same fields, in the same order, as the Java port's `FsMetaEntry.format(name)`.
 */
export function formatEntry(name, entry) {
  return `${name}\t${entry.mtimeMillis}\t${entry.sizeBytes}\t${hex64(entry.contentHash)}\t${hex64(entry.nameHash)}\t${entry.flags}`;
}

/** The names every scan skips: `.git` is git's own, and `.fs-meta` is the trio itself. */
export const DEFAULT_IGNORED = ['.git', DIRECTORY_NAME];

/**
 * The scan options, with the same defaults as the Java port: text-aware hashing, `.gitignore` honoured, and
 * only `.git` / `.fs-meta` skipped by name.
 */
export function scanOptions({ hashMode = 'text', ignored = DEFAULT_IGNORED, respectGitignore = true } = {}) {
  return { hashMode, ignored: [...ignored], respectGitignore };
}

// ------------------------------------------------------------------ reading a trio

/**
 * A validated pair, in memory: the entries, their names and the lookups a consumer asks of them.
 *
 * Throws when the verdict is not `ok` — a caller holding a failure has nothing to read a field from.
 */
export function openPair(meta, txt, config) {
  const validation = validate(meta, txt, config);
  if (!validation.ok) {
    throw new Error(`the trio is not usable: ${validation.verdict}${validation.detail ? `: ${validation.detail}` : ''}`);
  }
  const entries = decodeEntries(meta);
  const names = entries.map((entry) => txt.subarray(Number(entry.nameOffset), Number(entry.nameOffset) + entry.nameLength).toString('utf8'));

  // Lookup by hash, then verified against the stored name: a 64-bit collision costs a comparison rather
  // than a wrong answer. The order of `files.txt` is deliberately not relied on (§ 8 does not validate it).
  const byHash = new Map();
  entries.forEach((entry, index) => {
    const key = hex64(entry.nameHash);
    if (!byHash.has(key)) {
      byHash.set(key, []);
    }
    byHash.get(key).push(index);
  });

  return {
    config,
    validation,
    entries,
    names,
    size: entries.length,
    entry: (index) => entries[index],
    name: (index) => names[index],
    untrusted: (index) => !trusted(entries[index]),
    find(name) {
      const candidates = byHash.get(hex64(nameHashOf(name))) ?? [];
      for (const index of candidates) {
        if (names[index] === name) {
          return index;
        }
      }
      return -1;
    },
    contains(name) {
      return this.find(name) >= 0;
    },
    entryOrNull(name) {
      const index = this.find(name);
      return index < 0 ? null : entries[index];
    },
    describe() {
      return `fs-meta generation ${config.generation}, ${entries.length} entries, `
        + (validation.untrusted.length === 0 ? 'ok' : `ok (${validation.untrusted.length} untrusted)`);
    },
  };
}

function loadFailure(directory, verdict, detail, config = null) {
  return {
    directory,
    verdict,
    config,
    pair: null,
    detail,
    ok: false,
    describe: () => `${directory}: ${verdict}${detail ? ` — ${detail}` : ''}`,
  };
}

function loadOk(directory, config, pair) {
  return {
    directory,
    verdict: 'ok',
    config,
    pair,
    detail: '',
    ok: true,
    describe: () => `${directory}: ${pair.describe()}`,
  };
}

/** Reads and validates the three files. Throws when one of them is missing. */
export function loadTrio(directory) {
  const meta = readFileSync(join(directory, META_FILE));
  const txt = readFileSync(join(directory, TXT_FILE));
  let config;
  try {
    config = parseConfig(readFileSync(join(directory, JSON_FILE), 'utf8'));
  } catch (malformed) {
    // § 8 check 1: a document that cannot be read is the same verdict as one that is not ours.
    return loadFailure(directory, 'unsupported-format', malformed.message);
  }
  const validation = validate(meta, txt, config);
  if (!validation.ok) {
    return loadFailure(directory, validation.verdict, validation.detail, config);
  }
  return loadOk(directory, config, openPair(meta, txt, config));
}

/** Reads the trio when all three files exist; `null` when one does not — a checkout never scanned. */
export function loadTrioIfPresent(directory) {
  for (const file of [META_FILE, TXT_FILE, JSON_FILE]) {
    if (!existsSync(join(directory, file))) {
      return null;
    }
  }
  return loadTrio(directory);
}

// ------------------------------------------------------------------ scanning (§ 3, § 6, § 12)

/** A file as a scan found it: the name plus the fingerprint fields an entry is built from. */
export const fileFor = (name, mtimeMillis, sizeBytes, contentHash, lfNormalised) => ({
  name, mtimeMillis, sizeBytes, contentHash, lfNormalised,
});

/** A file the writer listed without reading — no fingerprint, and the fields are ignored (§ 6). */
export const listingOnlyFile = (name) => ({
  name, mtimeMillis: 0n, sizeBytes: 0n, contentHash: 0n, lfNormalised: false, listingOnly: true,
});

/** The entry a scanned file becomes once its name's place in `files.txt` is known. */
function fileToEntry(file, nameOffset) {
  return file.listingOnly
    ? listingOnlyEntry(file.name, nameOffset)
    : entryForFile(file.name, file.mtimeMillis, file.sizeBytes, file.contentHash, nameOffset, file.lfNormalised);
}

const relativeName = (base, path) => (path === base ? '' : relative(base, path).split(sep).join('/'));

/**
 * Every regular file under `root` that the options do not ignore, in the format's name order.
 *
 * Regular files only: a symbolic link is skipped rather than followed or recorded, because a link's identity
 * is both the link and its target and a v1 entry has no field for the link (§ 15).
 */
export function scanTree(root, options = scanOptions()) {
  const base = root;
  const files = [];
  const rules = new GitIgnoreRules();
  if (options.respectGitignore) {
    rules.push(readGitignore(base, ''));
  }
  walk(base, '', rules, options, files);
  if (options.respectGitignore) {
    rules.pop();
  }
  files.sort((left, right) => compareNames(left.name, right.name));
  return files;
}

function walk(directory, relativeDirectory, rules, options, files) {
  for (const dirent of readdirSync(directory, { withFileTypes: true })) {
    const name = relativeDirectory === '' ? dirent.name : `${relativeDirectory}/${dirent.name}`;
    const path = join(directory, dirent.name);
    if (dirent.isDirectory()) {
      if (options.ignored.includes(dirent.name)) {
        continue;
      }
      if (options.respectGitignore && rules.isIgnored(name, true)) {
        continue;                                   // an excluded directory is not entered
      }
      const file = options.respectGitignore ? readGitignore(path, name) : null;
      if (file) {
        rules.push(file);
      }
      walk(path, name, rules, options, files);
      if (file) {
        rules.pop();
      }
      continue;
    }
    if (!dirent.isFile()) {
      continue;                                     // a symlink, a socket, a device: not listed
    }
    if (options.respectGitignore && rules.isIgnored(name, false)) {
      continue;
    }
    files.push(record(path, name, options));
  }
}

/** One file's fingerprint, as an incremental update needs for a path a watcher reported as changed. */
function record(path, name, options) {
  const stat = statSync(path);
  const bytes = readFileSync(path);
  const hashed = hashBytes(bytes, options.hashMode);
  return fileFor(name, BigInt(Math.floor(stat.mtimeMs)), BigInt(stat.size), hashed.hash, hashed.lfNormalised);
}

/**
 * One file, as {@link scanTree} would record it — `null` when the scan would not list it: not a regular
 * file, inside a `.git`/`.fs-meta` directory, or excluded by a `.gitignore` on the way to it.
 */
export function scanOne(root, file, options = scanOptions()) {
  const base = root;
  const target = file;
  const name = relativeName(base, target);
  if (name === '' || name.startsWith('..')) {
    throw new Error(`${target} is not inside the scan root ${base}`);
  }
  let stat;
  try {
    stat = statSync(target);
  } catch {
    return null;
  }
  if (!stat.isFile()) {
    return null;
  }

  const rules = new GitIgnoreRules();
  if (options.respectGitignore) {
    rules.push(readGitignore(base, ''));            // the root's own .gitignore governs the root's files
  }
  const segments = name.split('/');
  let directory = base;
  for (let index = 0; index < segments.length - 1; index++) {
    const segment = segments[index];
    if (options.ignored.includes(segment)) {
      return null;
    }
    const relativeDirectory = segments.slice(0, index + 1).join('/');
    if (options.respectGitignore) {
      if (rules.isIgnored(relativeDirectory, true)) {
        return null;
      }
      rules.push(readGitignore(join(directory, segment), relativeDirectory));
      directory = join(directory, segment);
    }
  }
  if (options.respectGitignore && rules.isIgnored(name, false)) {
    return null;
  }
  return record(target, name, options);
}

// ------------------------------------------------------------------ publishing (§ 9)

/** What a previous generation contributes to the next one: its counter and its creation instant. */
function previousGeneration(directory) {
  const document = join(directory, JSON_FILE);
  if (!existsSync(document)) {
    return { generation: 0, created: '' };
  }
  try {
    const config = parseConfig(readFileSync(document, 'utf8'));
    return { generation: config.generation, created: config.created };
  } catch {
    return { generation: 0, created: '' };
  }
}

/**
 * Writes the trio for `files` into `directory`, in § 9's order, and reads it back.
 *
 * @returns the trio as it now reads, validated — a publish that cannot be read back is a writer bug, and
 *   checking it here is cheaper than a consumer discovering it later
 */
export function publish(directory, files, { mode = 'text', writer = WRITER, root = '' } = {}) {
  const ordered = [...files].sort((left, right) => compareNames(left.name, right.name));
  const txt = encodeNames(ordered.map((file) => file.name));
  const entries = [];
  let offset = 0;
  for (const file of ordered) {
    entries.push(fileToEntry(file, offset));
    offset += utf8Length(file.name) + 1;
  }
  const meta = encodeEntries(entries);

  const previous = previousGeneration(directory);
  const config = configForPublish({
    count: entries.length,
    metaBytes: meta.length,
    txtBytes: txt.length,
    generation: previous.generation + 1,
    mode,
    writer,
    root,
    created: previous.created === '' ? now() : previous.created,
    updated: now(),
  });

  mkdirSync(directory, { recursive: true });
  writeAtomically(join(directory, TXT_FILE), txt);
  writeAtomically(join(directory, META_FILE), meta);
  writeAtomically(join(directory, JSON_FILE), Buffer.from(configToJson(config), 'utf8'));
  return loadTrio(directory);
}

/**
 * One file through a temporary name in the same directory, fsynced and renamed: the rename is the commit,
 * and the fsync is what makes the claim survive a crash.
 */
function writeAtomically(target, buffer) {
  const temporary = `${target}.tmp`;
  const descriptor = openSync(temporary, 'w');
  try {
    writeSync(descriptor, buffer);
    fsyncSync(descriptor);
  } finally {
    closeSync(descriptor);
  }
  renameSync(temporary, target);
}

// ------------------------------------------------------------------ diffing two generations (§ 11)

const KINDS = {
  added: '+',
  removed: '-',
  modified: 'M',
  touched: 'T',
  unknown: '?',
};

/** The one-character marker a diff line starts with. */
export const kindMarker = (kind) => KINDS[kind];

/** The line `fsmeta diff` prints for a change. */
export const changeLine = (change) => `${KINDS[change.kind]} ${change.name}`;

/** Every name that was added, removed or changed between two pairs, sorted into the format's order. */
export function diffPairs(before, after) {
  const older = new Map(before.names.map((name, index) => [name, before.entry(index)]));
  const newer = new Map(after.names.map((name, index) => [name, after.entry(index)]));
  const changes = [];
  for (const [name, entry] of newer) {
    const previous = older.get(name);
    if (previous === undefined) {
      changes.push({ kind: 'added', name, before: null, after: entry });
      continue;
    }
    const kind = classify(previous, entry);
    if (kind !== null) {
      changes.push({ kind, name, before: previous, after: entry });
    }
  }
  for (const [name, entry] of older) {
    if (!newer.has(name)) {
      changes.push({ kind: 'removed', name, before: entry, after: null });
    }
  }
  changes.sort((left, right) => compareNames(left.name, right.name));
  return changes;
}

function classify(before, after) {
  const trustworthy = (entry) => trusted(entry) && contentKnown(entry);
  if (!trustworthy(before) || !trustworthy(after)) {
    return 'unknown';
  }
  if (before.contentHash !== after.contentHash || before.sizeBytes !== after.sizeBytes) {
    return 'modified';
  }
  return before.mtimeMillis !== after.mtimeMillis ? 'touched' : null;
}

// ------------------------------------------------------------------ repairing a broken pairing (§ 10)

/**
 * Rebuilds the entry-to-name pairing from the hashes — `nameHash`'s reason for existing.
 *
 * @returns an array of `{ entry, name }` in entry order, or `null` when it cannot be recovered (an entry
 *   with no distinct matching line, or two lines a single entry could claim)
 */
export function repairPairing(meta, txt) {
  if (meta.length % 64 !== 0) {
    return null;
  }
  const entries = decodeEntries(meta);
  const names = lines(txt);
  if (names.length !== entries.length) {
    return null;
  }
  const nameHashes = names.map((name) => nameHashOf(name));
  const lineUsed = names.map(() => false);
  const pairing = [];

  for (let entryIndex = 0; entryIndex < entries.length; entryIndex++) {
    const entry = entries[entryIndex];
    let found = -1;
    for (let line = 0; line < names.length; line++) {
      if (lineUsed[line] || nameHashes[line] !== entry.nameHash) {
        continue;
      }
      if (found >= 0) {
        // Two lines hash alike: the entry also recorded how many bytes its name is, which separates them —
        // and if it does not, the pairing would be a guess, so it is refused.
        const firstFits = utf8Length(names[found]) === entry.nameLength;
        const thisFits = utf8Length(names[line]) === entry.nameLength;
        if (firstFits === thisFits) {
          return null;
        }
        if (thisFits) {
          found = line;
        }
        continue;
      }
      found = line;
    }
    if (found < 0) {
      return null;
    }
    lineUsed[found] = true;
    pairing.push({ entry: entryIndex, name: names[found] });
  }
  return pairing;
}

/** The names in `files.txt`, in file order; a final unterminated line is accepted so a torn write is readable. */
export function lines(txt) {
  const names = [];
  let start = 0;
  for (let index = 0; index < txt.length; index++) {
    if (txt[index] === 0x0a) {
      names.push(txt.subarray(start, index).toString('utf8'));
      start = index + 1;
    }
  }
  if (start < txt.length) {
    names.push(txt.subarray(start).toString('utf8'));
  }
  return names;
}

/** The file objects a repair republishes, in the recovered pairing. */
export function repairedFiles(entries, pairing) {
  return pairing.map((one) => {
    const entry = entries[one.entry];
    return contentKnown(entry)
      ? fileFor(one.name, entry.mtimeMillis, entry.sizeBytes, entry.contentHash, hashLf(entry))
      : listingOnlyFile(one.name);
  });
}

// The layout half is re-exported whole: a consumer of this port should not have to know that the format's
// constants and codec live in a second module, and it keeps the CLI's imports in one place.
export * from './layout.mjs';