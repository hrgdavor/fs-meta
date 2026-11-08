#!/usr/bin/env bun
// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//
// The scp-like example against a fake stage server: copy starts before STAGE_BATCH_END, the post-batch hook runs
// after it, and a successful batch is the only thing that can trigger the hook.
import { afterAll, describe, expect, test } from 'bun:test';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync } from 'node:fs';
import { createServer } from 'node:net';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const publisher = join(here, '..', 'examples', 'stage-publisher', 'publisher.mjs');
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

const KIND = {
  HELLO: 0x01,
  ERROR: 0x05,
  SUBSCRIBE_V3: 0x12,
  STAGE_BATCH_START: 0x0f,
  STAGE_CHANGE_ENTRY: 0x10,
  STAGE_BATCH_END: 0x11,
};

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
  payload.writeUInt8(1, 5); // server
  payload.writeBigUInt64LE(0n, 8);
  payload.writeBigUInt64LE(1n << 20n, 16);
  return frame(KIND.HELLO, payload);
}

function stageStart(stage, generation) {
  const payload = Buffer.alloc(26);
  payload.writeUInt16LE(stage, 0);
  payload.writeBigUInt64LE(BigInt(generation), 2);
  payload.writeBigUInt64LE(BigInt(generation - 1), 10);
  return frame(KIND.STAGE_BATCH_START, payload);
}

function stageEntry(name, change = 0x20) {
  const entry = Buffer.alloc(64);
  entry.writeUInt32LE(64, 40);
  entry.writeUInt32LE(0x02 | 0x01 | change, 44); // regular file, content known, added
  entry.writeBigUInt64LE(0x1234n, 16); // content hash, informational for this client
  return frame(KIND.STAGE_CHANGE_ENTRY, Buffer.concat([entry, Buffer.from(name)]));
}

function stageEnd(stage, generation, added = 1) {
  const payload = Buffer.alloc(43);
  payload.writeUInt16LE(stage, 0);
  payload.writeBigUInt64LE(BigInt(generation), 2);
  payload.writeBigUInt64LE(BigInt(added), 10);
  payload.writeBigUInt64LE(0n, 18);
  payload.writeBigUInt64LE(0n, 26);
  payload.writeUInt8(0, 42);
  return frame(KIND.STAGE_BATCH_END, payload);
}

function waitFor(predicate, timeoutMs = 10000) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + timeoutMs;
    const tick = () => {
      try {
        if (predicate()) return resolve();
      } catch {}
      if (Date.now() > deadline) return reject(new Error('timed out'));
      setTimeout(tick, 25);
    };
    tick();
  });
}

describe('stage publisher example', () => {
  test('copies during the batch and runs the hook only after STAGE_BATCH_END', async () => {
    const root = scratch('stage-publisher-');
    const source = join(root, 'source');
    const dest = join(root, 'dest');
    const socket = join(root, 'stage.sock');
    mkdirSync(join(source, 'build', 'classes'), { recursive: true });
    mkdirSync(dest, { recursive: true });
    writeFileSync(join(source, 'build', 'classes', 'A.class'), 'AAA');

    const hook = join(root, 'hook.mjs');
    const marker = join(root, 'hook-ran');
    writeFileSync(hook, `import { writeFileSync } from 'node:fs';\nwriteFileSync(${JSON.stringify(marker)}, 'ok');\n`);

    let peer = null;
    let subscribed;
    const subscribedPromise = new Promise((resolve) => { subscribed = resolve; });
    const server = createServer((connection) => {
      peer = connection;
      connection.write(hello());
      let buffered = Buffer.alloc(0);
      connection.on('data', (chunk) => {
        buffered = Buffer.concat([buffered, chunk]);
        while (buffered.length >= 8) {
          const length = buffered.readUInt32LE(4);
          if (buffered.length < 8 + length) return;
          const kind = buffered.readUInt16LE(0);
          buffered = buffered.subarray(8 + length);
          if (kind === KIND.SUBSCRIBE_V3) subscribed();
        }
      });
    });
    await new Promise((resolve) => server.listen(socket, resolve));
    scratchDirs.push(root);

    const child = Bun.spawn([
      process.execPath,
      publisher,
      '--socket', socket,
      '--root', source,
      '--dest', dest,
      '--stage', '1',
      '--include', 'build/classes/**',
      '--after-batch', `${process.execPath} ${hook}`,
    ], { stdout: 'ignore', stderr: 'inherit' });

    try {
      await subscribedPromise;
      // `peer` is set by the connection callback; `subscribed` fires once the client's SUBSCRIBE_V3 is read.
      peer.write(stageStart(0, 1));
      peer.write(stageEntry('build/classes/A.class'));
      // The copy must be visible while the batch is still open, before the end frame exists.
      await waitFor(() => existsSync(join(dest, 'build', 'classes', 'A.class')));
      expect(existsSync(marker)).toBe(false);
      peer.write(stageEnd(0, 1, 1));
      await waitFor(() => existsSync(marker));
      expect(readFileSync(marker, 'utf8')).toBe('ok');
      expect(readFileSync(join(dest, 'build', 'classes', 'A.class'), 'utf8')).toBe('AAA');
    } finally {
      child.kill('SIGKILL');
      await Promise.race([child.exited, Bun.sleep(1000)]);
      server.close();
    }
  }, 20000);

  test('a connection dropped mid-batch exits non-zero and runs no hook', async () => {
    const root = scratch('stage-publisher-drop-');
    const source = join(root, 'source');
    const dest = join(root, 'dest');
    const socket = join(root, 'stage.sock');
    mkdirSync(join(source, 'build', 'classes'), { recursive: true });
    mkdirSync(dest, { recursive: true });
    writeFileSync(join(source, 'build', 'classes', 'A.class'), 'AAA');
    const hook = join(root, 'hook.mjs');
    const marker = join(root, 'hook-ran');
    writeFileSync(hook, `import { writeFileSync } from 'node:fs';\nwriteFileSync(${JSON.stringify(marker)}, 'ok');\n`);

    let peer = null;
    let subscribed;
    const subscribedPromise = new Promise((resolve) => { subscribed = resolve; });
    const server = createServer((connection) => {
      peer = connection;
      connection.write(hello());
      let buffered = Buffer.alloc(0);
      connection.on('data', (chunk) => {
        buffered = Buffer.concat([buffered, chunk]);
        while (buffered.length >= 8) {
          const length = buffered.readUInt32LE(4);
          if (buffered.length < 8 + length) return;
          const kind = buffered.readUInt16LE(0);
          buffered = buffered.subarray(8 + length);
          if (kind === KIND.SUBSCRIBE_V3) subscribed();
        }
      });
    });
    await new Promise((resolve) => server.listen(socket, resolve));
    scratchDirs.push(root);

    const child = Bun.spawn([
      process.execPath, publisher,
      '--socket', socket,
      '--root', source,
      '--dest', dest,
      '--stage', '1',
      '--after-batch', `${process.execPath} ${hook}`,
    ], { stdout: 'ignore', stderr: 'ignore' });
    try {
      await subscribedPromise;
      peer.write(stageStart(0, 1));
      peer.write(stageEntry('build/classes/A.class'));
      peer.destroy();
      const code = await Promise.race([child.exited, Bun.sleep(5000).then(() => 'timeout')]);
      expect(code).not.toBe(0);
      expect(existsSync(marker)).toBe(false);
    } finally {
      child.kill('SIGKILL');
      server.close();
    }
  }, 20000);
});
