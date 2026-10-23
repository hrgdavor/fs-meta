#!/usr/bin/env bun
// Generates `fsmeta-vectors.json` — the one vector set the Java and Bun implementations (and the Zig
// one, when it lands) all assert against.
//
//   bun fs-meta/conformance/gen-vectors.mjs
//
// WHY A GENERATOR, AND WHERE THE NUMBERS COME FROM. Two kinds of number live in that file, and neither
// may be derived from an implementation of the thing it is supposed to check:
//
//   * **wyhash64 values** — `js/wyhash64.mjs` asserts the seven library-produced golden vectors (the
//     same ones `ContentHashTest` pins its vendored copy to) *before* this generator emits anything, so
//     a hash that disagrees with `hr.hrg.wyhash:wyhash:1.0.0` cannot become part of the contract.
//     The binary-pattern cases (the `<= 16` short path, the 48-byte block loop, a multi-block tail) were
//     additionally cross-checked against `std.hash.Wyhash` as the Zig builtin implements it (0.17 when last regenerated), which reproduced
//     every library vector above — see `conformance/README.md`.
//   * **byte layout** — the `files.txt` and `files.meta` blobs are assembled here by hand, straight from
//     `FORMAT.md`'s field table, with no encoder shared with either implementation. An implementation
//     that agrees with these blobs agrees with the published spec, not with another implementation of
//     it — which is the difference between a conformance vector and a change detector.
//
// The invalid cases are complete blob pairs plus the sidekick document, each with the verdict a
// validator must reach, so the two implementations' *failure* behaviour is pinned as tightly as their
// success behaviour.

import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// The hash comes from the `wyhash` project, which owns it (its reference is the Zig builtin, and its own
// vectors are generated from it). The import resolves through the package link the root `package.json`
// declares, so this generator hashes with that project's code rather than with a copy of it (DEC-050).
// This generator only assembles the format's layout — and it refuses to emit anything until the shared
// implementation reproduces the library-produced golden vectors, so a broken hash cannot become part of this
// format's contract.
import { assertLibraryGoldenVectors, wyhash64Hex } from 'wyhash/js/wyhash64.mjs';
import { reportDuration, stopwatch } from '../../scripts/lib/timing.js';

const here = dirname(fileURLToPath(import.meta.url));
const elapsed = stopwatch();

const ENTRY_SIZE = 64;
const CONTENT_KNOWN = 0x0000_0001;
const REGULAR_FILE = 0x0000_0002;

const encoder = new TextEncoder();

const utf8 = (text) => encoder.encode(text);
const hash = (bytes) => wyhash64Hex(bytes);
const hashText = (text) => wyhash64Hex(utf8(text));
const hex = (bytes) => Buffer.from(bytes).toString('hex');

/** One `files.meta` entry's fields, in the order `FORMAT.md` publishes them. */
function entryBytes(entry) {
  const buffer = Buffer.alloc(ENTRY_SIZE);
  buffer.writeBigUInt64LE(BigInt(entry.mtime), 0);
  buffer.writeBigUInt64LE(BigInt(`0x${entry.nameHash}`), 8);
  buffer.writeBigUInt64LE(BigInt(`0x${entry.contentHash}`), 16);
  buffer.writeBigUInt64LE(BigInt(entry.size), 24);
  buffer.writeBigUInt64LE(BigInt(entry.nameOffset), 32);
  buffer.writeUInt32LE(entry.nameLength, 40);
  buffer.writeUInt32LE(entry.flags, 44);
  buffer.writeBigUInt64LE(0n, 48);
  buffer.writeBigUInt64LE(0n, 56);
  return buffer;
}

const metaBytes = (entries, truncateTo) => {
  const all = Buffer.concat(entries.map(entryBytes));
  return truncateTo === undefined ? all : all.subarray(0, truncateTo);
};

/** The names in order, each followed by LF — including the last, unless the case tests a torn write. */
const txtBytes = (names, trailingLf = true) => utf8(names.map((name, i) => {
  const last = i === names.length - 1;
  return (last && !trailingLf) ? name : `${name}\n`;
}).join(''));

const sidekick = ({ format = 'fs-meta', version = 1, entrySize = ENTRY_SIZE, count, meta, txt }) => ({
  format,
  version,
  entrySize,
  order: 'utf8-bytes',
  generation: 1,
  count,
  meta: { bytes: meta },
  txt: { bytes: txt },
  hash: { content: 'wyhash64', name: 'wyhash64', seed: 0, normalize: 'none' },
  updated: '2026-10-16T11:33:30.123Z',
  writer: 'fs-meta-conformance/1',
});

// ------------------------------------------------------------------ the fixture every case mutates

const NAME_0 = 'a.txt';
const NAME_1 = 'src/b.java';
const CONTENT_0 = 'hello\n';
const CONTENT_1 = 'class B {}\n';

const TXT = txtBytes([NAME_0, NAME_1]);
const NAME_1_OFFSET = NAME_0.length + 1;

const BASE = [
  {
    mtime: 1_700_000_000_123,
    nameHash: hashText(NAME_0),
    contentHash: hashText(CONTENT_0),
    size: utf8(CONTENT_0).length,
    nameOffset: 0,
    nameLength: NAME_0.length,
    flags: CONTENT_KNOWN | REGULAR_FILE,
  },
  {
    mtime: 1_700_000_001_456,
    nameHash: hashText(NAME_1),
    contentHash: hashText(CONTENT_1),
    size: utf8(CONTENT_1).length,
    nameOffset: NAME_1_OFFSET,
    nameLength: NAME_1.length,
    flags: CONTENT_KNOWN | REGULAR_FILE,
  },
];

const META = metaBytes(BASE);
const GOOD_JSON = sidekick({ count: 2, meta: META.length, txt: TXT.length });

const clone = (entries) => entries.map((entry) => ({ ...entry }));

/** A case: the pair, the sidekick document, the verdict, and any entry a reader must not trust. */
function testCase(label, verdict, { txt = TXT, meta = META, json = GOOD_JSON, untrusted = [] } = {}) {
  return { label, verdict, untrusted, txtHex: hex(txt), metaHex: hex(meta), json };
}

const CASES = [];

// ---- the valid pair, which is also the byte-exactness pin ----------------------
CASES.push(testCase('valid', 'ok'));

// ---- the version gate, which wins over every other fault ----------------------
CASES.push(testCase('unsupported-format', 'unsupported-format',
  { json: sidekick({ format: 'fs-meta-other', count: 2, meta: META.length, txt: TXT.length }) }));
CASES.push(testCase('unsupported-version', 'unsupported-version',
  { json: sidekick({ version: 2, count: 2, meta: META.length, txt: TXT.length }) }));
CASES.push(testCase('unsupported-entry-size', 'unsupported-entry-size',
  { json: sidekick({ entrySize: 32, count: 2, meta: META.length, txt: TXT.length }) }));
CASES.push(testCase('unsupported-format-beats-meta-size', 'unsupported-format',
  {
    meta: metaBytes(BASE, 127),
    json: sidekick({ format: 'fs-meta-other', count: 2, meta: META.length, txt: TXT.length }),
  }));

// ---- the pair no longer agrees with itself or with the document ---------------
CASES.push(testCase('meta-not-a-multiple-of-64', 'meta-size-mismatch',
  { meta: metaBytes(BASE, 127), json: sidekick({ count: 2, meta: 127, txt: TXT.length }) }));
CASES.push(testCase('json-count-mismatch', 'meta-size-mismatch',
  { json: sidekick({ count: 3, meta: META.length, txt: TXT.length }) }));
CASES.push(testCase('json-meta-bytes-mismatch', 'meta-size-mismatch',
  { json: sidekick({ count: 2, meta: META.length + 1, txt: TXT.length }) }));
CASES.push(testCase('json-txt-bytes-mismatch', 'txt-size-mismatch',
  { json: sidekick({ count: 2, meta: META.length, txt: TXT.length + 1 }) }));

const TXT_NO_TRAILING_LF = txtBytes([NAME_0, NAME_1], false);
CASES.push(testCase('txt-without-trailing-lf', 'txt-size-mismatch',
  { txt: TXT_NO_TRAILING_LF, json: sidekick({ count: 2, meta: META.length, txt: TXT_NO_TRAILING_LF.length }) }));

// ---- per-entry faults, in the order a validator must report them --------------
const outOfRange = clone(BASE);
outOfRange[1].nameOffset = 4096;
const OUT_OF_RANGE_META = metaBytes(outOfRange);
CASES.push(testCase('name-offset-out-of-range', 'entry-out-of-range',
  { meta: OUT_OF_RANGE_META, json: sidekick({ count: 2, meta: OUT_OF_RANGE_META.length, txt: TXT.length }) }));

const badHash = clone(BASE);
badHash[0].nameHash = (BigInt(`0x${badHash[0].nameHash}`) ^ 1n).toString(16).padStart(16, '0');
const BAD_HASH_META = metaBytes(badHash);
CASES.push(testCase('name-hash-mismatch', 'name-hash-mismatch',
  { meta: BAD_HASH_META, json: sidekick({ count: 2, meta: BAD_HASH_META.length, txt: TXT.length }) }));

const bothWrong = clone(BASE);
bothWrong[1].nameOffset = 4096;
bothWrong[1].nameHash = (BigInt(`0x${bothWrong[1].nameHash}`) ^ 1n).toString(16).padStart(16, '0');
const BOTH_WRONG_META = metaBytes(bothWrong);
CASES.push(testCase('range-beats-name-hash', 'entry-out-of-range',
  { meta: BOTH_WRONG_META, json: sidekick({ count: 2, meta: BOTH_WRONG_META.length, txt: TXT.length }) }));

// ---- flags: one unknown bit makes an entry untrusted, and that is not a failure of the pair -----
const reservedBit = clone(BASE);
reservedBit[1].flags |= 0x10;
const RESERVED_BIT_META = metaBytes(reservedBit);
CASES.push(testCase('reserved-flag-bit', 'ok',
  { meta: RESERVED_BIT_META, json: sidekick({ count: 2, meta: RESERVED_BIT_META.length, txt: TXT.length }), untrusted: [1] }));

// A listing-only entry: the file is known to exist, no fingerprint was taken. Legal, and it carries no
// hash to trust — the reader must read the file itself.
const listingOnly = clone(BASE);
listingOnly[1] = {
  mtime: 0,
  nameHash: hashText(NAME_1),
  contentHash: '0000000000000000',
  size: 0,
  nameOffset: NAME_1_OFFSET,
  nameLength: NAME_1.length,
  flags: REGULAR_FILE,
};
const LISTING_ONLY_META = metaBytes(listingOnly);
CASES.push(testCase('listing-only-entry', 'ok',
  { meta: LISTING_ONLY_META, json: sidekick({ count: 2, meta: LISTING_ONLY_META.length, txt: TXT.length }) }));

// ------------------------------------------------------------------ the repair case

const REPAIR_NAME_0 = 'b.txt';
const REPAIR_NAME_1 = 'a.txt';
const REPAIR_TXT = txtBytes([REPAIR_NAME_0, REPAIR_NAME_1]);
const REPAIR_BASE = [
  {
    mtime: 1_700_000_000_123,
    nameHash: hashText(REPAIR_NAME_1),
    contentHash: hashText('a\n'),
    size: 2,
    nameOffset: 0, // the entry for `a.txt`, pointing at the line that holds `b.txt`
    nameLength: REPAIR_NAME_0.length,
    flags: CONTENT_KNOWN | REGULAR_FILE,
  },
  {
    mtime: 1_700_000_001_456,
    nameHash: hashText(REPAIR_NAME_0),
    contentHash: hashText('b\n'),
    size: 2,
    nameOffset: REPAIR_NAME_0.length + 1,
    nameLength: REPAIR_NAME_1.length,
    flags: CONTENT_KNOWN | REGULAR_FILE,
  },
];
const REPAIR_META = metaBytes(REPAIR_BASE);

// ------------------------------------------------------------------ the document

assertLibraryGoldenVectors();

const TEXT_HASH_CASES = [
  ['empty', ''],
  ['one-byte', 'x'],
  ['a', 'a'],
  ['lf (12 bytes)', 'line1\nline2\n'],
  ['crlf (14 bytes, raw)', 'line1\r\nline2\r\n'],
  ['utf8 (7 bytes)', 'héllo\n'],
  ['exactly 16 bytes', '0123456789abcdef'],
  ['17 bytes', '0123456789abcdefg'],
  ['exactly 48 bytes', '0123456789abcdef0123456789abcdef0123456789abcdef'],
  ['49 bytes', '0123456789abcdef0123456789abcdef0123456789abcdef0'],
  ['name a.txt', 'a.txt'],
  ['name src/b.java', 'src/b.java'],
  ['name README.md', 'README.md'],
  ['name z/y/z.txt', 'z/y/z.txt'],
];

// Binary patterns: the byte at index i is (i * 7 + 3) & 0xFF, at the lengths that walk the algorithm's
// branches — the <= 16 short path, the 48-byte block loop, and multi-block tails.
const PATTERN_LENGTHS = [4, 7, 8, 15, 31, 32, 47, 64, 100, 255];
const patternOf = (length) => Uint8Array.from({ length }, (_, i) => (i * 7 + 3) & 0xff);

// ------------------------------------------------------------------ what a walk lists

/** The format's name order (§ 3): unsigned byte comparison of the UTF-8 encoding. */
const formatOrder = (left, right) => Buffer.compare(Buffer.from(left, 'utf8'), Buffer.from(right, 'utf8'));

/**
 * One ignore case: a tree to materialise, the expected walk result, and — where it is worth pinning — the
 * result when `.gitignore` reading is switched off. Both lists are emitted in format order.
 */
const gitignoreCase = (label, explain, { files, gitignores = {}, included, includedWithoutGitignore }) => ({
  label,
  explain,
  files: [...files].sort(formatOrder),
  gitignores,
  included: [...included].sort(formatOrder),
  ...(includedWithoutGitignore ? { includedWithoutGitignore: [...includedWithoutGitignore].sort(formatOrder) } : {}),
});

const GITIGNORE_CASES = [
  gitignoreCase('basic-glob', 'a basename pattern excludes at any depth', {
    gitignores: { '.gitignore': '*.log\n' },
    files: ['a.txt', 'debug.log'],
    included: ['.gitignore', 'a.txt'],
    includedWithoutGitignore: ['.gitignore', 'a.txt', 'debug.log'],
  }),
  gitignoreCase('negation-reincludes', 'the last matching pattern wins', {
    gitignores: { '.gitignore': '*.log\n!keep.log\n' },
    files: ['a.txt', 'debug.log', 'keep.log'],
    included: ['.gitignore', 'a.txt', 'keep.log'],
  }),
  gitignoreCase('anchored-pattern', 'a leading slash anchors to the ignore file\'s directory', {
    gitignores: { '.gitignore': '/root-only.txt\n' },
    files: ['root-only.txt', 'sub/root-only.txt'],
    included: ['.gitignore', 'sub/root-only.txt'],
  }),
  gitignoreCase('unanchored-matches-any-depth', 'a name-only pattern excludes directories too', {
    gitignores: { '.gitignore': 'build\n' },
    files: ['build/x.txt', 'keep.txt', 'sub/build/y.txt'],
    included: ['.gitignore', 'keep.txt'],
  }),
  gitignoreCase('directory-only-pattern', 'a trailing slash means directories only', {
    gitignores: { '.gitignore': 'out/\n' },
    files: ['keep.txt', 'out.txt', 'out/x.txt'],
    included: ['.gitignore', 'keep.txt', 'out.txt'],
  }),
  gitignoreCase('nested-gitignore-overrides-outer', 'a deeper file beats a shallower one', {
    gitignores: { '.gitignore': '*.tmp\n', 'src/.gitignore': '!keep.tmp\n' },
    files: ['root.tmp', 'src/a.tmp', 'src/b.txt', 'src/keep.tmp'],
    included: ['.gitignore', 'src/.gitignore', 'src/b.txt', 'src/keep.tmp'],
  }),
  gitignoreCase('excluded-directory-cannot-be-reincluded', 'a negation cannot resurrect a file in a pruned directory', {
    gitignores: { '.gitignore': 'node_modules/\n!node_modules/keep.txt\n' },
    files: ['a.js', 'node_modules/keep.txt', 'node_modules/x.js'],
    included: ['.gitignore', 'a.js'],
  }),
  gitignoreCase('double-star-in-the-middle', '**/ between two segments covers zero or more directories', {
    gitignores: { '.gitignore': 'docs/**/*.md\n' },
    files: ['docs/a.md', 'docs/x/b.md', 'docs/x/d.txt', 'docs/x/y/c.md'],
    included: ['.gitignore', 'docs/x/d.txt'],
  }),
  gitignoreCase('double-star-trailing', 'a trailing /** matches everything inside, not the directory itself', {
    gitignores: { '.gitignore': 'logs/**\n' },
    files: ['logs.txt', 'logs/a.txt', 'logs/x/b.txt'],
    included: ['.gitignore', 'logs.txt'],
  }),
  gitignoreCase('double-star-leading', 'a leading **/ matches at any depth', {
    gitignores: { '.gitignore': '**/generated\n' },
    files: ['generated/a.txt', 'src/generated/b.txt', 'src/keep.txt'],
    included: ['.gitignore', 'src/keep.txt'],
  }),
  gitignoreCase('question-and-character-class', '? is one character and [...] is a class', {
    gitignores: { '.gitignore': 'file?.txt\n[abc].dat\n' },
    files: ['a.dat', 'd.dat', 'file1.txt', 'file12.txt'],
    included: ['.gitignore', 'd.dat', 'file12.txt'],
  }),
  gitignoreCase('comment-blank-line-and-trailing-space', 'comments and blank lines are skipped, and a trailing space is not part of the pattern', {
    gitignores: { '.gitignore': '# a comment\n\nkeep-me \n' },
    files: ['keep-me', 'other'],
    included: ['.gitignore', 'other'],
  }),
  gitignoreCase('escaped-hash-and-bang', 'a backslash makes a leading # or ! literal', {
    gitignores: { '.gitignore': '\\#literal\n\\!literal\n' },
    files: ['#literal', '!literal', 'other'],
    included: ['.gitignore', 'other'],
  }),
  gitignoreCase('always-skipped-directories', '.git and .fs-meta are skipped whatever the ignore files say', {
    files: ['.fs-meta/files.txt', '.git/config', 'a.txt'],
    included: ['a.txt'],
  }),
  gitignoreCase('nested-gitignore-scopes-to-its-directory', 'a subdirectory\'s file governs only that subdirectory', {
    gitignores: { 'sub/.gitignore': '*.log\n' },
    files: ['sub/keep.txt', 'sub/x.log', 'y.log'],
    included: ['sub/.gitignore', 'sub/keep.txt', 'y.log'],
  }),
  gitignoreCase('star-does-not-cross-a-separator', 'a bare * stays inside one path segment', {
    gitignores: { '.gitignore': '*.tmp\n' },
    files: ['a.tmp', 'sub/b.tmp', 'sub/deep/a.tmp'],
    included: ['.gitignore'],
  }),
];

const document = {
  format: 'fs-meta-vectors',
  version: 1,
  entrySize: ENTRY_SIZE,
  note: 'Generated by conformance/gen-vectors.mjs — see that file for how the numbers are derived. Do not hand-edit.',
  hash: { algo: 'wyhash64', seed: 0 },
  hashCases: [
    ...TEXT_HASH_CASES.map(([label, text]) => ({ label, text, wyhash64: hashText(text) })),
    ...PATTERN_LENGTHS.map((length) => {
      const bytes = patternOf(length);
      return { label: `pattern-${length}`, hex: hex(bytes), wyhash64: hash(bytes) };
    }),
  ],
  cases: CASES,
  gitignoreCases: GITIGNORE_CASES,
  repairCase: {
    label: 'entries-paired-by-name-hash',
    verdict: 'name-hash-mismatch',
    txtHex: hex(REPAIR_TXT),
    metaHex: hex(REPAIR_META),
    json: sidekick({ count: 2, meta: REPAIR_META.length, txt: REPAIR_TXT.length }),
    recovered: [
      { entry: 0, name: 'a.txt' },
      { entry: 1, name: 'b.txt' },
    ],
    sortedNames: ['a.txt', 'b.txt'],
  },
};

const target = join(here, 'fsmeta-vectors.json');
writeFileSync(target, `${JSON.stringify(document, null, 2)}\n`, 'utf8');

console.log(`${document.hashCases.length} hash case(s), ${document.cases.length} pair case(s), `
  + `${document.gitignoreCases.length} ignore case(s), 1 repair case -> ${target}`);
reportDuration(elapsed(), { what: 'fs-meta vectors generated', files: 1 });
