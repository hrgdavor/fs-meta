#!/usr/bin/env bun
// Integration tests for the socket server: the binary protocol of FORMAT.socket.md, over AF_UNIX.
//
//   bun test test
//
// These drive the built CLI (`zig-out/bin/fsmeta.exe serve <root>`), because the thing being tested is the
// transport: a client that speaks exactly the document's framing, a reply that is framed the same way, and a
// loop that serves more than one connection. The batch archive is built by running `refresh` twice, so the
// replay is compared against batches the engine itself wrote.
import { afterAll, describe, expect, test } from 'bun:test';
import { execFileSync } from 'node:child_process';
import { appendFileSync, existsSync, lstatSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const binary = join(here, '..', 'zig-out', 'bin', process.platform === 'win32' ? 'fsmeta.exe' : 'fsmeta');
if (!existsSync(binary)) {
  throw new Error(`build the engine first: zig build (expected ${binary})`);
}

// FORMAT.socket.md, "Messages": the only kinds this suite sends or expects.
const KIND = { HELLO: 0x01, START_BATCH: 0x02, CHANGE_ENTRY: 0x03, END_BATCH: 0x04, ERROR: 0x05, SUBSCRIBE: 0x06, PING: 0x07 };
const CHANGE_MASK = 0x20 | 0x40 | 0x80;
const ENTRY_SIZE = 64;

const roots = [];
const children = [];
afterAll(async () => {
  for (const child of children) {
    try { child.kill(); } catch {}
  }
  for (const root of roots) rmSync(root, { recursive: true, force: true });
});

/** Scratch under the project's `.tmp/`, the same rule `reconcile.test.mjs` follows. */
function scratch() {
  const base = join(here, '..', '.tmp');
  mkdirSync(base, { recursive: true });
  const dir = mkdtempSync(join(base, 'socket-'));
  roots.push(dir);
  return dir;
}

/** Publish the tree's current state; the first publish also records batch 1 (every name is added). */
function publish(root, second) {
  return execFileSync(binary, ['refresh', root, '--updated', `2026-10-24T00:00:0${second}Z`], {
    encoding: 'utf8',
    cwd: here,
  });
}

/**
 * A tree with two generations and therefore two batches:
 *   batch 1: a.txt, src/, src/b.java added
 *   batch 2: a.txt changed, src/c.java added
 */
function twoGenerationTree() {
  const root = scratch();
  mkdirSync(join(root, 'src'));
  writeFileSync(join(root, 'a.txt'), 'one\n');
  writeFileSync(join(root, 'src', 'b.java'), 'class B {}\n');
  publish(root, 0);
  writeFileSync(join(root, 'a.txt'), 'two\n');
  writeFileSync(join(root, 'src', 'c.java'), 'class C {}\n');
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

  async read(length, timeoutMs = 3000) {
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

  async waitClosed(timeoutMs = 3000) {
    const deadline = Date.now() + timeoutMs;
    while (!this.closed && Date.now() < deadline) await Bun.sleep(20);
    return this.closed;
  }

  end() {
    try { this.#socket.end(); } catch {}
  }
}

/**
 * Connect to the socket, sending HELLO and SUBSCRIBE immediately (the document's simultaneous greeting).
 * Retries on connect until the server's address exists, so readiness is bounded by `timeoutMs` rather than a
 * fixed sleep. The last error is reported with the server's captured output by `startServer`'s caller.
 */
async function connect(root, fromBatch, { subscribe = true, timeoutMs = 5000 } = {}) {
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
              if (subscribe) peer.send(subscribeFrame(fromBatch));
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

/** Start `fsmeta serve <root>`; its output is captured for a failure message. */
function startServer(root) {
  const child = Bun.spawn([binary, 'serve', root], { cwd: here, stdout: 'pipe', stderr: 'pipe' });
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
// Reading a replay
// ──────────────────────────────────────────────

/** The server's greeting, checked field by field against the handshake section. */
function expectHello(frame, generation) {
  expect(frame.kind).toBe(KIND.HELLO);
  expect(frame.flags).toBe(0);
  expect(frame.length).toBe(24);
  const payload = frame.payload;
  expect(payload.length).toBe(24);
  expect(payload.readUInt16LE(0) >> 8).toBe(1); // major version
  expect(payload.readUInt16LE(2)).toBe(ENTRY_SIZE);
  expect(payload.readUInt8(4)).toBe(0); // wyhash64
  expect(payload.readUInt8(5)).toBe(0); // role 0 = server
  expect(payload.readUInt8(6) & 0x02).toBe(0); // changes_hash capability not advertised
  expect(payload.readBigUInt64LE(8)).toBe(BigInt(generation));
  expect(payload.readBigUInt64LE(16)).toBeGreaterThanOrEqual(BigInt(ENTRY_SIZE));
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
async function readBatch(peer) {
  const startFrame = await peer.frame();
  expect(startFrame.kind).toBe(KIND.START_BATCH);
  expect(startFrame.flags).toBe(0);
  expect(startFrame.length).toBe(24);
  const number = Number(startFrame.payload.readBigUInt64LE(0));
  const parent = Number(startFrame.payload.readBigUInt64LE(8));

  const entries = [];
  for (;;) {
    const frame = await peer.frame();
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

/** What batch 1 and batch 2 of `twoGenerationTree` contain, ordered by (nameHash, name). */
const EXPECTED_BATCH_1 = {
  number: 1,
  parent: 0,
  names: ['a.txt', 'src/', 'src/b.java'],
  added: 3,
  changed: 0,
  deleted: 0,
};
const EXPECTED_BATCH_2 = {
  number: 2,
  parent: 1,
  names: ['a.txt', 'src/c.java'],
  added: 1,
  changed: 1,
  deleted: 0,
};

function expectBatch(batch, expected) {
  expect(batch.number).toBe(expected.number);
  expect(batch.parent).toBe(expected.parent);
  expect(batch.end).toEqual({
    number: expected.number,
    added: expected.added,
    changed: expected.changed,
    deleted: expected.deleted,
  });
  expect(batch.entries.map((entry) => entry.name).sort()).toEqual([...expected.names].sort());
}

// ──────────────────────────────────────────────
// AF_UNIX availability
// ──────────────────────────────────────────────

/**
 * Whether this platform provides AF_UNIX at all. Windows has it from 10 build 17063 and Bun must have been
 * built against a runtime that offers it; where it is missing the suite is skipped with the reason, never
 * passed by pretending a TCP socket is one.
 */
const AF_UNIX_PROBE = join(here, '..', '.tmp', `af-unix-probe-${process.pid}.sock`);
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
  'AF_UNIX is unavailable on this host: Windows provides Unix-domain sockets only from build 17063, and Bun/Zig must both support them; the socket suite needs one';
const unixTest = afUnixAvailable
  ? test
  : (name, fn) => test.skip(`${name} [skipped: ${AF_UNIX_REASON}]`, fn);

// ──────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────

describe('FORMAT.socket.md over a Unix socket', () => {
  unixTest(
    'replays the batch archive, framed exactly as the document specifies',
    async () => {
      const root = twoGenerationTree();
      const server = startServer(root);
      try {
        const peer = await connect(root, 1);
        expectHello(await peer.frame(), 2);
        const batch = await readBatch(peer);
        expectBatch(batch, EXPECTED_BATCH_2);
        expect(await peer.waitClosed()).toBe(true);
        peer.end();
      } catch (error) {
        throw new Error(`${error.message}\nserver output:\n${server.output.text}`);
      } finally {
        await stopServer(server);
      }
    },
    20000,
  );

  unixTest(
    'the accept loop serves a second connection, and from_batch 0 replays the whole archive',
    async () => {
      const root = twoGenerationTree();
      const server = startServer(root);
      try {
        const first = await connect(root, 1);
        expectHello(await first.frame(), 2);
        expectBatch(await readBatch(first), EXPECTED_BATCH_2);
        await first.waitClosed();
        first.end();

        // A second, independent connection: from 0, so both batches arrive, in generation order.
        const second = await connect(root, 0);
        expectHello(await second.frame(), 2);
        expectBatch(await readBatch(second), EXPECTED_BATCH_1);
        expectBatch(await readBatch(second), EXPECTED_BATCH_2);
        expect(await second.waitClosed()).toBe(true);
        second.end();
      } catch (error) {
        throw new Error(`${error.message}\nserver output:\n${server.output.text}`);
      } finally {
        await stopServer(server);
      }
    },
    20000,
  );

  unixTest(
    'a client older than the retained archive is refused with batch-too-old, not a shortened replay',
    async () => {
      const root = twoGenerationTree();
      // Retention presents itself as a first batch that is no longer 1.
      rmSync(join(root, '.fs-meta', 'batches', '00000001'), { recursive: true, force: true });
      const server = startServer(root);
      try {
        const peer = await connect(root, 0);
        expectHello(await peer.frame(), 2);
        const error = await peer.frame();
        expect(error.kind).toBe(KIND.ERROR);
        expect(error.flags).toBe(0);
        expect(error.length).toBeGreaterThan(2);
        expect(error.payload.readUInt16LE(0)).toBe(2); // this server's batch-too-old code
        expect(error.payload.subarray(2).toString()).toContain('batch-too-old');
        expect(await peer.waitClosed()).toBe(true);
        peer.end();
      } catch (error) {
        throw new Error(`${error.message}\nserver output:\n${server.output.text}`);
      } finally {
        await stopServer(server);
      }
    },
    20000,
  );

  unixTest(
    'the reserved MULTIPART flag is refused with unsupported-flags, not ignored',
    async () => {
      const root = twoGenerationTree();
      const server = startServer(root);
      try {
        // Greet, then send a PING-shaped frame with the reserved bit 0 set instead of SUBSCRIBE.
        const peer = await connect(root, 1, { subscribe: false });
        expectHello(await peer.frame(), 2);
        const frame = Buffer.alloc(8);
        frame.writeUInt16LE(KIND.PING, 0);
        frame.writeUInt16LE(0x0001, 2); // bit 0 = MULTIPART, reserved
        frame.writeUInt32LE(0, 4);
        peer.send(frame);
        const error = await peer.frame();
        expect(error.kind).toBe(KIND.ERROR);
        expect(error.payload.subarray(2).toString()).toContain('unsupported-flags');
        expect(await peer.waitClosed()).toBe(true);
        peer.end();
      } catch (error) {
        throw new Error(`${error.message}\nserver output:\n${server.output.text}`);
      } finally {
        await stopServer(server);
      }
    },
    20000,
  );

  // POSIX-only variant: the same replay, plus the property Linux CI has and Windows does not guarantee —
  // that the bound address is a socket node in the file system (S_ISSOCK).
  test.skipIf(process.platform === 'win32')(
    'POSIX: the bound address is a socket node and the replay still matches the archive',
    async () => {
      const root = twoGenerationTree();
      const server = startServer(root);
      try {
        const peer = await connect(root, 1);
        expectHello(await peer.frame(), 2);
        expect(lstatSync(socketPath(root)).isSocket()).toBe(true);
        expectBatch(await readBatch(peer), EXPECTED_BATCH_2);
        expect(await peer.waitClosed()).toBe(true);
        peer.end();
      } catch (error) {
        throw new Error(`${error.message}\nserver output:\n${server.output.text}`);
      } finally {
        await stopServer(server);
      }
    },
    20000,
  );
});

describe('serve refuses to start without a usable trio', () => {
  test('a missing trio is a clear failure, not a listening socket', () => {
    const root = scratch();
    const result = Bun.spawnSync([binary, 'serve', root], { cwd: here, stdout: 'pipe', stderr: 'pipe' });
    expect(result.exitCode).not.toBe(0);
    const text = `${result.stdout.toString()}${result.stderr.toString()}`;
    expect(text).toContain('no usable trio');
    expect(existsSync(socketPath(root))).toBe(false);
  });

  test('a corrupt trio is refused with the verify hint, not served', () => {
    const root = twoGenerationTree();
    // One extra byte breaks the entry count: the trio fails validation and cannot back a server.
    appendFileSync(join(root, '.fs-meta', 'files.meta'), Buffer.from([0]));
    const result = Bun.spawnSync([binary, 'serve', root], { cwd: here, stdout: 'pipe', stderr: 'pipe' });
    expect(result.exitCode).not.toBe(0);
    const text = `${result.stdout.toString()}${result.stderr.toString()}`;
    expect(text).toContain('not usable');
    expect(text).toContain('fsmeta verify');
    expect(existsSync(socketPath(root))).toBe(false);
  });
});
