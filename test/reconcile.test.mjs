#!/usr/bin/env bun
// Integration tests for the batch history: hex batch ids, the reconcile range, and the optional baseline.
//
//   bun test test
//
// These drive the built CLI (`zig-out/bin/fsmeta.exe`) instead of calling the engine, because every bug this file exists to
// prevent was in the *path between* the engine and a consumer: batch ids that could not be found, a range end that was
// silently ignored, deletions dropped from the change record, and a baseline whose identities could never match.
import { afterAll, describe, expect, test } from 'bun:test';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const binary = join(here, '..', 'zig-out', 'bin', process.platform === 'win32' ? 'fsmeta.exe' : 'fsmeta');
if (!existsSync(binary)) {
  throw new Error(`build the engine first: zig build (expected ${binary})`);
}

const roots = [];
afterAll(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true });
});

/**
 * Scratch under the project's `.tmp/`, not the system temp directory.
 *
 * The engine refuses a root outside the project (its `refresh` answers `FileNotFound` for one under `%TEMP%`), which is a
 * real limitation of its absolute-path handling rather than something this test should work around silently — but a test
 * that cannot create a tree cannot test the CLI. When that limitation is fixed, this helper can move to `tmpdir()` and the
 * comment goes with it.
 */
function scratch() {
  const base = join(here, '..', '.tmp');
  mkdirSync(base, { recursive: true });
  const dir = mkdtempSync(join(base, 'it-'));
  roots.push(dir);
  return dir;
}

/** Publishes the tree's current state, returning the CLI's one-line summary. */
function publish(root, updated) {
  return execFileSync(binary, ['refresh', root, '--updated', updated], { encoding: 'utf8', cwd: here });
}

/** Runs a batch-history command and returns { code, stdout } — the refusals are exit codes, not exceptions to swallow. */
function batchCommand(command, root, ...args) {
  try {
    const stdout = execFileSync(binary, [command, root, ...args], { encoding: 'utf8', cwd: here });
    return { code: 0, stdout };
  } catch (error) {
    return { code: error.status ?? 1, stdout: String(error.stdout ?? '') };
  }
}

/** Runs reconcile; `merge` is its deprecated alias and is exercised by the alias test below. */
function reconcile(root, ...args) {
  return batchCommand('reconcile', root, ...args);
}

describe('the batch history a consumer reads', () => {
  test('batch ids are eight zero-padded hex digits, and generation 16 proves which base', () => {
    const root = scratch();
    writeFileSync(join(root, 'a.txt'), 'one\n');
    publish(root, '2026-10-24T00:00:00Z');
    // Sixteen publishes, one per generation: generation 16 is `00000010` in hex and `00000016` in decimal.
    for (let generation = 2; generation <= 16; generation += 1) {
      writeFileSync(join(root, 'a.txt'), `value ${generation}\n`);
      publish(root, `2026-10-24T00:00:${String(generation).padStart(2, '0')}Z`);
    }
    const batches = readdirSync(join(root, '.fs-meta', 'batches')).filter((name) => /^[0-9a-f]{8}$/.test(name)).sort();
    expect(batches).toContain('0000000a');
    expect(batches).toContain('00000010');
    expect(batches).not.toContain('00000016');
  });

  test('a range reports added, changed and deleted, and honours the end it is given', () => {
    const root = scratch();
    mkdirSync(join(root, 'src'));
    writeFileSync(join(root, 'a.txt'), 'one\n');
    writeFileSync(join(root, 'src', 'b.java'), 'class B {}\n');
    publish(root, '2026-10-24T00:00:00Z');

    writeFileSync(join(root, 'a.txt'), 'two\n');
    rmSync(join(root, 'src', 'b.java'));
    writeFileSync(join(root, 'src', 'c.java'), 'class C {}\n');
    publish(root, '2026-10-24T00:00:01Z');

    const second = reconcile(root, '1');
    expect(second.code).toBe(0);
    expect(second.stdout).toContain('changed a.txt');
    expect(second.stdout).toContain('deleted src/b.java');
    expect(second.stdout).toContain('added src/c.java');

    // An explicit end is honoured: 1..1 is empty, and it used to be ignored entirely.
    expect(reconcile(root, '1', '1').stdout).toContain('0 names');
  });

  test('a range that reaches a batch it does not have is batch-gap, not an empty answer', () => {
    const root = scratch();
    writeFileSync(join(root, 'a.txt'), 'one\n');
    publish(root, '2026-10-24T00:00:00Z');

    const result = reconcile(root, '0', '9');
    expect(result.code).not.toBe(0);
    expect(result.stdout).toContain('batch-gap');
  });

  test('a range older than the retained batches is batch-too-old, not an empty answer', () => {
    const root = scratch();
    writeFileSync(join(root, 'a.txt'), 'one\n');
    publish(root, '2026-10-24T00:00:00Z');
    writeFileSync(join(root, 'a.txt'), 'two\n');
    publish(root, '2026-10-24T00:00:01Z');
    // Dropping the first batch is how retention will present itself: the archive no longer starts at 1.
    rmSync(join(root, '.fs-meta', 'batches', '00000001'), { recursive: true });

    const result = reconcile(root, '0');
    expect(result.code).not.toBe(0);
    expect(result.stdout).toContain('batch-too-old');
  });

  test('the change stream needs no baseline, and a baseline drops a change that came back', () => {
    const root = scratch();
    const snapshot = scratch();
    writeFileSync(join(root, 'a.txt'), 'one\n');
    publish(root, '2026-10-24T00:00:00Z');
    // The state at generation 1, copied out of the tree: a baseline inside the tree would change the tree it describes.
    mkdirSync(join(snapshot, '.fs-meta'));
    for (const file of ['files.meta', 'files.txt', 'files.json']) {
      writeFileSync(join(snapshot, '.fs-meta', file), readFileSync(join(root, '.fs-meta', file)));
    }

    writeFileSync(join(root, 'a.txt'), 'two\n');
    publish(root, '2026-10-24T00:00:01Z');
    writeFileSync(join(root, 'a.txt'), 'one\n');
    publish(root, '2026-10-24T00:00:02Z');

    // The batches saw two changes; seeing them needs nothing but the generation the consumer recorded.
    expect(reconcile(root, '1').stdout).toContain('changed a.txt');
    // With the recorded state, the change has come back to what the consumer already holds.
    const withBaseline = reconcile(root, '1', '--baseline', snapshot);
    expect(withBaseline.code).toBe(0);
    expect(withBaseline.stdout).toContain('0 names');
  });

  test('merge is an alias: it prints exactly what reconcile prints for the same range', () => {
    const root = scratch();
    mkdirSync(join(root, 'src'));
    writeFileSync(join(root, 'a.txt'), 'one\n');
    writeFileSync(join(root, 'src', 'b.java'), 'class B {}\n');
    publish(root, '2026-10-24T00:00:00Z');

    // One change, one add and one delete, all in the generation after the range starts.
    writeFileSync(join(root, 'a.txt'), 'two\n');
    rmSync(join(root, 'src', 'b.java'));
    writeFileSync(join(root, 'src', 'c.java'), 'class C {}\n');
    publish(root, '2026-10-24T00:00:01Z');

    const merged = batchCommand('merge', root, '1');
    const reconciled = reconcile(root, '1');
    expect(merged.code).toBe(0);
    expect(merged.stdout).toBe(reconciled.stdout);
    expect(merged.stdout).toContain('changed a.txt');
    expect(merged.stdout).toContain('deleted src/b.java');
    expect(merged.stdout).toContain('added src/c.java');
    expect(merged.stdout).toContain('3 names');
  });
});