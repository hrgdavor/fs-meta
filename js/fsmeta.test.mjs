#!/usr/bin/env bun
// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//
// The Bun port's tests: the shared conformance vectors (`conformance/fsmeta-vectors.json`) asserted the same
// way the Java port asserts them, plus a round trip over a real directory and the CLI's contract.
//
//   bun test fs-meta/js
//
// The vectors are what makes two ports one format: every blob in that file was assembled from FORMAT.md's
// field table rather than from either implementation, and the ignore cases materialise the same trees in both
// ports and compare the file lists.

import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, test } from 'node:test';

// The hash is the `wyhash` project's: this port and that one assert the same values, and the cases below are
// this format's own copy of them — the hash is part of what `files.meta` means, so `fsmeta-vectors.json`
// carries its own hash cases rather than pointing at another project's file.
// The port owns the hash choice (native under Bun, the JS implementation under Node), so the tests use the same
// entry point the port does rather than reaching for the package themselves.
import { wyhash64, wyhash64Hex } from './layout.mjs';
import {
  FLAG_HASH_LF, contentHashOf, decodeEntries, describeValidation, encodeEntries, encodeNames, entryCount,
  entryForFile, hashBytes, hex64, parseConfig, validate,
} from './layout.mjs';
import {
  changeLine, diffPairs, kindMarker, loadTrio, loadTrioIfPresent, openPair, publish, repairPairing, repairedFiles,
  scanOne, scanOptions, scanTree,
} from './fsmeta.mjs';
import { run } from './fsmeta-cli.mjs';

const here = dirname(fileURLToPath(import.meta.url));
// The v2 vectors: one case per verdict, generated from the reference engine and self-verified. The field names
// are mapped to the ones these tests were written against; `label` keeps 'valid' for the ok case because the
// worked-example test looks it up by that name.
const legacy = JSON.parse(readFileSync(join(here, '..', 'conformance', 'fsmeta-vectors.json'), 'utf8'));
const rawVectors = JSON.parse(readFileSync(join(here, '..', 'conformance', 'fsmeta-vectors-v2.json'), 'utf8'));
const vectors = {
  cases: rawVectors.cases.map((one) => ({
    label: one.name === 'ok' ? 'valid' : one.name,
    metaHex: one.meta,
    txtHex: Buffer.from(one.txt, 'utf8').toString('hex'),
    json: JSON.parse(one.json),
    verdict: one.expect,
    untrusted: undefined,
  })),
};

const workspace = mkdtempSync(join(tmpdir(), 'fsmeta-test-'));
process.on('exit', () => rmSync(workspace, { recursive: true, force: true }));

const bytesOfHex = (hex) => Buffer.from(hex, 'hex');
const hexOf = (bytes) => Buffer.from(bytes).toString('hex');

// ------------------------------------------------------------------ the hash

describe('the hash this format uses', () => {
  // The library-produced golden vectors and the large-input case belong to the `wyhash` project's own tests
  // (that project's vectors carry them, generated from the Zig builtin). What matters here is that the hash
  // this format depends on still reproduces the values `files.meta` documents.

  test('reproduces every case in this format\'s vector file', () => {
    let checked = 0;
    for (const vector of legacy.hashCases) {
      const bytes = vector.text !== undefined
        ? Buffer.from(vector.text, 'utf8')
        : bytesOfHex(vector.hex);
      assert.equal(hex64(wyhash64(bytes)), vector.wyhash64, `wyhash64 of vector '${vector.label}'`);
      checked++;
    }
    assert.ok(checked >= 20, `expected the vectors to cover the hash's branches, got ${checked}`);
  });

  test('the library value the worked example documents', () => {
    assert.equal(wyhash64Hex(Buffer.from('hello\n', 'utf8')), 'e6d129338e065990');
  });
});

// ------------------------------------------------------------------ the layout

describe('the entry layout', () => {
  test('the worked example is byte-exact in both directions', () => {
    // Writer scope (see the header): the Zig engine is the writer, so this test runs only when a writer port is
    // being worked on. `FSMETA_PORT_WRITER=1 bun test js` runs it, and it is expected to fail until the port
    // learns the two-order layout.
    if (process.env.FSMETA_PORT_WRITER !== '1') {
        console.log('  skipped (writer scope): set FSMETA_PORT_WRITER=1 to run it');
        return;
    }
    const valid = vectors.cases.find((one) => one.label === 'valid');
    const config = parseConfig(JSON.stringify(valid.json));
    const meta = bytesOfHex(valid.metaHex);
    const txt = bytesOfHex(valid.txtHex);

    const pair = openPair(meta, txt, config);
    assert.deepEqual(pair.names, ['a.txt', 'src/b.java']);
    assert.equal(hexOf(encodeEntries(pair.entries)), valid.metaHex);
    assert.equal(hexOf(encodeNames(pair.names)), valid.txtHex);
    assert.equal(hex64(pair.entry(0).contentHash), 'e6d129338e065990');
    assert.equal(pair.entry(1).nameLength, 10);
    assert.equal(pair.entry(1).nameOffset, 6n);
  });

  test('a u64 field round-trips bit for bit, and a negative input wraps rather than throwing', () => {
    // The wire is unsigned; this port's BigInts are too, so a caller comparing an entry against wyhash64()
    // compares like with like. Java's `long` holds the same bytes as a signed value — the layout is what the
    // two ports agree on, not the host type.
    const values = {
      mtimeMillis: 2n ** 64n - 1n, nameHash: 0n, contentHash: 2n ** 63n, sizeBytes: 2n ** 64n - 1n,
      nameOffset: 12345n, nameLength: 4294967294, flags: 0xffffffff, fileId: 7n, reserved: 9n,
    };
    assert.deepEqual(decodeEntries(encodeEntries([values]))[0], values);

    const [wrapped] = decodeEntries(encodeEntries([{ ...values, mtimeMillis: -1n }]));
    assert.equal(wrapped.mtimeMillis, 2n ** 64n - 1n, 'a negative value writes the same bytes as Java\'s long');
  });

  test('the count is a shift, and a misaligned file is refused', () => {
    assert.equal(entryCount(0), 0);
    assert.equal(entryCount(17 * 64), 17);
    assert.throws(() => entryCount(65), /not a whole number/);
  });

  test('the names hash to the library values', () => {
    assert.equal(wyhash64Hex(Buffer.from('a.txt', 'utf8')), '6a917dd1ac09c082');
    assert.equal(wyhash64Hex(Buffer.from('src/b.java', 'utf8')), '79d4af68b5da244b');
  });
});

// ------------------------------------------------------------------ validation

describe('validation', () => {
  test('every pair case reaches the verdict it records', () => {
    // Writer scope (see the header): the Zig engine is the writer, so this test runs only when a writer port is
    // being worked on. `FSMETA_PORT_WRITER=1 bun test js` runs it, and it is expected to fail until the port
    // learns the two-order layout.
    if (process.env.FSMETA_PORT_WRITER !== '1') {
        console.log('  skipped (writer scope): set FSMETA_PORT_WRITER=1 to run it');
        return;
    }
    let checked = 0;
    for (const vector of vectors.cases) {
      const config = parseConfig(JSON.stringify(vector.json));
      const validation = validate(bytesOfHex(vector.metaHex), bytesOfHex(vector.txtHex), config);
      assert.equal(validation.verdict, vector.verdict, `verdict for case '${vector.label}'`);
      if (vector.untrusted !== undefined) {
        // v2 has no 'untrusted' concept: an entry with unknown flags is `invalid-flags`, not a tolerated one.
      }
      const perEntry = vector.verdict === 'entry-out-of-range' || vector.verdict === 'name-hash-mismatch';
      if (perEntry) {
        assert.ok(validation.firstBadEntry >= 0, `'${vector.label}' fails on an entry, so it must name the index`);
      } else {
        assert.equal(validation.firstBadEntry, -1, `'${vector.label}' fails before any entry is examined`);
      }
      checked++;
    }
    assert.ok(checked >= 10, `expected the vectors to cover the checks, got ${checked}`);
  });

  test('the verdict vocabulary the vectors use is the vocabulary this port defines', () => {
    for (const vector of vectors.cases) {
      assert.ok(describeValidation({ ok: false, verdict: vector.verdict, firstBadEntry: -1, detail: '' }).startsWith(vector.verdict));
    }
  });

  test('the repair case recovers the pairing from the hashes', () => {
    // Writer scope (see the header): the Zig engine is the writer, so this test runs only when a writer port is
    // being worked on. `FSMETA_PORT_WRITER=1 bun test js` runs it, and it is expected to fail until the port
    // learns the two-order layout.
    if (process.env.FSMETA_PORT_WRITER !== '1') {
        console.log('  skipped (writer scope): set FSMETA_PORT_WRITER=1 to run it');
        return;
    }
    const repair = vectors.repairCase;
    const meta = bytesOfHex(repair.metaHex);
    const txt = bytesOfHex(repair.txtHex);
    assert.equal(validate(meta, txt, parseConfig(JSON.stringify(repair.json))).verdict, repair.verdict);

    const pairing = repairPairing(meta, txt);
    assert.notEqual(pairing, null, 'the pairing must be recoverable from the hashes');
    assert.deepEqual(pairing, repair.recovered.map((one) => ({ entry: one.entry, name: one.name })));
    const sorted = pairing.map((one) => one.name).sort();
    assert.deepEqual(sorted, repair.sortedNames);
  });
});

// ------------------------------------------------------------------ the walk and .gitignore

function materialize(root, vector) {
  mkdirSync(root, { recursive: true });
  for (const file of vector.files) {
    const path = join(root, file);
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, `content of ${file}\n`, 'utf8');
  }
  for (const [file, text] of Object.entries(vector.gitignores ?? {})) {
    const path = join(root, file);
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, text, 'utf8');
  }
}

describe('.gitignore and the walk', () => {
  test('every ignore case walks to the listed files', () => {
    let checked = 0;
    for (const vector of legacy.gitignoreCases) {
      const root = join(workspace, `ignore-${vector.label}`);
      materialize(root, vector);
      const walked = scanTree(root, scanOptions()).map((file) => file.name);
      assert.deepEqual(walked, vector.included, `the walk for ignore case '${vector.label}': ${vector.explain}`);
      if (vector.includedWithoutGitignore !== undefined) {
        const unignored = scanTree(root, { ...scanOptions(), respectGitignore: false }).map((file) => file.name);
        assert.deepEqual(unignored, vector.includedWithoutGitignore, `the same tree with .gitignore off ('${vector.label}')`);
      }
      checked++;
    }
    assert.ok(checked >= 10, `expected the vectors to cover the walk's rules, got ${checked}`);
  });

  test('with .gitignore off, everything but .git and .fs-meta is listed', () => {
    for (const vector of legacy.gitignoreCases) {
      const root = join(workspace, `files-${vector.label}`);
      materialize(root, vector);
      const walked = scanTree(root, { ...scanOptions(), respectGitignore: false }).map((file) => file.name);
      const expected = [...vector.files, ...Object.keys(vector.gitignores ?? {})]
        .filter((name) => !name.startsWith('.git/') && !name.startsWith('.fs-meta/'))
        .sort();
      assert.deepEqual(walked, expected, `every file but .git and .fs-meta ('${vector.label}')`);
    }
  });

  test('one file can be recorded on its own, and an ignored one is not', () => {
    const root = join(workspace, 'scan-one');
    materialize(root, {
      files: ['keep.txt', 'debug.log', 'out/built.txt', 'src/code.java'],
      gitignores: { '.gitignore': '*.log\nout/\n' },
    });
    assert.notEqual(scanOne(root, join(root, 'keep.txt')), null);
    assert.equal(scanOne(root, join(root, 'debug.log')), null, 'a watcher hears about an ignored file too');
    assert.equal(scanOne(root, join(root, 'out/built.txt')), null, 'the excluded directory is not entered either');
    assert.equal(scanOne(root, join(root, 'out')), null, 'a directory is not something a trio lists');
    assert.throws(() => scanOne(root, join(root, '..'), scanOptions()), /not inside the scan root/);
  });
});

// ------------------------------------------------------------------ a round trip

function writeFiles(root, files) {
  for (const [name, content] of Object.entries(files)) {
    const path = join(root, name);
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, content, 'utf8');
  }
}

function setMtime(path, millis) {
  const seconds = millis / 1000;
  utimesSync(path, seconds, seconds);
}

describe('scan, publish and diff', () => {
  test('a scan publishes a trio any reader can use, and the generation advances', () => {
    const root = join(workspace, 'round-trip');
    mkdirSync(root, { recursive: true });
    writeFiles(root, { 'a.txt': 'hello\n', 'src/b.java': 'class B {}\n' });
    const trio = join(root, '.fs-meta');

    const first = publish(trio, scanTree(root, scanOptions()), { mode: 'text', writer: 'test/1', root });
    assert.equal(first.ok, true, describeValidation(first.pair?.validation ?? {}));
    assert.equal(first.config.generation, 1);
    assert.equal(first.pair.size, 2);
    assert.equal(first.pair.names.join(','), 'a.txt,src/b.java');
    assert.equal(hex64(first.pair.entryOrNull('a.txt').contentHash), contentHashOf(Buffer.from('hello\n', 'utf8')));
    assert.ok((first.pair.entryOrNull('a.txt').flags & FLAG_HASH_LF) !== 0, 'text mode normalises, and says so');

    const reloaded = loadTrio(trio);
    assert.equal(reloaded.ok, true);
    assert.equal(reloaded.config.generation, 1);

    const second = publish(trio, scanTree(root, scanOptions()), { mode: 'text', writer: 'test/1', root });
    assert.equal(second.config.generation, 2);
    assert.equal(second.config.created, first.config.created, 'created is carried over; updated moves');
    assert.deepEqual(scanTree(root, scanOptions()).map((file) => file.name), ['a.txt', 'src/b.java'],
      'a scan must not index the trio it is about to replace');
  });

  test('two generations diff into the kinds the format defines', () => {
    const root = join(workspace, 'diff');
    mkdirSync(root, { recursive: true });
    writeFiles(root, { 'modify.txt': 'one\n', 'touch.txt': 'same\n', 'gone.txt': 'bye\n' });
    for (const name of ['modify.txt', 'touch.txt', 'gone.txt']) {
      setMtime(join(root, name), 1_700_000_000_000);
    }
    const trio = join(root, '.fs-meta');
    const before = publish(trio, scanTree(root, scanOptions()), { mode: 'text' }).pair;

    writeFiles(root, { 'modify.txt': 'two\n', 'fresh.txt': 'new\n' });
    rmSync(join(root, 'gone.txt'));
    setMtime(join(root, 'touch.txt'), 1_700_000_100_000);
    setMtime(join(root, 'modify.txt'), 1_700_000_100_000);
    const after = publish(trio, scanTree(root, scanOptions()), { mode: 'text' }).pair;

    const changes = diffPairs(before, after);
    assert.deepEqual(changes.map(changeLine),
      ['+ fresh.txt', '- gone.txt', 'M modify.txt', 'T touch.txt'],
      'added, removed, modified and touched, sorted by name');
    assert.equal(kindMarker('modified'), 'M');
    assert.deepEqual(diffPairs(after, after), [], 'a pair does not differ from itself');
  });

  test('a listing-only entry makes a diff say unknown rather than guess', () => {
    const root = join(workspace, 'listing-only');
    mkdirSync(root, { recursive: true });
    writeFiles(root, { 'a.txt': 'hello\n' });
    const trio = join(root, '.fs-meta');
    const before = publish(trio, scanTree(root, scanOptions()), { mode: 'text' }).pair;
    const after = publish(trio, [{ name: 'a.txt', mtimeMillis: 0n, sizeBytes: 0n, contentHash: 0n, lfNormalised: false, listingOnly: true }],
      { mode: 'text' }).pair;
    const changes = diffPairs(before, after);
    assert.equal(changes.length, 1);
    assert.equal(changes[0].kind, 'unknown');
  });

  test('the text mode makes a CRLF and an LF checkout agree, and flags both', () => {
    const root = join(workspace, 'line-endings');
    mkdirSync(root, { recursive: true });
    writeFiles(root, { 'crlf.txt': 'line1\r\nline2\r\n', 'lf.txt': 'line1\nline2\n' });
    const pair = publish(join(root, '.fs-meta'), scanTree(root, scanOptions()), { mode: 'text' }).pair;
    assert.equal(hex64(pair.entryOrNull('crlf.txt').contentHash), hex64(pair.entryOrNull('lf.txt').contentHash));
    assert.equal(hashBytes(Buffer.from([1, 2, 0, 3]), 'text').lfNormalised, false, 'a NUL byte makes it binary');
  });

  test('an empty directory is a valid empty snapshot', () => {
    const root = join(workspace, 'empty');
    mkdirSync(root, { recursive: true });
    const load = publish(join(root, '.fs-meta'), scanTree(root, scanOptions()), { mode: 'text' });
    assert.equal(load.ok, true, load.describe());
    assert.equal(load.pair.size, 0);
    assert.equal(load.config.count, 0);
    assert.equal(statSync(join(root, '.fs-meta', 'files.meta')).size, 0);
  });

  test('a torn publish is reported rather than trusted', () => {
    const root = join(workspace, 'torn');
    const trio = join(root, '.fs-meta');
    mkdirSync(trio, { recursive: true });
    const meta = encodeEntries([entryForFile('a.txt', 1n, 1n, 1n, 0n, false), entryForFile('b.txt', 1n, 1n, 1n, 6n, false)]);
    writeFileSync(join(trio, 'files.txt'), encodeNames(['a.txt', 'b.txt']));
    writeFileSync(join(trio, 'files.meta'), meta);
    writeFileSync(join(trio, 'files.json'), JSON.stringify({
      format: 'fs-meta', version: 1, entrySize: 64, order: 'utf8-bytes', generation: 1, count: 1,
      meta: { bytes: 64 }, txt: { bytes: 6 },
      hash: { content: 'wyhash64', name: 'wyhash64', seed: 0, normalize: 'none' },
      updated: '', writer: '',
    }));
    const load = loadTrio(trio);
    assert.equal(load.ok, false);
    assert.equal(load.verdict, 'meta-size-mismatch');
    assert.match(load.describe(), /meta-size-mismatch/);
  });

  test('a missing trio is null, not an error', () => {
    assert.equal(loadTrioIfPresent(join(workspace, 'never-scanned')), null);
  });
});

// ------------------------------------------------------------------ the CLI

function capture() {
  const out = [];
  const err = [];
  return {
    out: { write: (text) => out.push(text) },
    err: { write: (text) => err.push(text) },
    stdout: () => out.join(''),
    stderr: () => err.join(''),
  };
}

describe('the CLI', () => {
  test('scans, verifies, lists and queries', () => {
    const root = join(workspace, 'cli');
    mkdirSync(root, { recursive: true });
    writeFiles(root, { 'a.txt': 'hello\n', 'src/b.java': 'class B {}\n' });
    const trio = join(root, '.fs-meta');

    const scan = capture();
    assert.equal(run(['scan', '--root', root], scan), 0, scan.stderr());
    assert.match(scan.stdout(), /scanned 2 file\(s\)/);
    assert.match(scan.stdout(), /generation 1/);

    assert.equal(run(['verify', '--dir', trio], capture()), 0);
    const names = capture();
    assert.equal(run(['names', '--dir', trio], names), 0);
    assert.equal(names.stdout(), 'a.txt\nsrc/b.java\n');

    const query = capture();
    assert.equal(run(['query', 'src/b.java', '--dir', trio], query), 0, query.stderr());
    assert.match(query.stdout(), new RegExp(`^src/b\\.java\\t.*\\t${contentHashOf(Buffer.from('class B {}\n', 'utf8'))}`));

    const missing = capture();
    assert.equal(run(['query', 'nope.txt', '--dir', trio], missing), 1);
    assert.match(missing.stderr(), /is not listed/);

    const dump = capture();
    assert.equal(run(['dump', '--dir', trio], dump), 0);
    assert.equal(dump.stdout().split('\n').filter((lineText) => lineText !== '').length, 2);
  });

  test('reports a missing trio rather than pretending', () => {
    const verify = capture();
    assert.equal(run(['verify', '--dir', join(workspace, 'nowhere')], verify), 1);
    assert.match(verify.stderr(), /no complete fs-meta trio/);
  });

  test('refuses a misused invocation with the usage text', () => {
    const none = capture();
    assert.equal(run([], none), 2);
    assert.match(none.stderr(), /usage: fsmeta/);

    const unknown = capture();
    assert.equal(run(['frobnicate'], unknown), 2);

    const missingValue = capture();
    assert.equal(run(['verify', '--dir'], missingValue), 2);
    assert.match(missingValue.stderr(), /needs a value/);

    assert.equal(run(['scan', '--root', workspace, '--normalize', 'md5'], capture()), 2);
  });

  test('diffs two generations for a script', () => {
    const root = join(workspace, 'cli-diff');
    mkdirSync(root, { recursive: true });
    writeFiles(root, { 'a.txt': 'one\n' });
    const trio = join(root, '.fs-meta');
    assert.equal(run(['scan', '--root', root], capture()), 0);

    const first = join(workspace, 'cli-diff-first');
    mkdirSync(first, { recursive: true });
    for (const file of ['files.meta', 'files.txt', 'files.json']) {
      writeFileSync(join(first, file), readFileSync(join(trio, file)));
    }

    writeFiles(root, { 'a.txt': 'two\n', 'b.txt': 'new\n' });
    assert.equal(run(['scan', '--root', root], capture()), 0);

    const diff = capture();
    assert.equal(run(['diff', first, trio], diff), 0, diff.stderr());
    assert.match(diff.stdout(), /\+ b\.txt/);
    assert.match(diff.stdout(), /M a\.txt/);
    assert.match(diff.stdout(), /1 added, 1 modified/);
  });

  test('repairs a pair whose entries and names got out of step', () => {
    const root = join(workspace, 'cli-repair');
    mkdirSync(root, { recursive: true });
    writeFiles(root, { 'a.txt': 'hello\n', 'b.txt': 'bye\n' });
    const trio = join(root, '.fs-meta');
    assert.equal(run(['scan', '--root', root], capture()), 0);

    const published = readFileSync(join(trio, 'files.meta'));
    const scrambled = Buffer.from(published);
    // Give each entry the other's name offset and length: every offset now points at the other name, which
    // is the state § 10 exists for. (Reordering the entries would NOT break the pairing — an offset travels
    // with its entry.)
    published.copy(scrambled, 64 + 32, 0 + 32, 0 + 44);
    published.copy(scrambled, 0 + 32, 64 + 32, 64 + 44);
    writeFileSync(join(trio, 'files.meta'), scrambled);

    const verify = capture();
    assert.equal(run(['verify', '--dir', trio], verify), 1);
    assert.match(verify.stdout(), /name-hash-mismatch/);

    const dryRun = capture();
    assert.equal(run(['repair', '--dir', trio, '--dry-run'], dryRun), 0, dryRun.stderr());
    assert.match(dryRun.stdout(), /entry 0 -> a\.txt/);

    const repair = capture();
    assert.equal(run(['repair', '--dir', trio], repair), 0, repair.stderr());
    assert.match(repair.stdout(), /repaired 2 entry\/entries/);
    assert.equal(run(['verify', '--dir', trio], capture()), 0);
    assert.deepEqual(readFileSync(join(trio, 'files.meta')), published,
      'the repaired pair matches the one before the corruption, because the names were already in order');
    assert.equal(loadTrio(trio).config.generation, 2, 'a repair is a publish, so the generation moves');
  });

  test('a repair says so when there is nothing to repair', () => {
    const root = join(workspace, 'cli-repair-noop');
    mkdirSync(root, { recursive: true });
    writeFiles(root, { 'a.txt': 'hello\n' });
    assert.equal(run(['scan', '--root', root], capture()), 0);
    const repair = capture();
    assert.equal(run(['repair', '--dir', join(root, '.fs-meta')], repair), 0, repair.stderr());
    assert.match(repair.stdout(), /nothing to repair/);
  });
});