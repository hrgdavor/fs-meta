#!/usr/bin/env bun
// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//
// The daemon client's tests. The server is fake and speaks the documented frames;
// the trio in the bootstrap test is real, written by `publish`, so the baseline +
// replay path is exercised end to end rather than with a hand-built map.
//
//   bun test js/daemon.test.mjs

import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, test } from 'node:test';

import {
  CHANGE_ADDED,
  CHANGE_CHANGED,
  CHANGE_DELETED,
  KIND,
  canonicalPath,
  findRootForPath,
  frame,
  helloPayload,
  namesForRoot,
  parseEntry,
  queryNames,
  readRoots,
  replayNames,
  rootsConfigPath,
  subscribePayload,
  subscribeV2Payload,
  subscribeV3Payload,
  buildStartedPayload,
  buildDonePayload,
  parseStageBatchStart,
  parseStageBatchEnd,
  StageClient,
} from './daemon.mjs';
import { publish, scanTree } from './fsmeta.mjs';

const temporary = [];
function tempDir(prefix = 'fsmeta-daemon-') {
  const directory = mkdtempSync(join(tmpdir(), prefix));
  temporary.push(directory);
  return directory;
}
process.on('exit', () => {
  for (const directory of temporary) rmSync(directory, { recursive: true, force: true });
});

/** A transport path: named pipe on Windows, Unix socket elsewhere. */
function socketPath(name) {
  if (process.platform === 'win32') return `\\\\.\\pipe\\${name}-${process.pid}-${Date.now()}`;
  return join(tempDir('fsmeta-daemon-socket-'), `${name}.sock`);
}

/** The 64-byte entry a fake daemon sends. */
function entryBytes(name, flags) {
  const nameBytes = Buffer.from(name, 'utf8');
  const buffer = Buffer.alloc(64 + nameBytes.length);
  buffer.writeUInt32LE(nameBytes.length, 40);
  buffer.writeUInt32LE(flags, 44);
  nameBytes.copy(buffer, 64);
  return buffer;
}

function startBatch(number, parent) {
  const payload = Buffer.alloc(24);
  payload.writeBigUInt64LE(BigInt(number), 0);
  payload.writeBigUInt64LE(BigInt(parent), 8);
  payload.writeBigUInt64LE(0n, 16);
  return payload;
}

function endBatch(number, added, changed, deleted) {
  const payload = Buffer.alloc(40);
  payload.writeBigUInt64LE(BigInt(number), 0);
  payload.writeBigUInt64LE(BigInt(added), 8);
  payload.writeBigUInt64LE(BigInt(changed), 16);
  payload.writeBigUInt64LE(BigInt(deleted), 24);
  payload.writeBigUInt64LE(0n, 32);
  return payload;
}

function errorFrame(code, detail) {
  const message = Buffer.from(detail, 'utf8');
  const payload = Buffer.alloc(2 + message.length);
  payload.writeUInt16LE(code, 0);
  message.copy(payload, 2);
  return frame(KIND.ERROR, payload);
}

/** The include patterns of a SUBSCRIBE payload. */
function includePatterns(payload) {
  const count = payload.readUInt16LE(8);
  const patterns = [];
  let position = 10;
  for (let index = 0; index < count; index += 1) {
    const length = payload.readUInt16LE(position);
    position += 2;
    patterns.push(payload.subarray(position, position + length).toString('utf8'));
    position += length;
  }
  return patterns;
}

/**
 * A fake daemon. `onSubscribe(socket, payload)` runs after the client's
 * SUBSCRIBE; `generation` is the head named in the HELLO.
 */
async function fakeDaemon({ generation = 0n, onSubscribe }) {
  const path = socketPath('daemon');
  const subscribes = [];
  const control = [];
  const server = createServer((socket) => {
    let buffered = Buffer.alloc(0);
    let greeted = false;
    socket.on('data', (chunk) => {
      buffered = Buffer.concat([buffered, chunk]);
      while (buffered.length >= 8) {
        const kind = buffered.readUInt16LE(0);
        const length = buffered.readUInt32LE(4);
        if (buffered.length < 8 + length) return;
        const payload = buffered.subarray(8, 8 + length);
        buffered = buffered.subarray(8 + length);

        if (kind === KIND.HELLO && !greeted) {
          greeted = true;
          socket.write(frame(KIND.HELLO, helloPayload({ role: 0, generation })));
        } else if (kind === KIND.SUBSCRIBE) {
          subscribes.push(payload);
          onSubscribe(socket, payload);
        } else if (kind === KIND.SUBSCRIBE_V3) {
          subscribes.push(payload);
          onSubscribe(socket, payload, kind);
        } else if (kind === KIND.BUILD_STARTED || kind === KIND.BUILD_DONE) {
          control.push({ kind, payload });
        }
      }
    });
    socket.on('error', () => {});
  });

  await new Promise((resolveListener, reject) => {
    server.once('error', reject);
    server.listen(path, resolveListener);
  });

  return {
    path,
    subscribes,
    control,
    close: () => new Promise((resolveListener) => server.close(resolveListener)),
  };
}

/** A small project with a real trio at generation 1. */
function publishedRoot() {
  const root = tempDir('fsmeta-daemon-root-');
  mkdirSync(join(root, '.git'));
  mkdirSync(join(root, 'docs'));
  writeFileSync(join(root, 'README.md'), '# readme\n');
  writeFileSync(join(root, 'docs', 'guide.md'), '# guide\n');
  writeFileSync(join(root, 'notes.txt'), 'not markdown\n');
  publish(join(root, '.fs-meta'), scanTree(root));
  return root;
}

function rootsDocument(root, socket) {
  return JSON.stringify({
    version: 1,
    roots: [{ id: 'a1b2c3d4', root: canonicalPath(root), socket, mode: 'auto', idle_timeout_ms: 300000 }],
  });
}

function configFor(root, socket) {
  const configPath = join(tempDir('fsmeta-daemon-config-'), 'roots.json');
  writeFileSync(configPath, rootsDocument(root, socket));
  return configPath;
}

describe('roots.json', () => {
  test('the config path follows FSMETA_CONFIG_HOME, then XDG_CONFIG_HOME', () => {
    assert.equal(rootsConfigPath({ FSMETA_CONFIG_HOME: 'C:\\cfg', XDG_CONFIG_HOME: 'C:\\xdg' }),
      join('C:\\cfg', 'fsmeta', 'roots.json'));
    assert.equal(rootsConfigPath({ XDG_CONFIG_HOME: '/xdg' }), join('/xdg', 'fsmeta', 'roots.json'));
  });

  test('a missing or malformed document is null, not an error', () => {
    const directory = tempDir();
    assert.equal(readRoots(join(directory, 'missing.json')), null);
    writeFileSync(join(directory, 'bad.json'), '{nope', 'utf8');
    assert.equal(readRoots(join(directory, 'bad.json')), null);
    writeFileSync(join(directory, 'no-roots.json'), JSON.stringify({ version: 1 }), 'utf8');
    assert.equal(readRoots(join(directory, 'no-roots.json')), null);
  });

  test('the longest served root containing the directory wins', () => {
    const parent = tempDir();
    const child = join(parent, 'packages', 'app');
    const other = join(parent, 'other');
    mkdirSync(child, { recursive: true });
    mkdirSync(other, { recursive: true });
    const document = {
      roots: [
        { root: parent, socket: join(parent, 'parent.sock') },
        { root: child, socket: join(child, 'child.sock') },
        { root: other, socket: join(other, 'other.sock') },
      ],
    };
    assert.equal(findRootForPath(child, { document }).socket, join(child, 'child.sock'));
    assert.equal(findRootForPath(join(parent, 'other', 'deep'), { document }).socket, join(other, 'other.sock'));
    assert.equal(findRootForPath(tempDir(), { document }), null);
  });
});

describe('frames', () => {
  test('SUBSCRIBE carries from_batch and the include/exclude patterns', () => {
    const payload = subscribePayload({ fromBatch: 7n, include: ['*.[mM][dD]'], exclude: ['draft.md'] });
    assert.equal(payload.readBigUInt64LE(0), 7n);
    assert.equal(payload.readUInt16LE(8), 1);
    assert.equal(payload.readUInt16LE(10), 10);
    assert.equal(payload.subarray(12, 22).toString('utf8'), '*.[mM][dD]');
    assert.equal(payload.readUInt16LE(22), 1);
    assert.equal(payload.readUInt16LE(24), 8);
    assert.equal(payload.subarray(26, 34).toString('utf8'), 'draft.md');
  });

  test('SUBSCRIBE_V3 carries the stage cursor and BUILD_* payloads round-trip', () => {
    const payload = subscribeV3Payload({
      fromBatch: 9n,
      fromStageBatch: 4n,
      stage: 2,
      builder: true,
      include: ['*.jar'],
      exclude: [],
    });
    assert.equal(payload.readBigUInt64LE(0), 9n);
    assert.equal(payload.readBigUInt64LE(8), 4n);
    assert.equal(payload.readUInt16LE(16), 2);
    assert.equal(payload.readUInt16LE(18), 1);
    assert.equal(payload.readUInt16LE(20), 1);
    assert.equal(payload.readUInt16LE(22), 5);
    assert.equal(payload.subarray(24, 29).toString('utf8'), '*.jar');

    const v2 = subscribeV2Payload({ fromBatch: 8n, stage: 2, builder: false, include: [], exclude: [] });
    assert.equal(v2.readBigUInt64LE(0), 8n);
    assert.equal(v2.readUInt16LE(8), 2);
    assert.equal(v2.readUInt16LE(10), 0);
    assert.equal(v2.readUInt16LE(12), 0);

    assert.equal(buildStartedPayload(9n).readBigUInt64LE(0), 9n);
    const done = buildDonePayload(9n, 1);
    assert.equal(done.readBigUInt64LE(0), 9n);
    assert.equal(done.readUInt8(8), 1);

    const start = Buffer.alloc(26);
    start.writeUInt16LE(1, 0);
    start.writeBigUInt64LE(4n, 2);
    start.writeBigUInt64LE(3n, 10);
    start.writeBigUInt64LE(99n, 18);
    assert.deepEqual(parseStageBatchStart(start), { stage: 1, generation: 4n, parent: 3n, startedNs: 99n });

    const end = Buffer.alloc(43);
    end.writeUInt16LE(1, 0);
    end.writeBigUInt64LE(4n, 2);
    end.writeBigUInt64LE(2n, 10);
    end.writeBigUInt64LE(1n, 18);
    end.writeBigUInt64LE(0n, 26);
    end.writeUInt8(0, 42);
    assert.equal(parseStageBatchEnd(end).added, 2n);
    assert.equal(parseStageBatchEnd(end).status, 0);
  });

  test('StageClient consumes STAGE_READY and the stage batch, and sends BUILD_*', async () => {
    const daemon = await fakeDaemon({
      generation: 4n,
      onSubscribe(socket, payload, kind) {
        assert.equal(kind, KIND.SUBSCRIBE_V3);
        assert.equal(payload.readBigUInt64LE(0), 3n);
        assert.equal(payload.readBigUInt64LE(8), 2n);
        assert.equal(payload.readUInt16LE(16), 1);
        assert.equal(payload.readUInt16LE(18), 1); // builder
        const ready = Buffer.alloc(18);
        ready.writeUInt16LE(1, 0);
        ready.writeBigUInt64LE(4n, 2);
        ready.writeBigUInt64LE(3n, 10);
        socket.write(frame(KIND.STAGE_READY, ready));
        const start = Buffer.alloc(26);
        start.writeUInt16LE(1, 0);
        start.writeBigUInt64LE(2n, 2);
        start.writeBigUInt64LE(1n, 10);
        socket.write(frame(KIND.STAGE_BATCH_START, start));
        socket.write(frame(KIND.STAGE_CHANGE_ENTRY, entryBytes('build/classes/A.class', CHANGE_ADDED | 0x02)));
        const end = Buffer.alloc(43);
        end.writeUInt16LE(1, 0);
        end.writeBigUInt64LE(2n, 2);
        end.writeBigUInt64LE(1n, 10);
        socket.write(frame(KIND.STAGE_BATCH_END, end));
      },
    });
    const client = await StageClient.connect(daemon.path, {
      stage: 1,
      builder: true,
      fromBatch: 3n,
      fromStageBatch: 2n,
    });
    try {
      assert.deepEqual(await client.nextEvent(1000), {
        type: 'stage_ready',
        stage: 1,
        headBatch: 4n,
        releasedThrough: 3n,
      });
      assert.deepEqual(await client.nextEvent(1000), {
        type: 'stage_batch_start',
        stage: 1,
        generation: 2n,
        parent: 1n,
        startedNs: 0n,
      });
      assert.deepEqual(await client.nextEvent(1000), {
        type: 'stage_change',
        stage: 1,
        name: 'build/classes/A.class',
        flags: CHANGE_ADDED | 0x02,
      });
      const end = await client.nextEvent(1000);
      assert.equal(end.type, 'stage_batch_end');
      assert.equal(end.generation, 2n);
      assert.equal(end.added, 1n);
      client.sendBuildStarted(2n);
      client.sendBuildDone(2n, 0);
      await new Promise(resolve => setTimeout(resolve, 20));
      assert.equal(daemon.control.length, 2);
      assert.equal(daemon.control[0].kind, KIND.BUILD_STARTED);
      assert.equal(daemon.control[1].kind, KIND.BUILD_DONE);
    } finally {
      client.close();
      await daemon.close();
    }
  });

  test('parseEntry reads flags and name, and rejects a short payload', () => {
    assert.deepEqual(parseEntry(entryBytes('docs/a.md', CHANGE_CHANGED | 0x02)), {
      name: 'docs/a.md',
      flags: CHANGE_CHANGED | 0x02,
    });
    assert.throws(() => parseEntry(Buffer.alloc(10)), /short CHANGE_ENTRY/);
  });
});

describe('replayNames', () => {
  test('collects additions, changes and deletions across replay batches', async () => {
    const daemon = await fakeDaemon({
      generation: 3n,
      onSubscribe(socket) {
        socket.write(frame(KIND.START_BATCH, startBatch(1, 0)));
        socket.write(frame(KIND.CHANGE_ENTRY, entryBytes('a.md', CHANGE_ADDED | 0x02)));
        socket.write(frame(KIND.CHANGE_ENTRY, entryBytes('dir/', CHANGE_ADDED | 0x04)));
        socket.write(frame(KIND.END_BATCH, endBatch(1, 2, 0, 0)));

        socket.write(frame(KIND.START_BATCH, startBatch(2, 1)));
        socket.write(frame(KIND.CHANGE_ENTRY, entryBytes('b.md', CHANGE_ADDED | 0x02)));
        socket.write(frame(KIND.END_BATCH, endBatch(2, 1, 0, 0)));

        socket.write(frame(KIND.START_BATCH, startBatch(3, 2)));
        socket.write(frame(KIND.CHANGE_ENTRY, entryBytes('a.md', CHANGE_CHANGED | 0x02)));
        socket.write(frame(KIND.CHANGE_ENTRY, entryBytes('b.md', CHANGE_DELETED | 0x02)));
        socket.write(frame(KIND.END_BATCH, endBatch(3, 0, 1, 1)));
      },
    });

    try {
      const result = await replayNames(daemon.path, { timeoutMs: 5000 });
      assert.deepEqual([...result.names.keys()].sort(), ['a.md']);
      assert.equal(result.head, 3n);
      assert.equal(daemon.subscribes.length, 1);
      assert.equal(daemon.subscribes[0].readBigUInt64LE(0), 0n);
    } finally {
      await daemon.close();
    }
  });

  test('a baseline plus a replay applies only the batches after its generation', async () => {
    const baseline = new Map([['old.md', 0x02], ['gone.md', 0x02]]);
    const daemon = await fakeDaemon({
      generation: 2n,
      onSubscribe(socket) {
        socket.write(frame(KIND.START_BATCH, startBatch(2, 1)));
        socket.write(frame(KIND.CHANGE_ENTRY, entryBytes('new.md', CHANGE_ADDED | 0x02)));
        socket.write(frame(KIND.CHANGE_ENTRY, entryBytes('gone.md', CHANGE_DELETED | 0x02)));
        socket.write(frame(KIND.END_BATCH, endBatch(2, 1, 0, 1)));
      },
    });

    try {
      const result = await replayNames(daemon.path, { fromBatch: 1n, baseline, timeoutMs: 5000 });
      assert.deepEqual([...result.names.keys()].sort(), ['new.md', 'old.md']);
      assert.equal(daemon.subscribes[0].readBigUInt64LE(0), 1n);
    } finally {
      await daemon.close();
    }
  });

  test('no retained batch resolves immediately, and an ERROR carries its word', async () => {
    const empty = await fakeDaemon({ generation: 0n, onSubscribe() {} });
    try {
      assert.deepEqual(await queryNames(empty.path, { timeoutMs: 5000 }), []);
    } finally {
      await empty.close();
    }

    const refused = await fakeDaemon({
      generation: 9n,
      onSubscribe(socket) {
        socket.write(errorFrame(2, 'batch-too-old: batches start at 7'));
      },
    });
    try {
      await assert.rejects(replayNames(refused.path, { timeoutMs: 5000 }), (error) => {
        assert.equal(error.code, 'batch-too-old');
        assert.equal(error.reachable, true);
        return true;
      });
    } finally {
      await refused.close();
    }
  });

  test('an unreachable socket rejects with reachable false', async () => {
    await assert.rejects(replayNames(socketPath('missing'), { timeoutMs: 1000 }), (error) => {
      assert.equal(error.reachable, false);
      return true;
    });
  });
});

describe('namesForRoot', () => {
  test('bootstraps from the trio, then applies the replay after its generation', async () => {
    const root = publishedRoot();
    const daemon = await fakeDaemon({
      generation: 2n,
      onSubscribe(socket, payload) {
        // The trio is generation 1, so the client must ask for batches after 1
        // rather than replaying from 0.
        if (payload.readBigUInt64LE(0) === 1n) {
          socket.write(frame(KIND.START_BATCH, startBatch(2, 1)));
          socket.write(frame(KIND.CHANGE_ENTRY, entryBytes('NEW.md', CHANGE_ADDED | 0x02)));
          socket.write(frame(KIND.CHANGE_ENTRY, entryBytes('docs/guide.md', CHANGE_DELETED | 0x02)));
          socket.write(frame(KIND.END_BATCH, endBatch(2, 1, 0, 1)));
        } else {
          socket.write(errorFrame(2, 'batch-too-old: the baseline was not used'));
        }
      },
    });

    try {
      const configPath = configFor(root, daemon.path);
      const result = await namesForRoot(root, { configPath, include: ['*.md'] });
      assert.ok(result);
      assert.equal(result.source, 'trio+replay');
      assert.equal(result.generation, 2n);
      assert.deepEqual(result.names, ['NEW.md', 'README.md']);
      assert.equal(daemon.subscribes[0].readBigUInt64LE(0), 1n);
      assert.deepEqual(includePatterns(daemon.subscribes[0]), ['*.md']);

      // Exclude wins over include, and the trio baseline is filtered too.
      const excluded = await namesForRoot(root, { configPath, include: ['*.md'], exclude: ['NEW.md'] });
      assert.deepEqual(excluded.names, ['README.md']);
    } finally {
      await daemon.close();
    }
  });

  test('a trio-only answer is returned when the daemon head equals its generation', async () => {
    const root = publishedRoot();
    const daemon = await fakeDaemon({ generation: 1n, onSubscribe() {} });
    try {
      const configPath = configFor(root, daemon.path);
      const result = await namesForRoot(root, { configPath });
      assert.equal(result.source, 'trio');
      assert.deepEqual(result.names, ['README.md', 'docs/guide.md', 'notes.txt']);
    } finally {
      await daemon.close();
    }
  });

  test('without a trio the replay starts at 0, and an old window is a null answer', async () => {
    const root = tempDir();
    mkdirSync(join(root, '.git'));

    const replayed = await fakeDaemon({
      generation: 1n,
      onSubscribe(socket, payload) {
        assert.equal(payload.readBigUInt64LE(0), 0n);
        socket.write(frame(KIND.START_BATCH, startBatch(1, 0)));
        socket.write(frame(KIND.CHANGE_ENTRY, entryBytes('README.md', CHANGE_ADDED | 0x02)));
        socket.write(frame(KIND.END_BATCH, endBatch(1, 1, 0, 0)));
      },
    });
    try {
      const configPath = configFor(root, replayed.path);
      const result = await namesForRoot(root, { configPath });
      assert.equal(result.source, 'replay');
      assert.deepEqual(result.names, ['README.md']);
    } finally {
      await replayed.close();
    }

    const pruned = await fakeDaemon({
      generation: 9n,
      onSubscribe(socket) {
        socket.write(errorFrame(2, 'batch-too-old: batches start at 7'));
      },
    });
    try {
      const configPath = configFor(root, pruned.path);
      assert.equal(await namesForRoot(root, { configPath }), null);
    } finally {
      await pruned.close();
    }
  });

  test('include/exclude use the daemon filter semantics', async () => {
    const root = tempDir();
    mkdirSync(join(root, '.git'));
    const daemon = await fakeDaemon({
      generation: 1n,
      onSubscribe(socket) {
        socket.write(frame(KIND.START_BATCH, startBatch(1, 0)));
        for (const name of ['README.md', 'UPPER.MD', 'notes.txt', 'docs/guide.md', 'other/docs/guide.md']) {
          socket.write(frame(KIND.CHANGE_ENTRY, entryBytes(name, CHANGE_ADDED | 0x02)));
        }
        socket.write(frame(KIND.END_BATCH, endBatch(1, 5, 0, 0)));
      },
    });

    try {
      const configPath = configFor(root, daemon.path);

      // A pattern without `/` is a basename, matched at any depth. Matching is
      // case-sensitive, as git's is.
      const basename = await namesForRoot(root, { configPath, include: ['*.md'] });
      assert.deepEqual(basename.names, ['README.md', 'docs/guide.md', 'other/docs/guide.md']);

      // The character class is how a caller asks for `.md` in any case.
      const anyCase = await namesForRoot(root, { configPath, include: ['*.[mM][dD]'] });
      assert.deepEqual(anyCase.names, ['README.md', 'UPPER.MD', 'docs/guide.md', 'other/docs/guide.md']);

      // A pattern with `/` is anchored to the root.
      const anchored = await namesForRoot(root, { configPath, include: ['docs/*.md'] });
      assert.deepEqual(anchored.names, ['docs/guide.md']);

      // Exclude wins, and a `**` pattern reaches any depth.
      const excluded = await namesForRoot(root, {
        configPath,
        include: ['*.md'],
        exclude: ['**/other/**'],
      });
      assert.deepEqual(excluded.names, ['README.md', 'docs/guide.md']);
    } finally {
      await daemon.close();
    }
  });

  test('no daemon, an unreachable socket, or a baseline ahead of the daemon is null', async () => {
    assert.equal(await namesForRoot(tempDir(), { configPath: join(tempDir(), 'missing.json') }), null);

    const root = publishedRoot();
    const unreachable = await fakeDaemon({ generation: 1n, onSubscribe() {} });
    const path = unreachable.path;
    await unreachable.close();
    assert.equal(await namesForRoot(root, { configPath: configFor(root, path) }), null);

    const behind = await fakeDaemon({ generation: 0n, onSubscribe() {} });
    try {
      // The trio is generation 1; a daemon whose head is 0 cannot replay from it.
      assert.equal(await namesForRoot(root, { configPath: configFor(root, behind.path) }), null);
    } finally {
      await behind.close();
    }
  });
});
