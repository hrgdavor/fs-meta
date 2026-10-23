#!/usr/bin/env bun
// The live path of `fsmeta serve --live`: after the handshake and the replay, a subscriber stays
// connected and receives the batches the server's own publisher writes. The frames are exactly the
// replay's — START_BATCH / CHANGE_ENTRY / END_BATCH — because FORMAT.socket.md already defines live
// updates as "the same messages"; nothing is re-framed and nothing is added.
//
//   bun test test/serve-stream.test.mjs
//
// The tree is prepared with the CLI's `refresh` (a separate process, before `serve` starts), and the
// live change is published by `serve --live` itself: the point under test is that one process replays,
// then publishes and streams without the client reconnecting. All waiting is bounded by the socket
// reader's timeout or by the connect retry loop; there is no "sleep until the server is ready".
import { afterAll, describe, expect, test } from 'bun:test';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const binary = join(here, '..', 'zig-out', 'bin', process.platform === 'win32' ? 'fsmeta.exe' : 'fsmeta');
if (!existsSync(binary)) {
  throw new Error(`build the engine first: zig build (expected ${binary})`);
}

// A live pass walks the served tree while the test is writing into it. A file that appears by rename is
// either absent or complete when the walk reaches it, so the test cannot publish a half-written entry
// and then see a second batch for the other half.
const staged = [];
let stagingCounter = 0;
function createFile(root, name, data) {
  const base = join(here, '..', '.tmp');
  mkdirSync(base, { recursive: true });
  const temporary = join(base, `staged-${process.pid}-${stagingCounter++}`);
  staged.push(temporary);
  writeFileSync(temporary, data);
  renameSync(temporary, join(root, name));
}

// FORMAT.socket.md, "Messages": the only kinds this suite sends or expects.
const KIND = { HELLO: 0x01, START_BATCH: 0x02, CHANGE_ENTRY: 0x03, END_BATCH: 0x04, ERROR: 0x05, SUBSCRIBE: 0x06 };
const CHANGE_MASK = 0x20 | 0x40 | 0x80;
const ENTRY_SIZE = 64;

const roots = [];
const children = [];
afterAll(async () => {
  for (const child of children) {
    try { child.kill(); } catch {}
  }
  for (const root of roots) rmSync(root, { recursive: true, force: true });
  for (const file of staged) rmSync(file, { force: true });
});

/** Scratch under the project's `.tmp/`, the same rule the other integration suites follow. */
function scratch() {
  const base = join(here, '..', '.tmp');
  mkdirSync(base, { recursive: true });
  const dir = mkdtempSync(join(base, 'serve-stream-'));
  roots.push(dir);
  return dir;
}

/** Publish the tree's current state in a separate process; the first call also writes batch 1. */
function publish(root, second) {
  return execFileSync(binary, ['refresh', root, '--updated', `2026-10-24T00:00:0${second}Z`], {
    encoding: 'utf8',
    cwd: here,
  });
}

/**
 * A tree whose archive ends at generation 2:
 *   batch 1: a.txt added
 *   batch 2: b.txt added
 * `serve --live` is what publishes generation 3, so nothing is written between start and subscribe
 * unless the live publisher itself does it.
 */
function twoBatchTree() {
  const root = scratch();
  writeFileSync(join(root, 'a.txt'), 'one\n');
  publish(root, 0);
  writeFileSync(join(root, 'b.txt'), 'b\n');
  publish(root, 1);
  return root;
}

function socketPath(root) {
  return join(root, '.fs-meta', 'socket');
}

// ──────────────────────────────────────────────
// The client: exactly the document's bytes
// ──────────────────────────────────────────────

/** `HELLO` as the handshake section specifies it: 8-byte prefix + the fixed 24-byte payload. */
function helloFrame() {
  const bytes = Buffer.alloc(8 + 24);
  bytes.writeUInt16LE(KIND.HELLO, 0);
  bytes.writeUInt16LE(0, 2);
  bytes.writeUInt32LE(24, 4);
  bytes.writeUInt16LE(0x0100, 8); // protocol: major 1, minor 0
  bytes.writeUInt16LE(ENTRY_SIZE, 10);
  bytes.writeUInt8(0, 12); // hash_algorithm 0 = wyhash64
  bytes.writeUInt8(1, 13); // role 1 = client
  bytes.writeUInt8(0, 14); // capabilities
  bytes.writeUInt8(0, 15); // reserved
  bytes.writeBigUInt64LE(2n, 16); // generation the client knows
  bytes.writeBigUInt64LE(1n << 20n, 24); // max_frame = 1 MiB
  return bytes;
}

/** `SUBSCRIBE`: the 8-byte prefix, then a u64 `from_batch`. */
function subscribeFrame(fromBatch) {
  const bytes = Buffer.alloc(8 + 8);
  bytes.writeUInt16LE(KIND.SUBSCRIBE, 0);
  bytes.writeUInt16LE(0, 2);
  bytes.writeUInt32LE(8, 4);
  bytes.writeBigUInt64LE(BigInt(fromBatch), 8);
  return bytes;
}

class Peer {
  #socket;
  #buffer = Buffer.alloc(0);
  #waiter = null;
  #failure = null;
  closed = false;

  constructor(socket) {
    this.#socket = socket;
  }

  push(chunk) {
    this.#buffer = Buffer.concat([this.#buffer, Buffer.from(chunk)]);
    this.#wake();
  }

  finish(error) {
    if (error) this.#failure = error;
    this.closed = true;
    this.#wake();
  }

  #wake() {
    if (this.#waiter) {
      const wake = this.#waiter;
      this.#waiter = null;
      wake();
    }
  }

  send(bytes) {
    this.#socket.write(bytes);
  }

  async read(length, timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    while (this.#buffer.length < length) {
      if (this.#failure) throw new Error(`socket failed: ${this.#failure.message}`);
      if (this.closed) throw new Error(`closed with ${this.#buffer.length}/${length} bytes buffered`);
      const remaining = deadline - Date.now();
      if (remaining <= 0) throw new Error(`timed out with ${this.#buffer.length}/${length} bytes buffered`);
      await new Promise((resolve) => {
        this.#waiter = resolve;
        setTimeout(resolve, remaining);
      });
    }
    const out = this.#buffer.subarray(0, length);
    this.#buffer = this.#buffer.subarray(length);
    return out;
  }

  /** One frame: the 8-byte prefix, then exactly `length` payload bytes. */
  async frame(timeoutMs = 3000) {
    const prefix = await this.read(8, timeoutMs);
    const kind = prefix.readUInt16LE(0);
    const flags = prefix.readUInt16LE(2);
    const length = prefix.readUInt32LE(4);
    const payload = await this.read(length, timeoutMs);
    return { kind, flags, length, payload };
  }

  end() {
    try { this.#socket.end(); } catch {}
  }
}

/**
 * Connect and send HELLO + SUBSCRIBE immediately (the document's simultaneous greeting). Retries until
 * the server's address exists, so readiness is bounded by `timeoutMs` rather than a fixed sleep.
 */
async function connect(root, fromBatch, { timeoutMs = 5000 } = {}) {
  const path = socketPath(root);
  const deadline = Date.now() + timeoutMs;
  let lastError = null;
  while (Date.now() < deadline) {
    if (existsSync(path)) {
      try {
        return await new Promise((resolve, reject) => {
          let peer = null;
          let settled = false;
          Bun.connect({
            unix: path,
            socket: {
              open(socket) {
                peer = new Peer(socket);
              },
              data(_socket, chunk) {
                peer?.push(chunk);
              },
              close() {
                peer?.finish(null);
              },
              error(_socket, error) {
                if (!settled && !peer) {
                  settled = true;
                  reject(error);
                  return;
                }
                peer?.finish(error);
              },
            },
          })
            .then(() => {
              if (!peer) {
                settled = true;
                reject(new Error('connected without an open socket'));
                return;
              }
              settled = true;
              peer.send(helloFrame());
              peer.send(subscribeFrame(fromBatch));
              resolve(peer);
            })
            .catch((error) => {
              settled = true;
              reject(error);
            });
        });
      } catch (error) {
        lastError = error;
      }
    }
    await Bun.sleep(25);
  }
  throw new Error(`socket ${path} did not become reachable in ${timeoutMs}ms: ${lastError ?? 'no address'}`);
}

/** Start `fsmeta serve <root> [extra...]`; its output is captured for a failure message. */
function startServer(root, extra = []) {
  const child = Bun.spawn([binary, 'serve', root, ...extra], { cwd: here, stdout: 'pipe', stderr: 'pipe' });
  children.push(child);
  const output = { text: '' };
  const decoder = new TextDecoder();
  const collect = async (stream) => {
    for await (const chunk of stream) output.text += decoder.decode(chunk);
  };
  collect(child.stdout);
  collect(child.stderr);
  child.output = output;
  return child;
}

async function stopServer(child) {
  try { child.kill(); } catch {}
  await Promise.race([child.exited, Bun.sleep(2000)]);
}

// ──────────────────────────────────────────────
// Reading frames
// ──────────────────────────────────────────────

/** The server's greeting, checked field by field against the handshake section. */
function expectHello(frame, generation) {
  expect(frame.kind).toBe(KIND.HELLO);
  expect(frame.flags).toBe(0);
  expect(frame.length).toBe(24);
  const payload = frame.payload;
  expect(payload.readUInt16LE(0) >> 8).toBe(1); // major version
  expect(payload.readUInt16LE(2)).toBe(ENTRY_SIZE);
  expect(payload.readUInt8(4)).toBe(0); // wyhash64
  expect(payload.readUInt8(5)).toBe(0); // role 0 = server
  expect(payload.readBigUInt64LE(8)).toBe(BigInt(generation));
}

/** A `CHANGE_ENTRY`: the trio's 64-byte entry plus the name, self-delimiting by nameLength at offset 40. */
function parseChangeEntry(frame) {
  expect(frame.kind).toBe(KIND.CHANGE_ENTRY);
  expect(frame.flags).toBe(0);
  expect(frame.payload.length).toBeGreaterThanOrEqual(ENTRY_SIZE);
  const entry = frame.payload.subarray(0, ENTRY_SIZE);
  const nameLength = entry.readUInt32LE(40);
  const name = frame.payload.subarray(ENTRY_SIZE);
  expect(frame.length).toBe(ENTRY_SIZE + nameLength);
  expect(name.length).toBe(nameLength);
  expect(name.includes(0x0a)).toBe(false); // no LF
  const flagsWord = entry.readUInt32LE(44);
  const changeBits = flagsWord & CHANGE_MASK;
  expect([0x20, 0x40, 0x80]).toContain(changeBits); // exactly one change bit
  const kind = changeBits === 0x20 ? 'added' : changeBits === 0x40 ? 'changed' : 'deleted';
  return { name: name.toString(), kind, flagsWord };
}

/** Read `START_BATCH`, its entries, and its `END_BATCH`, returning the decoded batch. */
async function readBatch(peer, timeoutMs = 3000) {
  const startFrame = await peer.frame(timeoutMs);
  expect(startFrame.kind).toBe(KIND.START_BATCH);
  expect(startFrame.flags).toBe(0);
  expect(startFrame.length).toBe(24);
  const number = Number(startFrame.payload.readBigUInt64LE(0));
  const parent = Number(startFrame.payload.readBigUInt64LE(8));

  const entries = [];
  for (;;) {
    const frame = await peer.frame(timeoutMs);
    if (frame.kind === KIND.CHANGE_ENTRY) {
      entries.push(parseChangeEntry(frame));
      continue;
    }
    if (frame.kind === KIND.ERROR) {
      throw new Error(`server refused mid-batch: ${frame.payload.subarray(2).toString()}`);
    }
    expect(frame.kind).toBe(KIND.END_BATCH);
    expect(frame.flags).toBe(0);
    expect(frame.length).toBe(40);
    const end = {
      number: Number(frame.payload.readBigUInt64LE(0)),
      added: Number(frame.payload.readBigUInt64LE(8)),
      changed: Number(frame.payload.readBigUInt64LE(16)),
      deleted: Number(frame.payload.readBigUInt64LE(24)),
    };
    expect(end.number).toBe(number);
    for (const kind of ['added', 'changed', 'deleted']) {
      expect(entries.filter((entry) => entry.kind === kind)).toHaveLength(end[kind]);
    }
    return { number, parent, entries, end };
  }
}

// ──────────────────────────────────────────────
// AF_UNIX availability
// ──────────────────────────────────────────────

/**
 * Whether this platform provides AF_UNIX at all. Where it does not, the suite is skipped with the
 * reason, never passed by pretending a TCP socket is one — the same rule `socket.test.mjs` follows.
 */
const AF_UNIX_PROBE = join(here, '..', '.tmp', `af-unix-live-probe-${process.pid}.sock`);
const afUnixAvailable = await (async () => {
  try {
    mkdirSync(join(here, '..', '.tmp'), { recursive: true });
    const probe = Bun.listen({ unix: AF_UNIX_PROBE, socket: { data() {}, open() {}, close() {} } });
    probe.stop(true);
    rmSync(AF_UNIX_PROBE, { force: true });
    return true;
  } catch {
    return false;
  }
})();
const AF_UNIX_REASON =
  'AF_UNIX is unavailable on this host: Windows provides Unix-domain sockets only from build 17063, and Bun/Zig must both support them; the live socket suite needs one';
const unixTest = afUnixAvailable
  ? test
  : (name, fn) => test.skip(`${name} [skipped: ${AF_UNIX_REASON}]`, fn);

// ──────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────

describe('fsmeta serve --live', () => {
  unixTest(
    'replays, then streams the batch the server itself publishes, on one connection',
    async () => {
      const root = twoBatchTree();
      const server = startServer(root, ['--live']);
      try {
        // from_batch 1: batch 2 is replayed from the archive, so the replay path is exercised first.
        const peer = await connect(root, 1);
        expectHello(await peer.frame(), 2);
        const replayed = await readBatch(peer);
        expect(replayed.number).toBe(2);
        expect(replayed.parent).toBe(1);
        expect(replayed.entries.map((entry) => entry.name)).toContain('b.txt');
        expect(peer.closed).toBe(false);

        // From here the tree changes and NO second process runs `refresh`: `serve --live` is the
        // publisher, so this proves the server's own pass reaches the subscription.
        createFile(root, 'c.txt', 'c\n');

        const live = await readBatch(peer, 15000);
        expect(live.number).toBe(3);
        expect(live.parent).toBe(2);
        expect(live.entries.map((entry) => entry.name)).toEqual(['c.txt']);
        expect(live.entries[0].kind).toBe('added');
        expect(live.end).toEqual({ number: 3, added: 1, changed: 0, deleted: 0 });
        expect(peer.closed).toBe(false); // the same socket, never reconnected

        // A second change on the same connection: the stream is continuous, not one lucky batch.
        createFile(root, 'd.txt', 'd\n');
        const next = await readBatch(peer, 15000);
        expect(next.number).toBe(4);
        expect(next.parent).toBe(3);
        expect(next.entries.map((entry) => entry.name)).toEqual(['d.txt']);
        expect(next.end).toEqual({ number: 4, added: 1, changed: 0, deleted: 0 });
        expect(peer.closed).toBe(false);
        peer.end();
      } catch (error) {
        throw new Error(`${error.message}\nserver output:\n${server.output.text}`);
      } finally {
        await stopServer(server);
      }
    },
    30000,
  );

  unixTest(
    'a subscriber already at the newest batch gets only what is published after it',
    async () => {
      const root = twoBatchTree();
      const server = startServer(root, ['--live']);
      try {
        const peer = await connect(root, 2); // newest: nothing to replay
        expectHello(await peer.frame(), 2);

        // Bounded silence: more than two publisher intervals with nothing to publish. This is the
        // assertion that live mode does not fabricate a generation on an unchanged tree — a bounded
        // wait for a frame that must not arrive, not a sleep to reach readiness.
        await expect(peer.frame(700)).rejects.toThrow(/timed out/);

        createFile(root, 'e.txt', 'e\n');
        const live = await readBatch(peer, 15000);
        expect(live.number).toBe(3);
        expect(live.entries.map((entry) => entry.name)).toEqual(['e.txt']);
        expect(peer.closed).toBe(false);
        peer.end();
      } catch (error) {
        throw new Error(`${error.message}\nserver output:\n${server.output.text}`);
      } finally {
        await stopServer(server);
      }
    },
    30000,
  );
});
