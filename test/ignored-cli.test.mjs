#!/usr/bin/env bun
// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//
// Smoke test for `fsmeta ignored` and for the M1 record it explains: `files.json`'s `scan.ignoreSources`.
//
//   bun test test/ignored-cli.test.mjs
//
// The Zig tests already exercise the sources, the precedence and the no-cross-source negation rule. This file pins
// the two things only the CLI can show: the line shape (`<source> <path>`) and the JSON array
// (`[{ path, source }]`), plus the fact that a plain `refresh` publishes the same sources it recorded.
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

const roots = [];
afterAll(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true });
});

/** Scratch under the project's `.tmp/`, never the system temp directory; removed in `afterAll`. */
function scratch() {
  const base = join(here, '..', '.tmp');
  mkdirSync(base, { recursive: true });
  const dir = mkdtempSync(join(base, 'ignored-cli-'));
  roots.push(dir);
  return dir;
}

function run(...args) {
  const result = spawnSync(binary, args, { encoding: 'utf8', cwd: here });
  if (result.error) throw new Error(`cannot run ${binary}: ${result.error.message}`);
  return { code: result.status, stdout: result.stdout, stderr: result.stderr };
}

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

function check(actual, expected, what, output) {
  if (Object.is(actual, expected)) return;
  throw new Error(
    `${what}\n  expected: ${JSON.stringify(expected)}\n  actual:   ${JSON.stringify(actual)}\n` +
      `  command printed:\n${indent(output)}`,
  );
}

/** Write one file, creating its parent directories; `name` is root-relative with `/` separators. */
function plant(root, name, contents) {
  const path = join(root, name);
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, contents);
}

function publishTree() {
  const root = scratch();
  plant(root, '.gitignore', 'build/\n');
  plant(root, '.git/info/exclude', 'cache/\n');
  plant(root, '.fs-meta/ignore', 'worktrees/w1/\n');
  plant(root, 'build/generated.txt', 'b');
  plant(root, 'cache/fetched.txt', 'c');
  plant(root, 'worktrees/w1/secret.txt', 's');
  plant(root, 'worktrees/w2/keep.txt', 'k');
  plant(root, 'top.txt', 't');
  return root;
}

describe('fsmeta ignored', () => {
  test('text mode names the source and the pruned directory', () => {
    const root = publishTree();
    const text = runOk('ignored', root);
    const lines = text.split('\n').filter(Boolean);
    check(lines.includes('gitignore build'), true, 'the .gitignore decision is a line', text);
    check(lines.includes('info/exclude cache'), true, 'the info/exclude decision is a line', text);
    check(lines.includes('fs-meta/ignore worktrees/w1'), true, 'the internal decision is a line', text);
    check(lines.includes('reserved .git'), true, 'a reserved directory is reported with no pattern source', text);
  });

  test('--json is an array of {path, source}', () => {
    const root = publishTree();
    const text = runOk('ignored', root, '--json');
    const entries = JSON.parse(text);
    if (!Array.isArray(entries)) throw new Error(`expected an array, got ${text}`);
    const byPath = new Map(entries.map((entry) => [entry.path, entry.source]));
    check(byPath.get('build'), 'gitignore', 'build was decided by .gitignore', text);
    check(byPath.get('cache'), 'info/exclude', 'cache was decided by info/exclude', text);
    check(byPath.get('worktrees/w1'), 'fs-meta/ignore', 'w1 was decided by .fs-meta/ignore', text);
  });

  test('refresh publishes the same exclusions and records the sources', () => {
    const root = publishTree();
    runOk('refresh', root);
    const txt = readFileSync(join(root, '.fs-meta', 'files.txt'), 'utf8').split('\n');
    for (const absent of ['build/generated.txt', 'cache/fetched.txt', 'worktrees/w1/secret.txt']) {
      check(txt.includes(`${absent}`), false, `${absent} is not in the trio`, txt.join('\n'));
    }
    check(txt.includes('worktrees/w2/keep.txt'), true, 'the unaffected sibling is in the trio', txt.join('\n'));

    const document = JSON.parse(readFileSync(join(root, '.fs-meta', 'files.json'), 'utf8'));
    check(
      JSON.stringify(document.scan.ignoreSources),
      JSON.stringify(['gitignore', 'info/exclude', 'fs-meta/ignore']),
      'scan.ignoreSources records the sources in precedence order',
      JSON.stringify(document.scan),
    );
  });
});
