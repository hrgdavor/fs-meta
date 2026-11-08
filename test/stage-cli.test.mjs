#!/usr/bin/env bun
// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//
// The stage CLI against a real binary: the declaration, the stage state, the one-shot diff/scan path, and the
// root walk's `stage` exclusion. The daemon path has its own socket tests.
import { afterAll, describe, expect, test } from 'bun:test';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { binary } from './binary.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const scratchDirs = [];

afterAll(() => {
  for (const dir of scratchDirs) rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
});

function scratch(prefix) {
  const base = join(here, '..', '.tmp');
  mkdirSync(base, { recursive: true });
  const dir = mkdtempSync(join(base, prefix));
  scratchDirs.push(dir);
  return dir;
}

function run(root, ...args) {
  return execFileSync(binary, [...args, root], { encoding: 'utf8', cwd: here });
}

function writeTree() {
  const root = scratch('stage-cli-');
  mkdirSync(join(root, 'build', 'classes'), { recursive: true });
  mkdirSync(join(root, 'src'), { recursive: true });
  mkdirSync(join(root, '.fs-meta'), { recursive: true });
  writeFileSync(join(root, 'build', 'classes', 'A.class'), 'AAA');
  writeFileSync(join(root, 'src', 'main.zig'), 'source\n');
  writeFileSync(
    join(root, '.fs-meta', 'build.json'),
    JSON.stringify({ version: 1, stages: [{ stage: 0, folders: ['build/classes'] }] }),
  );
  return root;
}

describe('fsmeta stage', () => {
  test('status, scan and diff use the stage state, and the root walk hides the stage folder', () => {
    if (!existsSync(binary)) throw new Error(`build the engine first: ${binary}`);
    const root = writeTree();

    const status = JSON.parse(run(root, 'stage', 'status', '--json'));
    expect(status).toEqual([{ stage: 0, folders: ['build/classes'], hash: 'text', generation: 0 }]);

    const scanned = JSON.parse(run(root, 'stage', 'scan', '--json', '--stage', '0'));
    expect(scanned.some((change) => change.name === 'build/classes/A.class')).toBe(true);
    const statePath = join(root, '.fs-meta', 'stages', '00', 'files.json');
    const state = JSON.parse(readFileSync(statePath, 'utf8'));
    expect(state.stage.stage).toBe(0);
    expect(state.stage.folders).toEqual(['build/classes']);

    // A second scan has no changes, and `diff` is the same pass without a write.
    expect(JSON.parse(run(root, 'stage', 'scan', '--json', '--stage', '0'))).toEqual([]);
    expect(JSON.parse(run(root, 'stage', 'diff', '--json', '--stage', '0'))).toEqual([]);

    writeFileSync(join(root, 'build', 'classes', 'A.class'), 'AAB');
    const diff = JSON.parse(run(root, 'stage', 'diff', '--json', '--stage', '0'));
    expect(diff).toEqual([
      expect.objectContaining({ change: 'changed', name: 'build/classes/A.class' }),
    ]);

    // The root trio must never describe the declared folder, even though it is not gitignored.
    run(root, 'refresh');
    const scan = JSON.parse(run(root, 'scan', '--json'));
    expect(scan.names.some((entry) => entry.name.startsWith('build/classes'))).toBe(false);
    expect(scan.names.some((entry) => entry.name === 'src/main.zig')).toBe(true);
  });
});
