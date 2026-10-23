#!/usr/bin/env bun
// Portability: a trio describes a workspace, not a path.
//
//   bun test test
//
// § 3.1 of FORMAT.md states the invariant these tests enforce — a trio contains no absolute path, names are
// workspace-relative, the root argument is only a locator — and a reader's three uses of it are:
//
//   1. the same tree published through an absolute root and through a relative root is byte-identical;
//   2. a workspace copied somewhere else still verifies there;
//   3. a renamed workspace still verifies, and a reconcile still reads its batches by their relative names.
//
// They drive the built CLI (`zig-out/bin/fsmeta.exe`), like `reconcile.test.mjs`, because the bug they guard
// against lived in the path between the engine and a consumer: the root argument reaching the stored bytes.
import { afterAll, describe, expect, test } from 'bun:test';
import { execFileSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs';
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
 * Scratch under the project's `.tmp/`, and a *parent* directory rather than a tree: one caller runs the CLI with
 * its cwd set here so the root argument is relative, and it needs the tree to sit below it.
 *
 * Being inside the checkout is a convenience, not a requirement — a trio is portable, and this file proves it by
 * moving one. It stays here because the engine's own scratch convention is `.tmp/` (AGENTS.md § 5).
 */
function scratch() {
  const base = join(here, '..', '.tmp');
  mkdirSync(base, { recursive: true });
  const dir = mkdtempSync(join(base, 'pt-'));
  roots.push(dir);
  return dir;
}

/** The tree every test here publishes: two files and a folder, one level down. */
function buildTree(root) {
  mkdirSync(join(root, 'src'), { recursive: true });
  writeFileSync(join(root, 'a.txt'), 'one\n');
  writeFileSync(join(root, 'src', 'b.java'), 'class B {}\n');
  writeFileSync(join(root, 'src', 'c.java'), 'class C {}\n');
}

const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

/**
 * Waits until the directories' own mtimes stop moving.
 *
 * NTFS defers a directory's mtime update after a file inside it is written, so `src`'s timestamp can still change a
 * millisecond or two after its files are closed. That is the tree's own metadata settling, not the publish: without
 * this wait, the byte comparison below is between two truthful trios of two slightly different instants, and it
 * fails about half the time for a reason that has nothing to do with the root argument.
 */
async function settle(directories) {
  let previous = null;
  for (let attempt = 0; attempt < 40; attempt += 1) {
    const current = directories.map((directory) => statSync(directory, { bigint: true }).mtimeNs).join('|');
    if (current === previous) {
      return;
    }
    previous = current;
    await sleep(15);
  }
  throw new Error(`the tree's directory mtimes never settled: ${directories.join(', ')}`);
}

/** Runs the CLI and returns its stdout; a non-zero exit is an exception, which is what a test wants. */
function run(args, options = {}) {
  return execFileSync(binary, args, { encoding: 'utf8', cwd: here, ...options });
}

/** The three files of a trio, as bytes: byte equality is the claim, so nothing is decoded on the way. */
function trio(tree) {
  const meta = join(tree, '.fs-meta');
  return {
    meta: readFileSync(join(meta, 'files.meta')),
    txt: readFileSync(join(meta, 'files.txt')),
    json: readFileSync(join(meta, 'files.json')),
  };
}

describe('a trio names a workspace, not a path', () => {
  test('an absolute root and a relative root publish byte-identical files', async () => {
    const parent = scratch();
    const tree = join(parent, 'tree');
    buildTree(tree);
    await settle([tree, join(tree, 'src')]);
    const stamp = '2026-10-24T00:00:00Z';

    const absolute = run(['refresh', tree, '--updated', stamp, '--hash', 'text']);
    expect(absolute).toContain('generation 1');
    const published = trio(tree);

    // Nothing stored may carry a location: no `rootPath` member, and not even the text of the root we passed.
    const document = published.json.toString('utf8');
    expect(JSON.parse(document).rootPath).toBeUndefined();
    expect(document).not.toContain(tree);
    expect(document).not.toContain(parent);

    // The same tree again, with its trio removed: the generation returns to 1 and no mtime was touched, so a byte
    // difference could only come from the root argument — and there is none.
    rmSync(join(tree, '.fs-meta'), { recursive: true, force: true });
    const relative = run(['refresh', 'tree', '--updated', stamp, '--hash', 'text'], { cwd: parent });
    expect(relative).toContain('generation 1');
    const republished = trio(tree);

    // All three at once, so a failure says *which* files moved rather than stopping at the first.
    const same = Object.fromEntries(['meta', 'txt', 'json'].map((name) => [name, republished[name].equals(published[name])]));
    expect(same).toEqual({ meta: true, txt: true, json: true });
  });

  test('a copied workspace verifies in its new location', () => {
    const parent = scratch();
    const original = join(parent, 'ws');
    buildTree(original);
    run(['refresh', original, '--updated', '2026-10-24T00:00:00Z']);

    // A copy is a different path to the same names, which is all the trio claims to describe.
    const copy = join(parent, 'elsewhere');
    cpSync(original, copy, { recursive: true });

    // Reachable absolutely and relatively: the locator is resolved at the boundary, and nothing else changes.
    expect(run(['verify', copy])).toContain('ok');
    expect(run(['verify', 'elsewhere'], { cwd: parent })).toContain('ok');
  });

  test('a renamed workspace verifies, and its batches still name files relatively', () => {
    const parent = scratch();
    const before = join(parent, 'before');
    buildTree(before);
    run(['refresh', before, '--updated', '2026-10-24T00:00:00Z']);
    // The size changes too, so the change is visible even if two writes land in the same mtime tick.
    writeFileSync(join(before, 'a.txt'), 'two, and longer\n');
    run(['refresh', before, '--updated', '2026-10-24T00:00:01Z']);

    const after = join(parent, 'after');
    renameSync(before, after);

    expect(run(['verify', after])).toContain('ok');
    const changes = run(['reconcile', after, '1']);
    expect(changes).toContain('changed a.txt');
    expect(changes).toContain('1 names');
    for (const path of [after, parent]) {
      expect(changes).not.toContain(path);
    }
  });
});
