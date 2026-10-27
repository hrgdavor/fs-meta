#!/usr/bin/env bun
// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//
// The M1 gate of `plans/archive/daemon.md`: parity with `fsmeta serve` on the same tree.
//
// One tree, one batch archive under `<root>/.fs-meta/`, two servers that replay it. `fsmeta serve <root>` binds
// `<root>/.fs-meta/socket`; `fsmeta daemon start --foreground` serves the same root at `<runtime>/roots/<id>.sock`
// and may interleave its one added frame, `STATE` (0x09), between batches. A consumer that asks both from
// `from_batch = 0` must be given the same batches: the same advertised generation, the same batch numbers and
// parents, the same entries (name *and* change kind, from the entry's change bits at offset 44), and the same
// `END_BATCH` counts. Anything else means the daemon is not a server of that archive but a second opinion.
//
//   bun test test/daemon-parity.test.mjs
//
// The archive is built by running the CLI's `refresh` twice, so both sides replay batches the engine itself
// wrote. Hermetic: the daemon gets a scratch runtime directory, a scratch config home and a scratch tree, all
// under `.tmp/`; the suite kills only the children it spawned and removes only its own scratch directories.
import { afterAll, describe, expect, test } from 'bun:test';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { binary } from './binary.mjs';

if (!existsSync(binary)) {
  throw new Error(`build the engine first: zig build (or set FSMETA_BIN); expected ${binary}`);
}

const here = dirname(fileURLToPath(import.meta.url));

// FORMAT.socket.md, "Messages": the kinds both servers may send and the client sends.
const KIND = {
  HELLO: 0x01,
  START_BATCH: 0x02,
  CHANGE_ENTRY: 0x03,
  END_BATCH: 0x04,
  ERROR: 0x05,
  SUBSCRIBE: 0x06,
  STATE: 0x09,
};
const CHANGE_MASK = 0x20 | 0x40 | 0x80;
const ENTRY_SIZE = 64;

/** `STATE`'s state table, in the order the byte encodes it (`FORMAT.socket.md` § STATE). */
const STATE_NAMES = ['off', 'asleep', 'waking', 'watching'];

/** The daemon's protocol: major 1, minor 2 adds `STATE` and `GIT_EVENT` (`wire.zig`). */
const DAEMON_PROTOCOL = 0x0102;

const scratchDirs = [];
const children = [];

afterAll(async () => {
  for (const child of children) {
    try { child.kill('SIGKILL'); } catch {}
  }
  for (const dir of scratchDirs) {
    rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
  }
});

/** Scratch under the project's `.tmp/`, the rule every integration suite follows. */
function scratch(prefix) {
  const base = join(here, '..', '.tmp');
  mkdirSync(base, { recursive: true });
  const dir = mkdtempSync(join(base, prefix));
  scratchDirs.push(dir);
  return dir;
}

/**
 * A scratch machine: the tree, the daemon's runtime directory and its config home. One directory owns all
 * three so the test's cleanup is "remove this one scratch directory".
 */
function machine() {
  const home = scratch('daemon-parity-');
  const runtime = join(home, 'run');
  const config = join(home, 'config');
  const root = join(home, 'tree');
  mkdirSync(runtime, { recursive: true });
  mkdirSync(config, { recursive: true });
  mkdirSync(join(root, 'src'), { recursive: true });
  return {
    home,
    runtime,
    config,
    root,
    env: { ...process.env, FSMETA_RUNTIME_DIR: runtime, FSMETA_CONFIG_HOME: config },
  };
}

/** Publish the tree's current state in a separate process; the first call writes batch 1. */
function publish(root, second) {
  return execFileSync(binary, ['refresh', root, '--updated', `2026-10-24T00:00:0${second}Z`], {
    encoding: 'utf8',
    cwd: here,
  });
}

/**
 * The one tree and the one archive both servers replay:
 *   batch 1: a.txt, src/, src/b.java added
 *   batch 2: a.txt changed, src/c.java added
 * No `.gitignore` is needed: nothing in the fixture is ignored, so it would only hide the comparison.
 */
function twoGenerationTree(m) {
  writeFileSync(join(m.root, 'a.txt'), 'one\n');
  writeFileSync(join(m.root, 'src', 'b.java'), 'class B {}\n');
  publish(m.root, 0);
  writeFileSync(join(m.root, 'a.txt'), 'two\n');
  writeFileSync(join(m.root, 'src', 'c.java'), 'class C {}\n');
  publish(m.root, 1);
}

function socketPath(root) {
  return join(root, '.fs-meta', 'socket');
}

function daemonSocket(m, id) {
  return join(m.runtime, 'roots', `${id}.sock`);
}

// ──────────────────────────────────────────────
// The CLI, as a caller would run it
// ──────────────────────────────────────────────

/** Run the binary with the machine's hermetic environment; never throws on a non-zero exit. */
function cli(m, ...args) {
  const result = Bun.spawnSync([binary, ...args], { cwd: here, env: m.env, stdout: 'pipe', stderr: 'pipe' });
  const out = result.stdout.toString();
  const err = result.stderr.toString();
  return { code: result.exitCode, out, err, text: `${out}${err}` };
}

function cliOk(m, ...args) {
  const result = cli(m, ...args);
  if (result.code !== 0) throw new Error(`fsmeta ${args.join(' ')} exited ${result.code}:\n${result.text}`);
  return result;
}

function roots(m) {
  return JSON.parse(cliOk(m, 'roots', 'list', '--json').out).roots;
}

function addRoot(m, path) {
  const result = cliOk(m, 'root', 'add', path);
  const match = result.out.match(/added ([0-9a-f]{8})/);
  if (!match) throw new Error(`no root id in the output of root add:\n${result.text}`);
  return match[1];
}

/** Capture a child's stdout and stderr into `child.output.text`, for a failure message. */
function capture(child) {
  child.output = { text: '' };
  const decoder = new TextDecoder();
  for (const stream of [child.stdout, child.stderr]) {
    (async () => {
      for await (const chunk of stream) child.output.text += decoder.decode(chunk);
    })();
  }
  return child;
}

/** Start `fsmeta serve <root>`; its output is captured for a failure message. */
function startServer(m) {
  const child = Bun.spawn([binary, 'serve', m.root], { cwd: here, stdout: 'pipe', stderr: 'pipe' });
  children.push(child);
  return capture(child);
}

async function stopServer(child) {
  try { child.kill(); } catch {}
  await Promise.race([child.exited, Bun.sleep(2000)]);
}

/** Start `fsmeta daemon start --foreground --base <runtime>`; output captured for failure messages. */
function startDaemon(m) {
  const child = Bun.spawn([binary, 'daemon', 'start', '--foreground', '--base', m.runtime], {
    cwd: here,
    env: m.env,
    stdout: 'pipe',
    stderr: 'pipe',
  });
  children.push(child);
  return capture(child);
}

async function stopDaemon(child) {
  try { child.kill('SIGKILL'); } catch {}
  await Promise.race([child.exited, Bun.sleep(3000)]);
}

/** Wait until the daemon answers `daemon status`; a daemon that dies first fails with its output. */
async function waitForDaemon(m, child, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(`the daemon exited with ${child.exitCode} before answering daemon status`);
    }
    if (cli(m, 'daemon', 'status').code === 0) return;
    await Bun.sleep(50);
  }
  throw new Error(`the daemon did not answer daemon status in ${timeoutMs}ms`);
}

// ──────────────────────────────────────────────
// The consumer: exactly FORMAT.socket.md's bytes
// ──────────────────────────────────────────────

/**
 * `HELLO`: the 8-byte prefix plus the fixed 24-byte payload. The minor version is the caller's: `serve`
 * predates `STATE` and is greeted as 0x0100, the daemon as 0x0101; both compare majors.
 */
function helloFrame(protocol) {
  const bytes = Buffer.alloc(8 + 24);
  bytes.writeUInt16LE(KIND.HELLO, 0);
  bytes.writeUInt16LE(0, 2);
  bytes.writeUInt32LE(24, 4);
  bytes.writeUInt16LE(protocol, 8);
  bytes.writeUInt16LE(ENTRY_SIZE, 10);
  bytes.writeUInt8(0, 12); // hash_algorithm 0 = wyhash64
  bytes.writeUInt8(1, 13); // role 1 = client
  bytes.writeUInt8(0, 14); // capabilities
  bytes.writeUInt8(0, 15); // reserved
  bytes.writeBigUInt64LE(0n, 16); // generation the client knows
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

  async read(length, timeoutMs = 5000) {
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
  async frame(timeoutMs = 5000) {
    const prefix = await this.read(8, timeoutMs);
    return {
      kind: prefix.readUInt16LE(0),
      flags: prefix.readUInt16LE(2),
      length: prefix.readUInt32LE(4),
      payload: await this.read(prefix.readUInt32LE(4), timeoutMs),
    };
  }

  async waitClosed(timeoutMs = 5000) {
    const deadline = Date.now() + timeoutMs;
    while (!this.closed && Date.now() < deadline) await Bun.sleep(20);
    return this.closed;
  }

  end() {
    try { this.#socket.end(); } catch {}
  }
}

/**
 * Connect to one consumer socket, sending HELLO and SUBSCRIBE immediately (the document's simultaneous
 * greeting). Retries on connect until the address exists, bounded by `timeoutMs` rather than a fixed sleep.
 */
async function connect(path, fromBatch, { protocol = DAEMON_PROTOCOL, timeoutMs = 10000 } = {}) {
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
              peer.send(helloFrame(protocol));
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

// ──────────────────────────────────────────────
// Reading a replay, from either server
// ──────────────────────────────────────────────

/**
 * The server's greeting: prefix, payload size, protocol major, layout, hash and role. `side` and `root`
 * only make the failure message name which server on which tree disagreed.
 */
function checkHello(frame, side, root) {
  const where = `${side} (root ${root})`;
  if (frame.kind !== KIND.HELLO) throw new Error(`${where}: expected HELLO, got frame kind 0x${frame.kind.toString(16)}`);
  if (frame.flags !== 0) throw new Error(`${where}: HELLO.flags is ${frame.flags}, expected 0`);
  if (frame.length !== 24) throw new Error(`${where}: HELLO.length is ${frame.length}, expected 24`);
  const payload = frame.payload;
  if (payload.length !== 24) throw new Error(`${where}: HELLO payload is ${payload.length} bytes, expected 24`);
  const protocol = payload.readUInt16LE(0);
  if (protocol >> 8 !== 1) throw new Error(`${where}: HELLO.protocol is 0x${protocol.toString(16)}, major is not 1`);
  if (payload.readUInt16LE(2) !== ENTRY_SIZE) throw new Error(`${where}: HELLO.entry_size is not ${ENTRY_SIZE}`);
  if (payload.readUInt8(4) !== 0) throw new Error(`${where}: HELLO.hash_algorithm is not 0 (wyhash64)`);
  if (payload.readUInt8(5) !== 0) throw new Error(`${where}: HELLO.role is not 0 (server)`);
  if (payload.readBigUInt64LE(16) < BigInt(ENTRY_SIZE)) throw new Error(`${where}: HELLO.max_frame is too small`);
  return { protocol, generation: Number(payload.readBigUInt64LE(8)) };
}

/** A `STATE` frame: flags, the fixed 14-byte payload, and one of the four table states. */
function parseState(frame, side, root) {
  const where = `${side} (root ${root})`;
  if (frame.kind !== KIND.STATE) throw new Error(`${where}: expected STATE, got frame kind 0x${frame.kind.toString(16)}`);
  if (frame.flags !== 0) throw new Error(`${where}: STATE.flags is ${frame.flags}, expected 0`);
  if (frame.length !== 14 || frame.payload.length !== 14) {
    throw new Error(`${where}: STATE.length is ${frame.length}, expected 14`);
  }
  const state = STATE_NAMES[frame.payload.readUInt8(0)];
  if (state === undefined) throw new Error(`${where}: STATE.state is ${frame.payload.readUInt8(0)}, not a table value`);
  return { name: state };
}

/** A `CHANGE_ENTRY`: the trio's 64-byte entry plus the name, self-delimiting by nameLength at offset 40. */
function parseChangeEntry(frame, side, root, batch) {
  const where = `${side} (root ${root}): batch ${batch}`;
  if (frame.kind !== KIND.CHANGE_ENTRY) {
    throw new Error(`${where}: expected CHANGE_ENTRY, got frame kind 0x${frame.kind.toString(16)}`);
  }
  if (frame.flags !== 0) throw new Error(`${where}: CHANGE_ENTRY.flags is ${frame.flags}, expected 0`);
  if (frame.payload.length < ENTRY_SIZE) throw new Error(`${where}: CHANGE_ENTRY shorter than ${ENTRY_SIZE} bytes`);
  const entry = frame.payload.subarray(0, ENTRY_SIZE);
  const nameLength = entry.readUInt32LE(40);
  const name = frame.payload.subarray(ENTRY_SIZE);
  if (frame.length !== ENTRY_SIZE + nameLength || name.length !== nameLength) {
    throw new Error(`${where}: CHANGE_ENTRY is ${frame.length} bytes for a ${nameLength}-byte name`);
  }
  const changeBits = entry.readUInt32LE(44) & CHANGE_MASK;
  if (![0x20, 0x40, 0x80].includes(changeBits)) {
    throw new Error(`${where}: entry ${JSON.stringify(name.toString())} has change bits 0x${changeBits.toString(16)}`);
  }
  const kind = changeBits === 0x20 ? 'added' : changeBits === 0x40 ? 'changed' : 'deleted';
  return { name: name.toString(), kind };
}

/**
 * Read one `START_BATCH` … `END_BATCH` transaction. `STATE` frames may precede it — the daemon announces
 * every transition — and are skipped; a `STATE` *inside* a batch is a protocol violation, so this throws.
 */
async function readBatch(peer, { side, root, timeoutMs = 10000 } = {}) {
  let frame = await peer.frame(timeoutMs);
  while (frame.kind === KIND.STATE) {
    parseState(frame, side, root);
    frame = await peer.frame(timeoutMs);
  }
  if (frame.kind === KIND.ERROR) {
    throw new Error(`${side} (root ${root}) refused: ${frame.payload.subarray(2).toString()}`);
  }
  if (frame.kind !== KIND.START_BATCH) {
    throw new Error(`${side} (root ${root}): expected START_BATCH, got frame kind 0x${frame.kind.toString(16)}`);
  }
  if (frame.flags !== 0) throw new Error(`${side} (root ${root}): START_BATCH.flags is ${frame.flags}, expected 0`);
  if (frame.length !== 24) throw new Error(`${side} (root ${root}): START_BATCH.length is ${frame.length}, expected 24`);
  const number = Number(frame.payload.readBigUInt64LE(0));
  const parent = Number(frame.payload.readBigUInt64LE(8));

  const entries = [];
  for (;;) {
    frame = await peer.frame(timeoutMs);
    if (frame.kind === KIND.CHANGE_ENTRY) {
      entries.push(parseChangeEntry(frame, side, root, number));
      continue;
    }
    if (frame.kind === KIND.STATE) throw new Error(`${side} (root ${root}): STATE inside batch ${number}`);
    if (frame.kind === KIND.ERROR) {
      throw new Error(`${side} (root ${root}) refused mid-batch ${number}: ${frame.payload.subarray(2).toString()}`);
    }
    if (frame.kind !== KIND.END_BATCH) {
      throw new Error(`${side} (root ${root}): batch ${number}: expected END_BATCH, got 0x${frame.kind.toString(16)}`);
    }
    break;
  }
  if (frame.flags !== 0) throw new Error(`${side} (root ${root}): batch ${number}: END_BATCH.flags is not 0`);
  if (frame.length !== 40) throw new Error(`${side} (root ${root}): batch ${number}: END_BATCH.length is not 40`);
  const end = {
    number: Number(frame.payload.readBigUInt64LE(0)),
    added: Number(frame.payload.readBigUInt64LE(8)),
    changed: Number(frame.payload.readBigUInt64LE(16)),
    deleted: Number(frame.payload.readBigUInt64LE(24)),
  };
  if (end.number !== number) throw new Error(`${side} (root ${root}): END_BATCH.number ${end.number} != ${number}`);
  for (const kind of ['added', 'changed', 'deleted']) {
    const seen = entries.filter((entry) => entry.kind === kind).length;
    if (seen !== end[kind]) {
      throw new Error(`${side} (root ${root}): batch ${number}: ${seen} ${kind} entries but END_BATCH says ${end[kind]}`);
    }
  }
  return { number, parent, entries, end };
}

/**
 * Read every batch after `from_batch = 0` up to the generation the server advertised in HELLO, so "all
 * batches" is bounded by the server's own answer instead of by a timeout. A batch number that does not
 * advance is a framing error on that side, not a comparison difference.
 */
async function collectBatches(peer, head, side, root) {
  const batches = [];
  let sent = 0;
  while (sent < head) {
    let batch;
    try {
      batch = await readBatch(peer, { side, root });
    } catch (error) {
      throw new Error(`${error.message} (while reading the batch after ${sent})`);
    }
    if (batch.number <= sent) {
      throw new Error(`${side} (root ${root}): batch ${batch.number} did not advance past ${sent}`);
    }
    batches.push(batch);
    sent = batch.number;
  }
  return batches;
}

// ──────────────────────────────────────────────
// The comparison, with a message that names the difference
// ──────────────────────────────────────────────

function list(values) {
  return `[${values.join(', ')}]`;
}

function describeEntries(entries) {
  return list(entries.map((entry) => `${JSON.stringify(entry.name)}:${entry.kind}`));
}

/**
 * Assert that the two consumers were given the same archive. Every failure names the root, the batch and,
 * for an entry, its index and name — so a failing run says precisely where the two servers diverge.
 *
 * Not compared: `STATE` frames. `serve` does not send them at all; they are the daemon's addition and are
 * skipped while reading, exactly as `test/daemon.test.mjs` skips them.
 */
function expectParity(root, served, daemon) {
  if (served.generation !== daemon.generation) {
    throw new Error(
      `root ${root}: HELLO.generation differs: serve advertised ${served.generation}, daemon ${daemon.generation}`,
    );
  }
  const servedNumbers = served.batches.map((batch) => batch.number);
  const daemonNumbers = daemon.batches.map((batch) => batch.number);
  if (servedNumbers.length !== daemonNumbers.length || servedNumbers.some((n, i) => n !== daemonNumbers[i])) {
    throw new Error(
      `root ${root}: batch numbers differ: serve replayed ${list(servedNumbers)}, daemon replayed ${list(daemonNumbers)}`,
    );
  }
  for (let i = 0; i < served.batches.length; i += 1) {
    const a = served.batches[i];
    const b = daemon.batches[i];
    if (a.parent !== b.parent) {
      throw new Error(`root ${root}: batch ${a.number}: parent differs: serve ${a.parent}, daemon ${b.parent}`);
    }
    if (a.entries.length !== b.entries.length) {
      throw new Error(
        `root ${root}: batch ${a.number}: entry count differs: serve has ${a.entries.length} ${describeEntries(a.entries)}, ` +
          `daemon has ${b.entries.length} ${describeEntries(b.entries)}`,
      );
    }
    for (let j = 0; j < a.entries.length; j += 1) {
      const left = a.entries[j];
      const right = b.entries[j];
      if (left.name !== right.name) {
        throw new Error(
          `root ${root}: batch ${a.number}: entry ${j} name differs: serve ${JSON.stringify(left.name)}, ` +
            `daemon ${JSON.stringify(right.name)} (daemon entries: ${describeEntries(b.entries)})`,
        );
      }
      if (left.kind !== right.kind) {
        throw new Error(
          `root ${root}: batch ${a.number}: entry ${j} ${JSON.stringify(left.name)} change kind differs: ` +
            `serve '${left.kind}', daemon '${right.kind}'`,
        );
      }
    }
    for (const kind of ['added', 'changed', 'deleted']) {
      if (a.end[kind] !== b.end[kind]) {
        throw new Error(
          `root ${root}: batch ${a.number}: END_BATCH.${kind} differs: serve ${a.end[kind]}, daemon ${b.end[kind]}`,
        );
      }
    }
  }
}

// ──────────────────────────────────────────────
// The two servers
// ──────────────────────────────────────────────

/** Serve path: `fsmeta serve <root>`, connect, HELLO, read from 0, and confirm the one-shot replay ends. */
async function readFromServe(m) {
  const server = startServer(m);
  let peer = null;
  try {
    peer = await connect(socketPath(m.root), 0, { protocol: 0x0100 });
    const hello = checkHello(await peer.frame(), 'serve', m.root);
    const batches = await collectBatches(peer, hello.generation, 'serve', m.root);
    if (!(await peer.waitClosed())) {
      // `serve` replays the archive and closes; still being open would mean the read above stopped early.
      throw new Error(`serve (root ${m.root}): did not close after replaying generation ${hello.generation}`);
    }
    return { ...hello, batches };
  } catch (error) {
    throw new Error(`${error.message}\nserve output:\n${server.output.text}`);
  } finally {
    peer?.end();
    await stopServer(server);
  }
}

/** The per-root log the daemon keeps, appended to a failure message when it exists. */
function readLog(m, id) {
  try {
    return `\ndaemon log ${id}:\n${readFileSync(join(m.runtime, 'logs', `${id}.log`), 'utf8')}`;
  } catch {
    return '';
  }
}

/** Daemon path: start it, add the same tree, connect at `<runtime>/roots/<id>.sock`, read from 0. */
async function readFromDaemon(m) {
  const daemon = startDaemon(m);
  let id = null;
  let peer = null;
  try {
    await waitForDaemon(m, daemon);
    id = addRoot(m, m.root);
    if (!/^[0-9a-f]{8}$/.test(id)) throw new Error(`root add returned a non-hex8 id: ${JSON.stringify(id)}`);

    const socket = daemonSocket(m, id);
    peer = await connect(socket, 0, { protocol: DAEMON_PROTOCOL });
    // Connecting proves it: this is the daemon's socket, at the documented path. Assert the same fact from
    // the registry and the file system so a future path change is a test failure, not a silent pass.
    if (!existsSync(socket)) throw new Error(`daemon (root ${m.root}): no socket at ${socket}`);
    const record = roots(m).find((candidate) => candidate.id === id);
    if (!record) throw new Error(`daemon (root ${m.root}): root ${id} is not in roots list`);
    if (record.socket !== socket) {
      throw new Error(`daemon (root ${m.root}): registry socket ${record.socket}, expected ${socket}`);
    }

    const hello = checkHello(await peer.frame(), 'daemon', m.root);
    if (hello.protocol !== DAEMON_PROTOCOL) {
      throw new Error(
        `daemon (root ${m.root}): advertised protocol 0x${hello.protocol.toString(16)}, ` +
          `expected 0x${DAEMON_PROTOCOL.toString(16)}`,
      );
    }
    const batches = await collectBatches(peer, hello.generation, 'daemon', m.root);

    // A wake scan runs after the replay. On an archive the engine already published, it must publish
    // nothing: a batch here would mean a consumer from 0 received more from the daemon than from `serve`.
    await expectNoBatchBeforeWatching(peer, m.root);

    return { ...hello, batches, id, socket };
  } catch (error) {
    throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}${id ? readLog(m, id) : ''}`);
  } finally {
    peer?.end();
    await stopDaemon(daemon);
  }
}

/**
 * After the replayed head, read frames until the wake scan reports `watching`. A `START_BATCH` before
 * that is a batch the archive did not hold when the consumer subscribed, so the two replays were not
 * comparing the same thing. This is the daemon's post-replay transition, not part of the comparison.
 */
async function expectNoBatchBeforeWatching(peer, root, timeoutMs = 15000) {
  const seen = [];
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const frame = await peer.frame(Math.max(250, deadline - Date.now()));
    if (frame.kind === KIND.STATE) {
      const state = parseState(frame, 'daemon', root);
      seen.push(state.name);
      if (state.name === 'watching') return;
      continue;
    }
    if (frame.kind === KIND.START_BATCH) {
      const number = Number(frame.payload.readBigUInt64LE(0));
      throw new Error(
        `daemon (root ${root}): published batch ${number} after the replayed head; ` +
          'the wake scan must not invent a generation for an unchanged tree',
      );
    }
    if (frame.kind === KIND.ERROR) {
      throw new Error(`daemon (root ${root}) refused after the replay: ${frame.payload.subarray(2).toString()}`);
    }
    throw new Error(`daemon (root ${root}): unexpected frame kind 0x${frame.kind.toString(16)} after the replay`);
  }
  throw new Error(`daemon (root ${root}): no STATE(watching) within ${timeoutMs}ms; saw STATE ${list(seen)}`);
}

// ──────────────────────────────────────────────
// AF_UNIX availability
// ──────────────────────────────────────────────

/**
 * Whether this platform provides AF_UNIX at all. Windows has it from 10 build 17063 and Bun must have been
 * built against a runtime that offers it; where it is missing the suite is skipped with the reason, never
 * passed by pretending a TCP socket is one. The probe is the same one `test/socket.test.mjs` uses.
 */
const AF_UNIX_PROBE = join(here, '..', '.tmp', `daemon-parity-probe-${process.pid}.sock`);
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
  'AF_UNIX is unavailable on this host: Windows provides Unix-domain sockets only from build 17063, and Bun/Zig must both support them; the daemon parity suite needs one';
const unixTest = afUnixAvailable
  ? test
  : (name, fn) => test.skip(`${name} [skipped: ${AF_UNIX_REASON}]`, fn);

// ──────────────────────────────────────────────
// Test
// ──────────────────────────────────────────────

describe('daemon parity with fsmeta serve on the same tree', () => {
  unixTest(
    'both servers replay the same archive from from_batch 0',
    async () => {
      const m = machine();
      twoGenerationTree(m);

      const served = await readFromServe(m);
      const daemon = await readFromDaemon(m);

      // The premise: two `refresh` runs left two generations for both servers to replay. Without this a
      // comparison of two empty lists could pass without either server doing anything.
      if (served.generation !== 2) {
        throw new Error(`the two-generation fixture ends at generation 2, but serve advertised ${served.generation}`);
      }
      expect(served.batches.map((batch) => batch.number)).toEqual([1, 2]);
      expect(served.batches.reduce((total, batch) => total + batch.entries.length, 0)).toBeGreaterThan(0);

      expectParity(m.root, served, daemon);

      // The facts that must hold even if the two replays agree: the daemon speaks 0x0101 and binds the
      // documented socket path. (Both are also checked inside readFromDaemon; these keep the contract in
      // the test body, where the reader looks for it.)
      expect(daemon.protocol).toBe(DAEMON_PROTOCOL);
      expect(daemon.socket).toBe(daemonSocket(m, daemon.id));
    },
    90000,
  );
});
