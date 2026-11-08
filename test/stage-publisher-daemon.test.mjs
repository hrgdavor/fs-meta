#!/usr/bin/env bun
// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//
// End-to-end: a real `fsmeta daemon`, a real stage-0 builder, and the scp-like publisher. The fake-server test
// proves the publisher's frame handling; this one proves the daemon's live stage path and the publisher agree.
import { afterAll, expect, test } from 'bun:test';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createConnection } from 'node:net';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { binary } from './binary.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const children = [];
const scratchDirs = [];

afterAll(() => {
  for (const child of children) {
    try { child.kill('SIGKILL'); } catch {}
  }
  for (const dir of scratchDirs) rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
});

function scratch(prefix) {
  const base = join(here, '..', '.tmp');
  mkdirSync(base, { recursive: true });
  const dir = mkdtempSync(join(base, prefix));
  scratchDirs.push(dir);
  return dir;
}

function envFor(home) {
  return {
    ...process.env,
    FSMETA_RUNTIME_DIR: join(home, 'run'),
    FSMETA_CONFIG_HOME: join(home, 'config'),
  };
}

function cli(env, args, allowFailure = false) {
  const result = Bun.spawnSync([binary, ...args], { cwd: here, env, stdout: 'pipe', stderr: 'pipe' });
  if (!allowFailure && result.exitCode !== 0) {
    throw new Error(`fsmeta ${args.join(' ')} failed (${result.exitCode}): ${result.stderr.toString()}`);
  }
  return result;
}

async function waitFor(predicate, message, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    try {
      if (await predicate()) return;
    } catch (error) {
      last = error;
    }
    await Bun.sleep(50);
  }
  throw new Error(`${message}${last ? `: ${last.message}` : ''}`);
}

function frame(kind, payload) {
  const header = Buffer.alloc(8);
  header.writeUInt16LE(kind, 0);
  header.writeUInt16LE(0, 2);
  header.writeUInt32LE(payload.length, 4);
  return Buffer.concat([header, payload]);
}

function hello() {
  const payload = Buffer.alloc(24);
  payload.writeUInt16LE(0x0105, 0);
  payload.writeUInt16LE(64, 2);
  payload.writeUInt8(1, 5);
  payload.writeBigUInt64LE(0n, 8);
  payload.writeBigUInt64LE(1n << 20n, 16);
  return frame(0x01, payload);
}

function subscribeV3({ fromBatch = 0n, fromStageBatch = 0n, stage = 0, builder = true } = {}) {
  const payload = Buffer.alloc(22);
  payload.writeBigUInt64LE(fromBatch, 0);
  payload.writeBigUInt64LE(fromStageBatch, 8);
  payload.writeUInt16LE(stage, 16);
  payload.writeUInt16LE(builder ? 1 : 0, 18);
  payload.writeUInt16LE(0, 20); // include_count
  // exclude_count is the final two bytes; the buffer is already zeroed.
  return frame(0x12, Buffer.concat([payload, Buffer.alloc(2)]));
}

function buildStarted(generation) {
  const payload = Buffer.alloc(8);
  payload.writeBigUInt64LE(BigInt(generation), 0);
  return frame(0x0c, payload);
}

function buildDone(generation) {
  const payload = Buffer.alloc(9);
  payload.writeBigUInt64LE(BigInt(generation), 0);
  payload.writeUInt8(0, 8);
  return frame(0x0d, payload);
}

/** A tiny frame queue over one socket. */
function frameReader(socket) {
  let buffer = Buffer.alloc(0);
  const queue = [];
  const waiters = [];
  let closed = false;
  socket.on('data', (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length >= 8) {
      const length = buffer.readUInt32LE(4);
      if (buffer.length < 8 + length) return;
      const kind = buffer.readUInt16LE(0);
      const payload = buffer.subarray(8, 8 + length);
      buffer = buffer.subarray(8 + length);
      queue.push({ kind, payload });
      while (waiters.length > 0 && queue.length > 0) waiters.shift()(queue.shift());
    }
  });
  socket.on('close', () => {
    closed = true;
    while (waiters.length > 0) waiters.shift()(null);
  });
  return {
    next(timeoutMs = 5000) {
      if (queue.length > 0) return Promise.resolve(queue.shift());
      if (closed) return Promise.resolve(null);
      return Promise.race([
        new Promise((resolve) => waiters.push(resolve)),
        Bun.sleep(timeoutMs).then(() => null),
      ]);
    },
  };
}

test('the real daemon streams a stage batch to the publisher, which copies and hooks', async () => {
  const home = scratch('stage-publisher-daemon-');
  const root = join(home, 'tree');
  const dest = join(home, 'deploy');
  const runtime = join(home, 'run');
  const config = join(home, 'config');
  mkdirSync(join(root, 'src'), { recursive: true });
  mkdirSync(join(root, 'build', 'classes'), { recursive: true });
  mkdirSync(join(root, '.fs-meta'), { recursive: true });
  mkdirSync(dest, { recursive: true });
  mkdirSync(runtime, { recursive: true });
  mkdirSync(config, { recursive: true });
  writeFileSync(join(root, 'src', 'main.zig'), 'const x = 1;\n');
  writeFileSync(join(root, 'build', 'classes', 'A.class'), 'AAA');
  writeFileSync(join(root, '.fs-meta', 'build.json'), JSON.stringify({
    version: 1,
    stages: [{ stage: 0, folders: ['build/classes'] }],
  }));
  const env = envFor(home);
  const marker = join(home, 'hook-ran');
  const hook = join(home, 'hook.mjs');
  writeFileSync(hook, `import { writeFileSync } from 'node:fs';\nwriteFileSync(${JSON.stringify(marker)}, 'ok');\n`);

  const daemon = Bun.spawn([binary, 'daemon', 'start', '--foreground', '--base', runtime], {
    cwd: here,
    env,
    stdout: 'pipe',
    stderr: 'pipe',
  });
  children.push(daemon);
  try {
    await waitFor(() => cli(env, ['daemon', 'status'], true).exitCode === 0, 'daemon did not start');
    // A deliberately slow scheduler tick: the stage scan is triggered by BUILD_DONE, not by the root tick or the
    // 25 ms quiet period, so the publisher must still see the batch quickly.
    const added = cli(env, ['root', 'add', root, '--mode', 'always', '--tick', '1000']);
    const id = added.stdout.toString().match(/added ([0-9a-f]{8})/)?.[1];
    expect(id).toBeTruthy();
    const socket = join(runtime, 'roots', `${id}.sock`);
    await waitFor(() => existsSync(socket), 'root socket did not appear');

    // The publisher subscribes first, at stage 1 (the consumer of stage 0).
    const publisher = Bun.spawn([
      process.execPath,
      join(here, '..', 'examples', 'stage-publisher', 'publisher.mjs'),
      '--socket', socket,
      '--root', root,
      '--dest', dest,
      '--stage', '1',
      '--from-stage-batch', '0',
      '--once',
      '--after-batch', `${process.execPath} ${hook}`,
    ], { cwd: here, stdout: 'ignore', stderr: 'pipe' });
    children.push(publisher);
    await Bun.sleep(250);

    // A stage-0 builder joins at generation 0, applies the initial batch, and acknowledges it.
    const client = createConnection({ path: socket });
    await new Promise((resolve, reject) => {
      client.once('connect', resolve);
      client.once('error', reject);
    });
    const reader = frameReader(client);
    client.write(hello());
    const serverHello = await reader.next();
    expect(serverHello?.kind).toBe(0x01);
    client.write(subscribeV3({ fromBatch: 0n, stage: 0, builder: true }));

    let acknowledged = false;
    const deadline = Date.now() + 10000;
    while (Date.now() < deadline) {
      const frame = await reader.next(1000);
      if (!frame) break;
      if (frame.kind === 0x04 && frame.payload.readBigUInt64LE(0) === 1n) {
        client.write(buildStarted(1));
        const acknowledgedAt = Date.now();
        client.write(buildDone(1));
        acknowledged = true;
        await waitFor(() => existsSync(marker), 'publisher hook did not run', 10000);
        expect(Date.now() - acknowledgedAt).toBeLessThan(900);
        break;
      }
    }
    expect(acknowledged).toBe(true);
    client.end();

    expect(readFileSync(join(dest, 'build', 'classes', 'A.class'), 'utf8')).toBe('AAA');
    expect(readFileSync(marker, 'utf8')).toBe('ok');
  } finally {
    daemon.kill('SIGKILL');
    await Promise.race([daemon.exited, Bun.sleep(1000)]);
  }
}, 30000);
