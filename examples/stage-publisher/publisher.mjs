#!/usr/bin/env bun
// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//
// A small scp-like stage publisher: it copies a stage's artifacts while their `STAGE_CHANGE_ENTRY` frames arrive,
// commits the copy set at `STAGE_BATCH_END`, and only then runs an optional reload/restart command. It is a
// client, not a watcher: the daemon does the scan and the stage bookkeeping.
//
//   bun examples/stage-publisher/publisher.mjs \
//     --socket <runtime>/roots/<id>.sock --root <project> --dest <deploy-dir> --stage 1 \
//     --include 'build/classes/**' --after-batch 'systemctl reload demo'
//
// `--stage 1` subscribes to the consumer of stage 0: it receives stage 0's artifact batches. `--from-stage-batch`
// defaults to 0, so the first run replays the archived stage batches; use the last applied generation on a resume.

import { createConnection } from 'node:net';
import { copyFile, mkdir, rename, rm, stat } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { spawn } from 'node:child_process';

const KIND = {
  HELLO: 0x01,
  START_BATCH: 0x02,
  CHANGE_ENTRY: 0x03,
  END_BATCH: 0x04,
  ERROR: 0x05,
  SUBSCRIBE: 0x06,
  PING: 0x07,
  PONG: 0x08,
  STATE: 0x09,
  GIT_EVENT: 0x0a,
  SUBSCRIBE_V2: 0x0b,
  BUILD_STARTED: 0x0c,
  BUILD_DONE: 0x0d,
  STAGE_READY: 0x0e,
  STAGE_BATCH_START: 0x0f,
  STAGE_CHANGE_ENTRY: 0x10,
  STAGE_BATCH_END: 0x11,
  SUBSCRIBE_V3: 0x12,
};
const PROTOCOL = 0x0105;
const ENTRY_SIZE = 64;
const CHANGE_MASK = 0x20 | 0x40 | 0x80;

function frame(kind, payload) {
  const header = Buffer.alloc(8);
  header.writeUInt16LE(kind, 0);
  header.writeUInt16LE(0, 2);
  header.writeUInt32LE(payload.length, 4);
  return Buffer.concat([header, payload]);
}

function helloFrame() {
  const payload = Buffer.alloc(24);
  payload.writeUInt16LE(PROTOCOL, 0);
  payload.writeUInt16LE(ENTRY_SIZE, 2);
  payload.writeUInt8(0, 4); // wyhash64
  payload.writeUInt8(1, 5); // role: client
  payload.writeUInt8(0, 6); // capabilities
  payload.writeBigUInt64LE(0n, 8);
  payload.writeBigUInt64LE(1n << 20n, 16);
  return frame(KIND.HELLO, payload);
}

function subscribeV3({ fromBatch, fromStageBatch, stage, include, exclude }) {
  const parts = [];
  const fixed = Buffer.alloc(20);
  fixed.writeBigUInt64LE(BigInt(fromBatch), 0);
  fixed.writeBigUInt64LE(BigInt(fromStageBatch), 8);
  fixed.writeUInt16LE(stage, 16);
  fixed.writeUInt16LE(0, 18);
  parts.push(fixed);
  for (const patterns of [include, exclude]) {
    const count = Buffer.alloc(2);
    count.writeUInt16LE(patterns.length, 0);
    parts.push(count);
    for (const pattern of patterns) {
      const length = Buffer.alloc(2);
      length.writeUInt16LE(Buffer.byteLength(pattern), 0);
      parts.push(length, Buffer.from(pattern));
    }
  }
  return frame(KIND.SUBSCRIBE_V3, Buffer.concat(parts));
}

function parseArgs(argv) {
  const options = {
    socket: null,
    root: null,
    dest: null,
    stage: 1,
    fromStageBatch: 0,
    include: [],
    exclude: [],
    afterBatch: null,
    once: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = () => {
      index += 1;
      if (index >= argv.length) throw new Error(`${arg} needs a value`);
      return argv[index];
    };
    switch (arg) {
      case '--socket': options.socket = next(); break;
      case '--root': options.root = next(); break;
      case '--dest': options.dest = next(); break;
      case '--stage': options.stage = Number(next()); break;
      case '--from-stage-batch': options.fromStageBatch = Number(next()); break;
      case '--include': options.include.push(next()); break;
      case '--exclude': options.exclude.push(next()); break;
      case '--after-batch': options.afterBatch = next(); break;
      case '--once': options.once = true; break;
      default: throw new Error(`unknown option ${arg}`);
    }
  }
  if (!options.socket || !options.root || !options.dest) {
    throw new Error('--socket, --root and --dest are required');
  }
  return options;
}

/** One batch's speculative copy set. Nothing here is committed state until `STAGE_BATCH_END`. */
class CopySet {
  constructor(options) {
    this.options = options;
    this.generation = 0;
    this.received = 0;
    this.expected = null;
    this.pending = [];
    this.deletes = [];
    this.errors = [];
  }

  reset(generation) {
    this.generation = generation;
    this.received = 0;
    this.expected = null;
    this.pending = [];
    this.deletes = [];
    this.errors = [];
  }

  change(entry, name) {
    this.received += 1;
    const kind = entry.flags & CHANGE_MASK;
    if (kind === 0x80) {
      this.deletes.push(name);
      return;
    }
    if ((entry.flags & 0x04) !== 0) {
      // A directory entry: create it now; its children arrive as their own entries.
      this.pending.push(mkdir(join(this.options.dest, name), { recursive: true }).catch((error) => this.errors.push(`${name}: ${error.message}`)));
      return;
    }
    if ((entry.flags & 0x02) !== 0) {
      this.pending.push(this.copyOne(name).catch((error) => this.errors.push(`${name}: ${error.message}`)));
    }
  }

  async copyOne(name) {
    const source = join(this.options.root, name);
    const target = join(this.options.dest, name);
    await mkdir(dirname(target), { recursive: true });
    const temporary = `${target}.stage-publish-${process.pid}-${this.received}`;
    try {
      await copyFile(source, temporary);
      await rm(target, { force: true, recursive: true });
      await rename(temporary, target);
    } finally {
      await rm(temporary, { force: true, recursive: true }).catch(() => {});
    }
  }

  async commit(added, changed, deleted) {
    await Promise.all(this.pending);
    for (const name of this.deletes) {
      try {
        await rm(join(this.options.dest, name), { recursive: true, force: true });
      } catch (error) {
        this.errors.push(`${name}: ${error.message}`);
      }
    }
    this.expected = added + changed + deleted;
    if (this.received !== this.expected) {
      this.errors.push(`count mismatch: received ${this.received}, END_BATCH says ${this.expected}`);
    }
    return this.errors.length === 0;
  }
}

function runHook(script) {
  if (!script) return Promise.resolve(true);
  const isWindows = process.platform === 'win32';
  const child = spawn(isWindows ? 'cmd' : '/bin/sh', isWindows ? ['/c', script] : ['-c', script], {
    stdio: 'inherit',
  });
  return new Promise((resolve) => {
    child.on('error', () => resolve(false));
    child.on('exit', (code) => resolve(code === 0));
  });
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const socket = createConnection({ path: options.socket });
  let serverHead = 0;
  let buffered = Buffer.alloc(0);
  let sawHello = false;
  let batchOpen = false;
  const copySet = new CopySet(options);

  const write = (bytes) => socket.write(bytes);
  const fail = (message) => {
    console.error(`fsmeta-publish: ${message}`);
    socket.destroy();
    process.exitCode = 1;
  };

  const handle = async (kind, payload) => {
    switch (kind) {
      case KIND.HELLO:
        if (payload.length !== 24) return fail('HELLO is not 24 bytes');
        serverHead = Number(payload.readBigUInt64LE(8));
        if (!sawHello) {
          sawHello = true;
          write(subscribeV3({
            fromBatch: serverHead,
            fromStageBatch: options.fromStageBatch,
            stage: options.stage,
            include: options.include,
            exclude: options.exclude,
          }));
        }
        return;
      case KIND.STATE:
        return; // transitions are diagnostics; the stage frames carry the work
      case KIND.STAGE_BATCH_START: {
        if (payload.length !== 26) return fail('STAGE_BATCH_START length');
        const stage = payload.readUInt16LE(0);
        const generation = Number(payload.readBigUInt64LE(2));
        copySet.reset(generation);
        batchOpen = true;
        console.log(`stage ${stage}: batch ${generation} started`);
        return;
      }
      case KIND.STAGE_CHANGE_ENTRY: {
        if (payload.length < ENTRY_SIZE) return fail('STAGE_CHANGE_ENTRY shorter than 64 bytes');
        const entry = payload.subarray(0, ENTRY_SIZE);
        const nameLength = entry.readUInt32LE(40);
        const name = payload.subarray(ENTRY_SIZE, ENTRY_SIZE + nameLength).toString('utf8');
        copySet.change({
          flags: entry.readUInt32LE(44),
        }, name);
        return;
      }
      case KIND.STAGE_BATCH_END: {
        if (payload.length !== 43) return fail('STAGE_BATCH_END length');
        const generation = Number(payload.readBigUInt64LE(2));
        const added = Number(payload.readBigUInt64LE(10));
        const changed = Number(payload.readBigUInt64LE(18));
        const deleted = Number(payload.readBigUInt64LE(26));
        const status = payload.readUInt8(42);
        const ok = status === 0 && await copySet.commit(added, changed, deleted);
        batchOpen = false;
        if (!ok) {
          console.error(`stage batch ${generation}: ${copySet.errors.length} copier error(s); post-batch hook skipped`);
          for (const error of copySet.errors) console.error(`  ${error}`);
          socket.destroy();
          process.exitCode = 1;
          return;
        }
        console.log(`stage batch ${generation}: ${added} added, ${changed} changed, ${deleted} deleted`);
        if (options.afterBatch) {
          const hookOk = await runHook(options.afterBatch);
          if (!hookOk) {
            console.error(`post-batch hook failed: ${options.afterBatch}`);
            socket.destroy();
            process.exitCode = 1;
            return;
          }
        }
        if (options.once) {
          socket.end();
          return;
        }
        return;
      }
      case KIND.ERROR: {
        const code = payload.readUInt16LE(0);
        return fail(`server error ${code}: ${payload.subarray(2).toString('utf8')}`);
      }
      default:
        return; // root batches and STAGE_READY are not this tool's work
    }
  };

  socket.on('connect', () => write(helloFrame()));
  socket.on('data', (chunk) => {
    buffered = Buffer.concat([buffered, chunk]);
    while (buffered.length >= 8) {
      const length = buffered.readUInt32LE(4);
      if (buffered.length < 8 + length) return;
      const kind = buffered.readUInt16LE(0);
      const payload = buffered.subarray(8, 8 + length);
      buffered = buffered.subarray(8 + length);
      handle(kind, payload).catch((error) => fail(error.message));
    }
  });
  socket.on('error', (error) => fail(error.message));
  socket.on('close', () => {
    if (batchOpen) {
      console.error('stage connection closed mid-batch; no copy set was committed');
      process.exitCode = 1;
      return;
    }
    if (process.exitCode === undefined) process.exitCode = 0;
  });
}

await main();
