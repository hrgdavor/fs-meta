#!/usr/bin/env bun
// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//
// Integration tests for `fsmeta match` and `fsmeta changed` — the query commands over a published trio.
//
//   bun test test/query-cli.test.mjs
//
// `query.zig`'s unit tests exercise `Glob` and `Query.run` over a hand-built `Cache`; they cannot see the path the
// CLI takes: which trio it loads, what the four printed fields are, the `glob` alias, `--json`, `--since` and the
// exit codes. That path is what this file pins, against a tree whose shape makes the trio and the disk disagree —
// a `.gitignore` keeps a file and a whole directory on disk but out of the trio — because "the query answers from
// the trio" is a property only an integration test can see.
import { afterAll, describe, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { binary } from './binary.mjs';

const here = dirname(fileURLToPath(import.meta.url));
if (!existsSync(binary)) {
  throw new Error(`build the engine first and point FSMETA_BIN at it (expected ${binary})`);
}

// ──────────────────────────────────────────────
// Harness
// ──────────────────────────────────────────────

const roots = [];
afterAll(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true });
});

/** Scratch under the project's `.tmp/`, never the system temp directory; removed in `afterAll`. */
function scratch() {
  const base = join(here, '..', '.tmp');
  mkdirSync(base, { recursive: true });
  const dir = mkdtempSync(join(base, 'query-cli-'));
  roots.push(dir);
  return dir;
}

/**
 * Run the binary and keep the exit code as data: these commands use 0 (answered), 1 (the subject failed) and 2
 * (usage), and a test that only catches exceptions cannot tell them apart.
 */
function run(...args) {
  const result = spawnSync(binary, args, { encoding: 'utf8', cwd: here });
  if (result.error) throw new Error(`cannot run ${binary}: ${result.error.message}`);
  return { code: result.status, stdout: result.stdout, stderr: result.stderr };
}

/** Run a command that must succeed, returning its stdout. */
function runOk(...args) {
  const result = run(...args);
  if (result.code !== 0) {
    throw new Error(
      `fsmeta ${args.join(' ')} exited ${result.code}, expected 0\n` +
        `  stdout:\n${indent(result.stdout)}  stderr:\n${indent(result.stderr)}`,
    );
  }
  return result.stdout;
}

function indent(text) {
  const value = String(text ?? '');
  if (value.length === 0) return '    (empty)\n';
  return `${value.split('\n').map((line) => `    ${line}`).join('\n')}\n`;
}

function render(value) {
  if (typeof value === 'string') return JSON.stringify(value);
  return JSON.stringify(value) ?? String(value);
}

/** An assertion whose failure says what was expected and what the command printed. */
function check(actual, expected, what, output) {
  const same =
    Array.isArray(actual) && Array.isArray(expected)
      ? actual.length === expected.length && actual.every((value, index) => value === expected[index])
      : Object.is(actual, expected);
  if (same) return;
  throw new Error(
    `${what}\n  expected: ${render(expected)}\n  actual:   ${render(actual)}\n` +
      `  command printed:\n${indent(output)}`,
  );
}

/** Name order is the query's own: sorted by name as UTF-8 bytes (`query.run`'s `matchLessThan`). */
function byBytes(a, b) {
  return Buffer.compare(Buffer.from(a, 'utf8'), Buffer.from(b, 'utf8'));
}

// ──────────────────────────────────────────────
// Fixture and trio reader
// ──────────────────────────────────────────────

/** Write one file, creating its parent directories; `name` is root-relative with `/` separators. */
function plant(root, name, contents) {
  const path = join(root, name);
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, contents);
}

/**
 * The tree the query tests run against:
 *
 *   .gitignore                     excludes secret.txt and build/ (both stay on disk)
 *   top.txt  release.v2.txt  notes.md  archive.tar.gz  secret.txt
 *   src/Main.java  src/notes.txt  src/deep/deep.txt  src/deep/Deep.java
 *   other/src/other.java
 *   build/generated.txt
 *
 * It has nested directories, several extensions, names with a dot in the middle (`release.v2.txt`,
 * `archive.tar.gz`) and two things the trio must not report: an ignored file and an ignored directory's child.
 * `refresh` publishes it; the summary is the CLI's own statement of what it published.
 */
function publishTree() {
  const root = scratch();
  plant(root, '.gitignore', 'secret.txt\nbuild/\n');
  plant(root, 'top.txt', 'top\n');
  plant(root, 'release.v2.txt', 'release\n');
  plant(root, 'notes.md', '# notes\n');
  plant(root, 'archive.tar.gz', 'gz\n');
  plant(root, 'secret.txt', 'secret\n');
  plant(root, 'src/Main.java', 'class Main {}\n');
  plant(root, 'src/notes.txt', 'src notes\n');
  plant(root, 'src/deep/deep.txt', 'deep\n');
  plant(root, 'src/deep/Deep.java', 'class Deep {}\n');
  plant(root, 'other/src/other.java', 'class Other {}\n');
  plant(root, 'build/generated.txt', 'generated\n');
  const summary = runOk('refresh', root);
  return { root, summary };
}

/**
 * Read the trio the way a reader must. `files.txt` is the names in order, each LF-terminated; `files.meta` is one
 * 64-byte little-endian record per name (FORMAT.md §5), but its records are ordered by `(nameHash, name)`, not by
 * `files.txt` order (AGENTS.md §2), so each record's `nameOffset`/`nameLength` pair is what pairs it with its name.
 * These values are the reference the CLI's output is checked against; a u64 does not fit a JS number, so every one
 * is kept as a decimal string.
 */
function readTrio(root) {
  const dir = join(root, '.fs-meta');
  const txt = readFileSync(join(dir, 'files.txt'));
  const names = txt.toString('utf8').split('\n');
  if (names.at(-1) !== '') {
    throw new Error(`files.txt must end with LF; it ends with ${JSON.stringify(names.at(-1))}`);
  }
  names.pop();

  const meta = readFileSync(join(dir, 'files.meta'));
  if (meta.length !== names.length * 64) {
    throw new Error(`files.meta must be ${names.length} records of 64 bytes; it is ${meta.length} bytes`);
  }

  const byName = new Map();
  for (let index = 0; index < names.length; index += 1) {
    const at = index * 64;
    const offset = Number(meta.readBigUInt64LE(at + 32));
    const length = meta.readUInt32LE(at + 40);
    const stored = txt.subarray(offset, offset + length).toString('utf8');
    const entry = {
      storedName: stored,
      // A directory's stored name ends with `/` (FORMAT.md §3); the cache keys it without.
      name: stored.endsWith('/') ? stored.slice(0, -1) : stored,
      mtime_ns: meta.readBigUInt64LE(at).toString(),
      size_bytes: meta.readBigUInt64LE(at + 8).toString(),
      content_hash: meta.readBigUInt64LE(at + 16).toString(),
      name_hash: meta.readBigUInt64LE(at + 24).toString(),
      name_length: length,
      flags_word: meta.readUInt32LE(at + 44),
      file_id_lo: meta.readBigUInt64LE(at + 48).toString(),
      file_id_hi: meta.readBigUInt64LE(at + 56).toString(),
    };
    byName.set(entry.name, entry);
  }
  if (byName.size !== names.length) {
    throw new Error(`the trio's records pair to ${byName.size} distinct names, but files.txt has ${names.length}`);
  }
  return { names, byName };
}

/**
 * Split a query's text output into its matches. The contract is one line of four space-separated fields —
 * `name mtimeNs sizeBytes contentHash` — then a final `<n> names` line. The fourth field is a **decimal** u64:
 * both `runGlob` and `runChanged` print `entry.content_hash` with `{d}`, and `query.toJson` does the same.
 *
 * A name containing a space would make the line ambiguous; the fixture deliberately uses dots, not spaces.
 */
function parseMatches(stdout, label) {
  const lines = stdout.split('\n');
  if (lines.at(-1) !== '') {
    throw new Error(`${label}: output must end with a newline; it printed:\n${indent(stdout)}`);
  }
  lines.pop();

  const footer = lines.pop();
  const counted = /^(\d+) names$/.exec(footer ?? '');
  if (counted === null) {
    throw new Error(
      `${label}: last line must be "<n> names"; it printed ${JSON.stringify(footer)}\n` +
        `  command printed:\n${indent(stdout)}`,
    );
  }

  const matches = lines.map((line) => {
    const fields = line.split(' ');
    if (fields.length !== 4) {
      throw new Error(
        `${label}: each match line must be four space-separated fields (name mtimeNs sizeBytes contentHash); ` +
          `it printed ${JSON.stringify(line)}`,
      );
    }
    const [name, mtime_ns, size_bytes, content_hash] = fields;
    for (const [field, value] of [
      ['mtime_ns', mtime_ns],
      ['size_bytes', size_bytes],
      ['content_hash', content_hash],
    ]) {
      if (!/^\d+$/.test(value)) {
        throw new Error(
          `${label}: ${field} of ${JSON.stringify(name)} must be a decimal integer; the line printed ${JSON.stringify(value)}`,
        );
      }
    }
    return { name, mtime_ns, size_bytes, content_hash };
  });

  if (Number(counted[1]) !== matches.length) {
    throw new Error(
      `${label}: the footer says ${counted[1]} names, but ${matches.length} match lines were printed\n` +
        `  command printed:\n${indent(stdout)}`,
    );
  }
  return matches;
}

/** Every printed match must be exactly the entry the trio holds for that name. */
function checkTrioFields(matches, trio, label, stdout) {
  for (const match of matches) {
    const entry = trio.byName.get(match.name);
    if (entry === undefined) {
      throw new Error(
        `${label}: ${JSON.stringify(match.name)} is not a trio name (files.txt has ${trio.names.length} names)\n` +
          `  command printed:\n${indent(stdout)}`,
      );
    }
    check(match.mtime_ns, entry.mtime_ns, `${label}: mtime_ns (second field) of ${JSON.stringify(match.name)}`, stdout);
    check(match.size_bytes, entry.size_bytes, `${label}: size_bytes (third field) of ${JSON.stringify(match.name)}`, stdout);
    check(
      match.content_hash,
      entry.content_hash,
      `${label}: content_hash (fourth field) of ${JSON.stringify(match.name)}`,
      stdout,
    );
  }
}

// ──────────────────────────────────────────────
// `match`
// ──────────────────────────────────────────────

describe('fsmeta match', () => {
  test('answers from the trio, not from the disk', () => {
    const { root, summary } = publishTree();
    const trio = readTrio(root);

    check(
      summary.startsWith(`generation 1, ${trio.names.length} names, published yes`),
      true,
      `refresh should publish generation 1 with the trio's own name count; it printed ${JSON.stringify(summary)}`,
      summary,
    );
    check(trio.names.length, 14, 'the published trio should hold 14 names (10 files and 4 directories)', '');

    // Both of these are on disk, and .gitignore keeps both out of the trio.
    check(existsSync(join(root, 'secret.txt')), true, 'the fixture should have secret.txt on disk', '');
    check(existsSync(join(root, 'build', 'generated.txt')), true, 'the fixture should have build/generated.txt on disk', '');
    check(trio.byName.has('secret.txt'), false, 'secret.txt is on disk but ignored, so the trio must not name it', '');
    check(
      trio.byName.has('build/generated.txt'),
      false,
      'build/ is ignored, so the trio must not name the directory or its child',
      '',
    );

    const ignored = runOk('match', root, 'secret.txt');
    check(ignored, '0 names\n', `match 'secret.txt': an ignored file on disk is not a trio name`, ignored);
    const ignoredDir = runOk('match', root, 'build/generated.txt');
    check(ignoredDir, '0 names\n', `match 'build/generated.txt': an ignored directory's child is not a trio name`, ignoredDir);
  });

  test('a pattern without "/" matches a basename at any depth; src/*.java is one level', () => {
    const { root } = publishTree();

    const text = runOk('match', root, '*.txt');
    const matches = parseMatches(text, `match ${root} '*.txt'`);
    const names = matches.map((match) => match.name);
    const expected = ['release.v2.txt', 'src/deep/deep.txt', 'src/notes.txt', 'top.txt'];

    check(
      names,
      expected,
      `match '*.txt' should find the top-level, nested and dot-in-the-middle .txt files, in name order`,
      text,
    );
    check(
      text.endsWith(`${matches.length} names\n`),
      true,
      `match '*.txt' should end with its own count ("${expected.length} names"), not a different number`,
      text,
    );
    check(names.length, 4, 'match \'*.txt\' should report four matches (the ignored .txt files are not in the trio)', text);
    check(names.includes('secret.txt'), false, 'the ignored secret.txt is on disk and must not be reported', text);
    check(names.includes('build/generated.txt'), false, 'the ignored build/generated.txt must not be reported', text);

    const java = runOk('match', root, 'src/*.java');
    const javaMatches = parseMatches(java, `match ${root} 'src/*.java'`);
    check(
      javaMatches.map((match) => match.name),
      ['src/Main.java'],
      `match 'src/*.java' is anchored to the query root: only the direct child src/*.java may match`,
      java,
    );
    check(
      java.endsWith('1 names\n'),
      true,
      `match 'src/*.java' should end with "1 names" (the CLI's wording for a single match)`,
      java,
    );
  });

  test('each line is the trio entry: name, mtimeNs, sizeBytes, contentHash', () => {
    const { root } = publishTree();
    const trio = readTrio(root);
    const text = runOk('match', root, '*.txt');
    const matches = parseMatches(text, `match ${root} '*.txt'`);

    check(matches.length, 4, 'the .txt fixture should produce four lines to check against the trio', text);
    check(matches.map((match) => match.name), [...matches.map((match) => match.name)].sort(byBytes), 'the matches must be name-ordered', text);
    checkTrioFields(matches, trio, `match ${root} '*.txt'`, text);
  });
});

// ──────────────────────────────────────────────
// `glob` alias
// ──────────────────────────────────────────────

describe('fsmeta glob (alias)', () => {
  test('prints exactly what match prints, text and JSON', () => {
    const { root } = publishTree();

    const matched = runOk('match', root, '*.txt');
    const aliased = runOk('glob', root, '*.txt');
    check(aliased, matched, `glob is the deprecated alias of match: the text output must be identical`, aliased);

    const matchedJson = runOk('match', root, '*.txt', '--json');
    const aliasedJson = runOk('glob', root, '*.txt', '--json');
    check(aliasedJson, matchedJson, `glob --json must be identical to match --json`, aliasedJson);
  });
});

// ──────────────────────────────────────────────
// `--json`
// ──────────────────────────────────────────────

// The fields `query.toJson` emits, in the order it emits them. A field added, removed or renamed here is a change
// a consumer sees, so the test pins the set and the order, not merely "some JSON".
const JSON_FIELDS = [
  'name',
  'mtime_ns',
  'size_bytes',
  'content_hash',
  'name_hash',
  'name_offset',
  'name_length',
  'flags_word',
  'file_id_lo',
  'file_id_hi',
];
const JSON_INTEGER_FIELDS = JSON_FIELDS.filter((field) => field !== 'name');

/**
 * Re-parse the JSON with every integer field quoted first. `JSON.parse` returns all numbers as doubles, and an
 * mtimeNs (≈1.8e18) does not survive that; comparing `String(parsed.mtime_ns)` would compare a rounded value, not
 * the one the command emitted. The untouched `JSON.parse` above already proves the document is valid JSON.
 */
function parseExactIntegers(raw) {
  const quoted = raw.replace(new RegExp(`("(?:${JSON_INTEGER_FIELDS.join('|')})": )(\\d+)`, 'g'), '$1"$2"');
  return JSON.parse(quoted);
}

describe('fsmeta match --json', () => {
  test('is the query.toJson array: same membership as the text output, exact entry values', () => {
    const { root } = publishTree();
    const trio = readTrio(root);

    const text = runOk('match', root, '*.txt');
    const textMatches = parseMatches(text, `match ${root} '*.txt'`);
    const raw = runOk('match', root, '*.txt', '--json');
    check(raw.startsWith('[\n'), true, '--json should print a pretty-printed array, starting with "[\\n"', raw);
    check(raw.endsWith(']\n'), true, '--json should print a pretty-printed array, ending with "]\\n"', raw);

    const parsed = JSON.parse(raw);
    check(Array.isArray(parsed), true, '--json must parse to a JSON array', raw);
    check(
      parsed.map((entry) => entry.name),
      textMatches.map((match) => match.name),
      '--json must contain the same names in the same order as the text output',
      raw,
    );

    for (const entry of parsed) {
      check(Object.keys(entry), JSON_FIELDS, `--json object fields for ${JSON.stringify(entry.name)}`, raw);
      for (const field of JSON_INTEGER_FIELDS) {
        check(
          typeof entry[field],
          'number',
          `--json ${field} of ${JSON.stringify(entry.name)} must be an unquoted JSON number, not ${typeof entry[field]}`,
          raw,
        );
      }
    }

    const entries = parseExactIntegers(raw);
    check(entries.length, textMatches.length, '--json must have one object per matched line', raw);

    for (const entry of entries) {
      const stored = trio.byName.get(entry.name);
      if (stored === undefined) {
        throw new Error(`--json: ${JSON.stringify(entry.name)} is not a trio name\n  command printed:\n${indent(raw)}`);
      }
      const label = `--json ${entry.name}:`;
      check(entry.mtime_ns, stored.mtime_ns, `${label} mtime_ns`, raw);
      check(entry.size_bytes, stored.size_bytes, `${label} size_bytes`, raw);
      check(entry.content_hash, stored.content_hash, `${label} content_hash`, raw);
      check(entry.name_hash, stored.name_hash, `${label} name_hash`, raw);
      check(entry.name_length, String(Buffer.byteLength(entry.name, 'utf8')), `${label} name_length is the name's byte length`, raw);
      // `flags_word` is the trio's word, not a projection: in text-hash mode the writer sets HASH_LF, and a query
      // that dropped it would tell a consumer the file is not LF-normalised. (It was a projection until this bit
      // was found missing here; `src/query.zig` now sets every bit the cache can answer.)
      check(entry.flags_word, String(stored.flags_word), `${label} flags_word is the trio's word`, raw);
      // `name_offset` is the one field the cache cannot answer (it is keyed by name, not by an offset into
      // files.txt), so only its shape is pinned; `src/query.zig`'s `Match` documents that.
      check(/^\d+$/.test(entry.name_offset), true, `${label} name_offset must be a decimal integer, it printed ${JSON.stringify(entry.name_offset)}`, raw);
      check(entry.file_id_lo, stored.file_id_lo, `${label} file_id_lo`, raw);
      check(entry.file_id_hi, stored.file_id_hi, `${label} file_id_hi`, raw);
    }
  });
});

// ──────────────────────────────────────────────
// `--since` and `changed`
// ──────────────────────────────────────────────

describe('fsmeta --since / changed', () => {
  test('1h keeps a freshly published tree; the filter is mtime >= since; changed agrees for the window', () => {
    const { root } = publishTree();
    // A file written after the first publish, then a republish: the point is that the query sees the new trio,
    // not whether the clock happened to move between the two commands.
    plant(root, 'fresh.txt', 'fresh\n');
    const summary = runOk('refresh', root);
    check(
      summary.startsWith('generation 2,'),
      true,
      `the second refresh should publish generation 2, it printed ${JSON.stringify(summary)}`,
      summary,
    );

    const trio = readTrio(root);
    const all = runOk('match', root, '*.txt');
    const allMatches = parseMatches(all, `match ${root} '*.txt'`);
    check(allMatches.length, 5, 'the republished tree should have five .txt files', all);
    check(allMatches.some((match) => match.name === 'fresh.txt'), true, 'fresh.txt must be in the republished trio', all);

    const withinHour = runOk('match', root, '*.txt', '--since', '1h');
    check(withinHour, all, `match '*.txt' --since 1h must keep every entry published moments ago`, withinHour);
    check(
      parseMatches(withinHour, `match ${root} '*.txt' --since 1h`).length,
      allMatches.length,
      'match --since 1h must not drop a fresh entry',
      withinHour,
    );

    // The predicate is `mtime_ns >= since` (query.zig), so an instant older than the entries keeps all of them and
    // only an instant after every mtime drops them. Pinning both directions keeps the filter from silently
    // inverting.
    const oldInstant = '2020-01-01T00:00:00Z';
    const oldText = runOk('match', root, '*.txt', '--since', oldInstant);
    check(oldText, all, `--since ${oldInstant} is older than every mtime, so it must keep every match`, oldText);

    const futureInstant = '2030-01-01T00:00:00Z';
    const futureText = runOk('match', root, '*.txt', '--since', futureInstant);
    check(futureText, '0 names\n', `--since ${futureInstant} is after every mtime, so it must match nothing`, futureText);
    const futureJson = runOk('match', root, '*.txt', '--since', futureInstant, '--json');
    check(futureJson, '[]\n', `--since ${futureInstant} --json must print the empty array`, futureJson);

    // `changed <root> 1h` is the same query without a pattern; `match <root> '*' --since 1h` is that pattern. They
    // must agree byte for byte, directories included.
    const changed = runOk('changed', root, '1h');
    const wildcard = runOk('match', root, '*', '--since', '1h');
    check(changed, wildcard, `changed ${root} 1h must equal match ${root} '*' --since 1h`, changed);

    const changedMatches = parseMatches(changed, `changed ${root} 1h`);
    check(changedMatches.length, trio.names.length, 'changed 1h must name every trio entry, directories included', changed);
    check(
      changedMatches.map((match) => match.name),
      [...trio.byName.keys()].sort(byBytes),
      'changed 1h must name the trio set in name order',
      changed,
    );
  });
});

// ──────────────────────────────────────────────
// Exit codes and error paths
// ──────────────────────────────────────────────

describe('fsmeta query exit codes', () => {
  test('usage errors exit 2 with a message and the usage text on stdout', () => {
    const { root } = publishTree();

    const noPattern = run('match', root);
    check(noPattern.code, 2, 'match without a pattern is a usage error and must exit 2', noPattern.stdout);
    check(
      noPattern.stdout.startsWith('fsmeta: match needs a pattern\n'),
      true,
      'the message must name the missing pattern and the command (`match`; `glob` is the deprecated alias)',
      noPattern.stdout,
    );
    check(noPattern.stdout.includes('\nusage:'), true, 'a usage error must print the usage text', noPattern.stdout);
    check(noPattern.stderr, '', 'usage errors are printed to stdout, not stderr', noPattern.stderr);

    const unknown = run('match', root, '*.txt', '--bogus');
    check(unknown.code, 2, 'an unknown option is a usage error and must exit 2', unknown.stdout);
    check(
      unknown.stdout.startsWith('fsmeta: unknown option\n'),
      true,
      'the message must name the unknown option',
      unknown.stdout,
    );

    const badSince = run('changed', root, 'not-a-date');
    check(badSince.code, 2, 'changed with an unparseable since must exit 2', badSince.stdout);
    check(
      badSince.stdout.startsWith('fsmeta: invalid since timestamp\n'),
      true,
      'the message must say the since timestamp is invalid',
      badSince.stdout,
    );
  });

  test('match rejects an unparseable --since instead of silently dropping the filter', () => {
    const { root } = publishTree();

    // `runGlob` used to map a parse failure to `null`, which means "no filter": the command answered a *wider*
    // question than the one asked, with exit 0. It now refuses exactly like `runChanged` does.
    const invalid = run('match', root, '*.txt', '--since', 'not-a-date');
    check(invalid.code, 2, 'match with an unparseable --since must exit 2, like changed', invalid.stdout);
    check(
      invalid.stdout.startsWith('fsmeta: invalid since timestamp\n'),
      true,
      'the message must say the since timestamp is invalid',
      invalid.stdout,
    );
    check(invalid.stdout.includes('\nusage:'), true, 'the refusal carries the usage text', invalid.stdout);

    // A parseable filter still filters: the same query with a real timestamp answers normally.
    const filtered = runOk('match', root, '*.txt', '--since', '1h');
    check(filtered.length > 0, true, 'a parseable --since still answers', filtered);
  });

  test('a query on a tree with no trio fails with the raw TrioMissing error: exit 1, empty stdout', () => {
    const empty = scratch();
    const noTrio = run('match', empty, '*.txt');
    check(noTrio.code, 1, 'a query whose trio cannot be loaded must exit 1 (the subject failed)', noTrio.stdout);
    check(
      noTrio.stdout,
      '',
      "loadCache's error is uncaught, so nothing is printed to stdout (unlike serve's friendly message)",
      noTrio.stdout,
    );
    check(
      noTrio.stderr.includes('error: TrioMissing'),
      true,
      'stderr must name the error the CLI returned (TrioMissing)',
      noTrio.stderr,
    );

    // loadCache maps a root it cannot even open to the same error, so a missing root and a root without a trio are
    // the same failure.
    const absent = run('match', join(empty, 'does-not-exist'), '*.txt');
    check(absent.code, 1, 'a missing root must exit 1 like a root without a trio', absent.stdout);
    check(absent.stdout, '', 'a missing root prints nothing to stdout', absent.stdout);
    check(
      absent.stderr.includes('error: TrioMissing'),
      true,
      'a missing root maps to error.TrioMissing in loadCache, so stderr must name it',
      absent.stderr,
    );
  });
});
