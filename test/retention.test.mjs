#!/usr/bin/env bun
// Retention (FORMAT.md § 17.6), driven through the built CLI.
//
//   bun test test/retention.test.mjs
//
// The whole point of a retention window is that `batch-too-old` is *reachable*: without rotation it can only be
// produced by deleting a batch directory by hand, which is corruption rather than policy. This file publishes past
// the documented default window and then asks a consumer on either side of it, because the answer — `batch-too-old`
// below the window, an ordinary reconcile inside it — is what makes the policy real.
import { afterAll, describe, expect, test } from 'bun:test';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const binary = join(here, '..', 'zig-out', 'bin', process.platform === 'win32' ? 'fsmeta.exe' : 'fsmeta');
if (!existsSync(binary)) {
  throw new Error(`build the engine first: zig build (expected ${binary})`);
}

// The documented default (FORMAT.md § 17.6): the newest 32 generations are retained, and the newest is always
// kept. Publishing two generations beyond the window must therefore drop exactly the oldest two — a change to the
// default is a change to the format document first, and this test should fail until both are updated together.
const KEEP = 32;
const PUBLISHED = KEEP + 2;
const OLDEST_RETAINED = PUBLISHED - KEEP + 1; // generation 3
const DROPPED = OLDEST_RETAINED - 1; // generations 1 and 2

const roots = [];
afterAll(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true });
});

/** Scratch under the project's `.tmp/`, for the reason `reconcile.test.mjs` gives: the engine refuses a root outside it. */
function scratch() {
  const base = join(here, '..', '.tmp');
  mkdirSync(base, { recursive: true });
  const dir = mkdtempSync(join(base, 'retention-'));
  roots.push(dir);
  return dir;
}

/** The batch id a generation gets: lowercase hex, zero-padded to eight digits (FORMAT.md § 17.1). */
function batchId(generation) {
  return generation.toString(16).padStart(8, '0');
}

function publish(root, generation) {
  return execFileSync(binary, ['refresh', root, '--updated', `2026-10-24T00:00:${String(generation).padStart(2, '0')}Z`], {
    encoding: 'utf8',
    cwd: here,
  });
}

/** Runs a batch-history command and returns { code, stdout } — a refusal is an exit code, not an exception to hide. */
function batchCommand(command, root, ...args) {
  try {
    const stdout = execFileSync(binary, [command, root, ...args], { encoding: 'utf8', cwd: here });
    return { code: 0, stdout };
  } catch (error) {
    return { code: error.status ?? 1, stdout: String(error.stdout ?? '') };
  }
}

function reconcile(root, ...args) {
  return batchCommand('reconcile', root, ...args);
}

/**
 * One tree that published `PUBLISHED` generations, so the window has rotated twice.
 *
 * The content changes length every time as well as its mtime, so "this file is dirty" does not depend on the
 * file system's timestamp resolution; every pass publishes a generation with a non-empty change set, which is
 * also what makes every generation get a batch.
 */
let prepared;
function publishedTree() {
  if (prepared) return prepared;
  const root = scratch();
  writeFileSync(join(root, 'a.txt'), 'value 1 x\n');
  publish(root, 1);
  for (let generation = 2; generation <= PUBLISHED; generation += 1) {
    writeFileSync(join(root, 'a.txt'), `value ${generation} ${'x'.repeat(generation)}\n`);
    publish(root, generation);
  }
  prepared = root;
  return root;
}

describe('the retention window (FORMAT.md § 17.6)', () => {
  test('a rotation keeps the newest generations and drops the oldest, without a hand-deleted directory', () => {
    const root = publishedTree();
    const batches = readdirSync(join(root, '.fs-meta', 'batches'))
      .filter((name) => /^[0-9a-f]{8}$/.test(name))
      .sort();

    // Exactly the window: the published count minus the two generations older than it.
    expect(batches).toHaveLength(KEEP);
    expect(batches).toContain(batchId(OLDEST_RETAINED));
    expect(batches).toContain(batchId(PUBLISHED));
    // The two that fell out of the window, and nothing newer: rotation only ever removes a prefix.
    expect(batches).not.toContain(batchId(1));
    expect(batches).not.toContain(batchId(DROPPED));
    expect(batches[0]).toBe(batchId(OLDEST_RETAINED));
  });

  test('a consumer older than the oldest retained batch is told batch-too-old, not given a shortened answer', () => {
    const root = publishedTree();

    // Generation 1 needs batch 2, which the rotation removed: an explicit refusal and a non-zero exit.
    const tooOld = reconcile(root, '1');
    expect(tooOld.code).not.toBe(0);
    expect(tooOld.stdout).toContain('batch-too-old');

    // The boundary is the oldest retained batch, not the newest dropped generation: `from = 2` needs batch 3,
    // which is still there, so this reconciles normally.
    const boundary = reconcile(root, '2');
    expect(boundary.code).toBe(0);
    expect(boundary.stdout).not.toContain('batch-too-old');
    expect(boundary.stdout).toMatch(/\d+ names/);

    // A consumer sitting on the oldest retained batch itself still works.
    const oldest = reconcile(root, String(OLDEST_RETAINED));
    expect(oldest.code).toBe(0);
    expect(oldest.stdout).not.toContain('batch-');
    expect(oldest.stdout).toMatch(/\d+ names/);
  });
});
