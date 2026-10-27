#!/usr/bin/env bun
// Integration tests for `fsmeta daemon`: the control plane, the per-root sockets and the state machine.
//
//   bun test test
//
// These drive the built binary (`zig-out/bin/fsmeta.exe`, or `FSMETA_BIN` when several builds share a checkout)
// the way a person would: `daemon start --foreground` on
// a scratch runtime directory and a scratch config home, then `root add`, `roots list`, `root sleep` — and a
// consumer that speaks FORMAT.socket.md, including the daemon's one added frame, `STATE` (0x09).
//
// The environment is deliberately hermetic: `FSMETA_RUNTIME_DIR` and `FSMETA_CONFIG_HOME` point into `.tmp/`,
// so a test never reads or writes the developer's own `roots.json` or runtime directory.
import { afterAll, describe, expect, test } from 'bun:test';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { binary } from './binary.mjs';

const here = dirname(fileURLToPath(import.meta.url));
if (!existsSync(binary)) {
  throw new Error(`build the engine first: zig build (expected ${binary})`);
}

// FORMAT.socket.md, "Messages": the kinds this suite sends or expects.
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
};
const CHANGE_MASK = 0x20 | 0x40 | 0x80;
const ENTRY_SIZE = 64;

/** `STATE`'s tables (FORMAT.socket.md § STATE). */
const STATE = ['off', 'asleep', 'waking', 'watching'];
const REASON = ['none', 'client', 'idle', 'control', 'watcher'];

const scratchDirs = [];
const children = [];

afterAll(async () => {
  for (const child of children) {
    try { child.kill('SIGKILL'); } catch {}
  }
  for (const dir of scratchDirs) rmSync(dir, { recursive: true, force: true });
});

function scratch(prefix) {
  const base = join(here, '..', '.tmp');
  mkdirSync(base, { recursive: true });
  const dir = mkdtempSync(join(base, `${prefix}-`));
  scratchDirs.push(dir);
  return dir;
}

/** A scratch machine: a runtime directory, a config home and a tree to serve. */
function machine() {
  const home = scratch('daemon');
  const runtime = join(home, 'run');
  const config = join(home, 'config');
  const root = join(home, 'tree');
  mkdirSync(runtime, { recursive: true });
  mkdirSync(config, { recursive: true });
  mkdirSync(root, { recursive: true });
  return { home, runtime, config, root, env: { ...process.env, FSMETA_RUNTIME_DIR: runtime, FSMETA_CONFIG_HOME: config } };
}

// ──────────────────────────────────────────────
// The CLI, as a caller would run it
// ──────────────────────────────────────────────

/** Run the binary and return its status and output; never throws on a non-zero exit. */
function cli(m, ...args) {
  const result = Bun.spawnSync([binary, ...args], { cwd: here, env: m.env, stdout: 'pipe', stderr: 'pipe' });
  const out = result.stdout.toString();
  const err = result.stderr.toString();
  return { code: result.exitCode, out, err, text: `${out}${err}` };
}

/** Run a command that must succeed, with its output in the failure message. */
function cliOk(m, ...args) {
  const result = cli(m, ...args);
  if (result.code !== 0) throw new Error(`fsmeta ${args.join(' ')} exited ${result.code}:\n${result.text}`);
  return result;
}

function roots(m) {
  return JSON.parse(cliOk(m, 'roots', 'list', '--json').out).roots;
}

function rootById(m, id) {
  return roots(m).find((candidate) => candidate.id === id);
}

function addRoot(m, path, ...extra) {
  const result = cliOk(m, 'root', 'add', path, ...extra);
  const match = result.out.match(/added ([0-9a-f]{8})/);
  if (!match) throw new Error(`no id in root add output: ${result.out}`);
  return match[1];
}

/** Start a daemon in the foreground, with its output captured for failure messages. */
function startDaemon(m, extra = []) {
  const child = Bun.spawn([binary, 'daemon', 'start', '--foreground', '--base', m.runtime, ...extra], {
    cwd: here,
    env: m.env,
    stdout: 'pipe',
    stderr: 'pipe',
  });
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

async function stopDaemon(child) {
  try { child.kill(); } catch {}
  await Promise.race([child.exited, Bun.sleep(3000)]);
}

/** Wait until the daemon answers `status`, so a test never races its startup. */
async function waitForDaemon(m, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (cli(m, 'daemon', 'status').code === 0) return;
    await Bun.sleep(50);
  }
  throw new Error('the daemon did not answer `daemon status` in time');
}

/** Poll `predicate` until it holds, or fail with a message that says what was expected. */
async function eventually(predicate, message, timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    try {
      last = await predicate();
      if (last) return last;
    } catch (error) {
      last = error;
    }
    await Bun.sleep(50);
  }
  throw new Error(`${message}${last instanceof Error ? `: ${last.message}` : ''}`);
}

/** One request line to the control socket, its one reply line parsed. */
function rawControl(socketPath, line, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    let text = '';
    const timer = setTimeout(() => reject(new Error(`no reply to ${line}`)), timeoutMs);
    Bun.connect({
      unix: socketPath,
      socket: {
        open(socket) {
          socket.write(`${line}\n`);
        },
        data(_socket, chunk) {
          text += new TextDecoder().decode(chunk);
        },
        close() {
          clearTimeout(timer);
          try {
            resolve(JSON.parse(text.trim()));
          } catch (error) {
            reject(new Error(`the reply is not JSON: ${JSON.stringify(text)} (${error.message})`));
          }
        },
        error(_socket, error) {
          clearTimeout(timer);
          reject(error);
        },
      },
    }).catch((error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

// SECTION: the consumer

function helloFrame() {
  const bytes = Buffer.alloc(8 + 24);
  bytes.writeUInt16LE(KIND.HELLO, 0);
  bytes.writeUInt32LE(24, 4);
  bytes.writeUInt16LE(0x0102, 8); // protocol: major 1, minor 2 (STATE and GIT_EVENT)
  bytes.writeUInt16LE(ENTRY_SIZE, 10);
  bytes.writeUInt8(0, 12); // hash_algorithm 0 = wyhash64
  bytes.writeUInt8(1, 13); // role 1 = client
  bytes.writeUInt8(0, 14); // capabilities
  bytes.writeBigUInt64LE(0n, 16);
  bytes.writeBigUInt64LE(1n << 20n, 24);
  return bytes;
}

function subscribeFrame(fromBatch) {
  const bytes = Buffer.alloc(8 + 8);
  bytes.writeUInt16LE(KIND.SUBSCRIBE, 0);
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

  async frame(timeoutMs = 5000) {
    const prefix = await this.read(8, timeoutMs);
    return {
      kind: prefix.readUInt16LE(0),
      flags: prefix.readUInt16LE(2),
      length: prefix.readUInt32LE(4),
      payload: await this.read(prefix.readUInt32LE(4), timeoutMs),
    };
  }

  /** The next frame, or `null` if none arrives within `timeoutMs` — the assertion "nothing was sent". */
  async maybeFrame(timeoutMs) {
    try {
      return await this.frame(timeoutMs);
    } catch (error) {
      if (`${error.message}`.includes('timed out')) return null;
      throw error;
    }
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

/** Connect to a root's socket, greeting and subscribing immediately (the simultaneous handshake). */
async function connect(socketPath, fromBatch = 0, { subscribe = true, timeoutMs = 10000 } = {}) {
  const deadline = Date.now() + timeoutMs;
  let lastError = null;
  while (Date.now() < deadline) {
    if (existsSync(socketPath)) {
      try {
        return await new Promise((resolve, reject) => {
          let peer = null;
          let settled = false;
          Bun.connect({
            unix: socketPath,
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
  throw new Error(`socket ${socketPath} did not become reachable in ${timeoutMs}ms: ${lastError ?? 'no address'}`);
}

function expectHello(frame) {
  expect(frame.kind).toBe(KIND.HELLO);
  expect(frame.flags).toBe(0);
  expect(frame.length).toBe(24);
  expect(frame.payload.readUInt16LE(0)).toBe(0x0102);
  expect(frame.payload.readUInt16LE(2)).toBe(ENTRY_SIZE);
  expect(frame.payload.readUInt8(5)).toBe(0); // role = server
}

/** A `STATE` frame: the daemon's one added kind (FORMAT.socket.md § STATE). */
function parseState(frame) {
  expect(frame.kind).toBe(KIND.STATE);
  expect(frame.flags).toBe(0);
  expect(frame.length).toBe(14);
  const state = frame.payload.readUInt8(0);
  const reason = frame.payload.readUInt8(1);
  return {
    state: STATE[state] ?? `unknown(${state})`,
    reason: REASON[reason] ?? `unknown(${reason})`,
    idleTimeoutMs: frame.payload.readUInt32LE(2),
    headBatch: Number(frame.payload.readBigUInt64LE(6)),
  };
}

/** `GIT_EVENT` (0x0A, protocol 0x0102): 20 bytes, and `24 + path_len` for the one variable kind, `worktree`. */
const GIT_PHASE = ['start', 'finish', 'aborted'];
const GIT_KIND = ['branch', 'checkout', 'commit', 'merge', 'rebase', 'index', 'worktree', 'other'];
const GIT_SOURCE = ['metadata', 'hook'];
const GIT_STATUS = ['ok', 'failed', 'timed_out'];

function parseGitEvent(frame) {
  expect(frame.kind).toBe(KIND.GIT_EVENT);
  expect(frame.flags).toBe(0);
  expect(frame.payload.length).toBeGreaterThanOrEqual(20);
  const event = {
    phase: GIT_PHASE[frame.payload.readUInt8(0)] ?? `unknown(${frame.payload.readUInt8(0)})`,
    kind: GIT_KIND[frame.payload.readUInt8(1)] ?? `unknown(${frame.payload.readUInt8(1)})`,
    source: GIT_SOURCE[frame.payload.readUInt8(2)] ?? `unknown(${frame.payload.readUInt8(2)})`,
    status: GIT_STATUS[frame.payload.readUInt8(3)] ?? `unknown(${frame.payload.readUInt8(3)})`,
    headBatch: Number(frame.payload.readBigUInt64LE(4)),
    atMs: Number(frame.payload.readBigUInt64LE(12)),
    path: '',
  };
  if (event.kind === 'worktree') {
    expect(frame.payload.length).toBeGreaterThanOrEqual(24);
    const pathLen = frame.payload.readUInt32LE(20);
    // `path_len <= length - 24`: a frame is a length, not a promise (FORMAT.socket.md § GIT_EVENT).
    expect(pathLen).toBeLessThanOrEqual(frame.payload.length - 24);
    expect(frame.payload.length).toBe(24 + pathLen);
    event.path = frame.payload.subarray(24, 24 + pathLen).toString();
  } else {
    expect(frame.payload.length).toBe(20);
  }
  return event;
}

function parseChangeEntry(frame) {
  expect(frame.kind).toBe(KIND.CHANGE_ENTRY);
  expect(frame.flags).toBe(0);
  const entry = frame.payload.subarray(0, ENTRY_SIZE);
  const nameLength = entry.readUInt32LE(40);
  const flagsWord = entry.readUInt32LE(44);
  const changeBits = flagsWord & CHANGE_MASK;
  expect([0x20, 0x40, 0x80]).toContain(changeBits);
  expect(frame.length).toBe(ENTRY_SIZE + nameLength);
  return {
    name: frame.payload.subarray(ENTRY_SIZE).toString(),
    kind: changeBits === 0x20 ? 'added' : changeBits === 0x40 ? 'changed' : 'deleted',
  };
}

/**
 * Read one `START_BATCH` … `END_BATCH` transaction.
 *
 * `STATE` and `GIT_EVENT` frames may precede it — the daemon announces a transition between batches, and a git
 * start has no ordering constraint (§ 5d) — while either *inside* a batch is a protocol violation, so this asserts
 * rather than tolerating it. The frames that preceded the batch are returned in `states` and `events`.
 */
async function readBatch(peer, { timeoutMs = 8000 } = {}) {
  const states = [];
  const events = [];
  let frame = await peer.frame(timeoutMs);
  while (frame.kind === KIND.STATE || frame.kind === KIND.GIT_EVENT) {
    if (frame.kind === KIND.STATE) states.push(parseState(frame));
    else events.push(parseGitEvent(frame));
    frame = await peer.frame(timeoutMs);
  }
  if (frame.kind === KIND.ERROR) {
    throw new Error(`the server refused: ${frame.payload.subarray(2).toString()}`);
  }
  expect(frame.kind).toBe(KIND.START_BATCH);
  const number = Number(frame.payload.readBigUInt64LE(0));
  const parent = Number(frame.payload.readBigUInt64LE(8));

  const entries = [];
  for (;;) {
    frame = await peer.frame(timeoutMs);
    if (frame.kind === KIND.END_BATCH) break;
    // A `GIT_EVENT` inside a batch would break the transaction; the daemon never sends one there.
    expect(frame.kind).toBe(KIND.CHANGE_ENTRY);
    entries.push(parseChangeEntry(frame));
  }
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
  return { number, parent, entries, end, states, events };
}

/** Read frames until a `STATE` matching `predicate` arrives. */
async function readUntilState(peer, predicate, timeoutMs = 8000) {
  const seen = [];
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const frame = await peer.frame(Math.max(250, deadline - Date.now()));
    if (frame.kind !== KIND.STATE) {
      seen.push({ kind: frame.kind });
      continue;
    }
    const state = parseState(frame);
    seen.push(state);
    if (predicate(state)) return state;
  }
  throw new Error(`no matching STATE; saw ${JSON.stringify(seen)}`);
}

// SECTION: af-unix

/**
 * Whether this platform provides AF_UNIX at all. Windows has it from 10 build 17063 and Bun must have been built
 * against a runtime that offers it; where it is missing the suite is skipped with the reason, never passed by
 * pretending a TCP socket is one.
 */
const AF_UNIX_PROBE = join(here, '..', '.tmp', `daemon-probe-${process.pid}.sock`);
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
  'AF_UNIX is unavailable on this host: Windows provides Unix-domain sockets only from build 17063, and Bun/Zig must both support them; the daemon suite needs one';
const unixTest = afUnixAvailable
  ? test
  : (name, fn) => test.skip(`${name} [skipped: ${AF_UNIX_REASON}]`, fn);

// SECTION: tests

describe('the daemon, over its control socket and its per-root sockets', () => {
  unixTest(
    'two roots are served on two sockets, and a change reaches only its own root',
    async () => {
      const m = machine();
      const other = join(m.home, 'other');
      mkdirSync(other, { recursive: true });
      writeFileSync(join(m.root, 'a.txt'), 'one\n');
      writeFileSync(join(other, 'b.txt'), 'two\n');

      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const first = addRoot(m, m.root, '--idle', '200ms');
        const second = addRoot(m, other, '--idle', '200ms');
        expect(first).not.toBe(second);

        const socketFor = (id) => join(m.runtime, 'roots', `${id}.sock`);
        expect(existsSync(socketFor(first))).toBe(true);
        expect(existsSync(socketFor(second))).toBe(true);

        // Each subscribe wakes its own root: STATE(waking, client) before the wake batch, watching after it.
        const a = await connect(socketFor(first));
        expectHello(await a.frame());
        const firstState = parseState(await a.frame());
        expect(firstState.state).toBe('waking');
        expect(firstState.reason).toBe('client');
        expect(firstState.idleTimeoutMs).toBe(200);
        expect(firstState.headBatch).toBe(0);
        const firstBatch = await readBatch(a);
        expect(firstBatch.states).toEqual([]); // no STATE inside a batch
        expect(firstBatch.entries.map((entry) => entry.name)).toEqual(['a.txt']);
        const watching = await readUntilState(a, (state) => state.state === 'watching');
        expect(watching.headBatch).toBeGreaterThanOrEqual(1);

        const b = await connect(socketFor(second));
        expectHello(await b.frame());
        expect(parseState(await b.frame()).state).toBe('waking');
        const bFirstBatch = await readBatch(b);
        expect(bFirstBatch.entries.map((entry) => entry.name)).toEqual(['b.txt']);
        await readUntilState(b, (state) => state.state === 'watching');

        // A change under the first root arrives there, and nowhere else.
        writeFileSync(join(m.root, 'c.txt'), 'three\n');
        const live = await readBatch(a);
        expect(live.entries.map((entry) => entry.name)).toEqual(['c.txt']);
        expect(live.entries[0].kind).toBe('added');
        expect(await b.maybeFrame(1200)).toBeNull();

        a.end();
        b.end();
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    60000,
  );

  unixTest(
    'an idle root sleeps, and a returning client wakes it with the diff',
    async () => {
      const m = machine();
      writeFileSync(join(m.root, 'a.txt'), 'one\n');
      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const id = addRoot(m, m.root, '--idle', '200ms');
        const socket = join(m.runtime, 'roots', `${id}.sock`);

        const first = await connect(socket);
        expectHello(await first.frame());
        expect(parseState(await first.frame()).state).toBe('waking');
        const batch = await readBatch(first);
        expect(batch.entries.map((entry) => entry.name)).toEqual(['a.txt']);
        await readUntilState(first, (state) => state.state === 'watching');
        first.end();
        await first.waitClosed();

        // No clients left: after the idle timeout the root sleeps, and says why.
        const asleep = await eventually(
          async () => {
            const root = rootById(m, id);
            return root?.state === 'asleep' ? root : null;
          },
          'the root never reported asleep after its idle timeout',
        );
        expect(asleep.clients).toBe(0);
        expect(asleep.reason).toBe('idle');

        // While it sleeps the tree changes, and nothing publishes: no watcher is running.
        writeFileSync(join(m.root, 'a.txt'), 'one, edited while asleep\n');
        writeFileSync(join(m.root, 'b.txt'), 'new\n');
        const before = rootById(m, id);
        await Bun.sleep(600);
        expect(rootById(m, id).head_batch).toBe(before.head_batch);

        // A returning client is told it is waking, then receives the whole difference, then watching.
        const second = await connect(socket, before.head_batch);
        expectHello(await second.frame());
        const waking = parseState(await second.frame());
        expect(waking.state).toBe('waking');
        expect(waking.reason).toBe('client');
        const catchUp = await readBatch(second);
        expect(catchUp.number).toBeGreaterThan(before.head_batch);
        expect(catchUp.entries.map((entry) => entry.name).sort()).toEqual(['a.txt', 'b.txt']);
        expect(catchUp.entries.find((entry) => entry.name === 'a.txt').kind).toBe('changed');
        expect(catchUp.entries.find((entry) => entry.name === 'b.txt').kind).toBe('added');
        await readUntilState(second, (state) => state.state === 'watching');

        // The pass's cost is exposed, and it is not the timestamp: `last_pass_ms` says when the pass ran,
        // `last_pass_duration_ms` how long it took. A wake that published a diff must report files and bytes.
        const status = JSON.parse(cliOk(m, 'root', 'status', id, '--json').out).root;
        for (const field of ['last_pass_ms', 'last_pass_duration_ms', 'last_pass_files', 'last_pass_batch_bytes']) {
          expect(typeof status[field]).toBe('number');
        }
        expect(status.last_pass_files).toBeGreaterThanOrEqual(1);
        expect(status.last_pass_duration_ms).toBeGreaterThanOrEqual(0);

        // The safety net's counters exist and stay honest: this root was woken twice by a subscriber and never
        // sat silent for the interval, so nothing was a safety pass.
        for (const field of ['event_passes', 'safety_passes']) {
          expect(typeof status[field]).toBe('number');
        }
        expect(status.safety_passes).toBe(0);
        expect(status.last_pass_batch_bytes).toBeGreaterThan(0);
        // An epoch-milliseconds timestamp, not a duration: the two fields cannot have been swapped.
        expect(status.last_pass_ms).toBeGreaterThan(1_000_000_000_000);
        second.end();
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    60000,
  );

  unixTest(
    'off never watches and refuses a wake; always watches with no clients at all',
    async () => {
      const m = machine();
      const alwaysRoot = join(m.home, 'always');
      mkdirSync(alwaysRoot, { recursive: true });
      writeFileSync(join(m.root, 'a.txt'), 'one\n');
      writeFileSync(join(alwaysRoot, 'b.txt'), 'two\n');

      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const offId = addRoot(m, m.root, '--mode', 'off');
        const alwaysId = addRoot(m, alwaysRoot, '--mode', 'always', '--idle', '200ms');

        // `off` serves from a scan, reports its state, and then watches nothing.
        const off = await connect(join(m.runtime, 'roots', `${offId}.sock`));
        expectHello(await off.frame());
        expect(parseState(await off.frame()).state).toBe('off');
        const scanned = await readBatch(off); // the on-demand scan the socket answers with
        expect(scanned.entries.map((entry) => entry.name)).toEqual(['a.txt']);
        const offHead = rootById(m, offId).head_batch;
        writeFileSync(join(m.root, 'touched-while-off.txt'), 'x\n');
        expect(await off.maybeFrame(1200)).toBeNull();
        off.end();

        // A control wake is refused by policy, not ignored: exit 4 with the reason.
        const refusal = cli(m, 'root', 'wake', offId);
        expect(refusal.code).toBe(4);
        expect(refusal.text).toContain('mode is off');

        // `always` watches with zero clients: its head batch moves on its own.
        const watched = await eventually(
          async () => {
            const root = rootById(m, alwaysId);
            return root && root.state === 'watching' && root.head_batch >= 1 ? root : null;
          },
          'the always-mode root never started watching with no clients',
        );
        writeFileSync(join(alwaysRoot, 'c.txt'), 'three\n');
        await eventually(
          async () => rootById(m, alwaysId).head_batch > watched.head_batch,
          'the always-mode root did not pick up a change with no clients',
        );

        // And `off` really never published: its head is still the generation its subscribe scanned.
        expect(rootById(m, offId).head_batch).toBe(offHead);

        // A control sleep forces even `always`; a control wake resumes it.
        cliOk(m, 'root', 'sleep', alwaysId);
        expect(rootById(m, alwaysId).state).toBe('asleep');
        cliOk(m, 'root', 'wake', alwaysId);
        await eventually(
          async () => rootById(m, alwaysId).state === 'watching',
          'the always-mode root did not resume after a control wake',
        );

        // `root set idle 0` is a setting, not a missing value: it prints as "never" and stops the idle rule.
        cliOk(m, 'root', 'set', alwaysId, 'idle', '0');
        expect(rootById(m, alwaysId).idle_timeout_ms).toBe(0);
        expect(cliOk(m, 'root', 'status', alwaysId).out).toContain('idle never');
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    60000,
  );

  unixTest(
    'the root list is durable: a restart re-reads it, and a vanished root is reported as missing',
    async () => {
      const m = machine();
      writeFileSync(join(m.root, 'a.txt'), 'one\n');
      const doomed = join(m.home, 'doomed');
      mkdirSync(doomed, { recursive: true });
      writeFileSync(join(doomed, 'b.txt'), 'two\n');

      let daemon = startDaemon(m);
      let id = null;
      let doomedId = null;
      try {
        await waitForDaemon(m);
        id = addRoot(m, m.root);
        doomedId = addRoot(m, doomed);
      } finally {
        await stopDaemon(daemon);
      }

      // The list is configuration in the user's config home; the runtime directory is rebuilt from it.
      const listFile = join(m.config, 'fsmeta', 'roots.json');
      expect(existsSync(listFile)).toBe(true);
      rmSync(doomed, { recursive: true, force: true });

      daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const listed = roots(m);
        expect(listed.map((root) => root.id).sort()).toEqual([id, doomedId].sort());
        const missing = rootById(m, doomedId);
        expect(missing.missing).toBe(true);
        expect(missing.root).toBe(doomed);
        expect(rootById(m, id).missing).toBe(false);

        // The live root still answers on its socket after the restart: the runtime entry was rebuilt.
        const peer = await connect(join(m.runtime, 'roots', `${id}.sock`));
        expectHello(await peer.frame());
        peer.end();
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    60000,
  );

  unixTest(
    'a second daemon on one base is refused, and a killed daemon leaves nothing a restart trips over',
    async () => {
      const m = machine();
      writeFileSync(join(m.root, 'a.txt'), 'one\n');
      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        addRoot(m, m.root);

        const second = Bun.spawnSync([binary, 'daemon', 'start', '--foreground', '--base', m.runtime], {
          cwd: here,
          env: m.env,
          stdout: 'pipe',
          stderr: 'pipe',
        });
        expect(second.exitCode).toBe(4);
        expect(`${second.stdout}${second.stderr}`).toContain('already running');

        // Kill without a shutdown: the claim locks die with the process, the socket file does not.
        daemon.kill('SIGKILL');
        await Promise.race([daemon.exited, Bun.sleep(3000)]);
      } finally {
        await stopDaemon(daemon);
      }

      // The restart has to remove the stale socket and claim before it can bind: that it starts at all is the
      // evidence, and the list it serves is the one the dead daemon wrote.
      const restarted = startDaemon(m);
      try {
        await waitForDaemon(m);
        expect(cli(m, 'daemon', 'status').code).toBe(0);
        expect(roots(m)).toHaveLength(1);
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${restarted.output.text}`);
      } finally {
        await stopDaemon(restarted);
      }
    },
    60000,
  );

  unixTest(
    'retention is enforced by count and by bytes, per root, and removal respects on_remove',
    async () => {
      const m = machine();
      writeFileSync(join(m.root, 'a.txt'), 'one\n');
      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const batches = join(m.root, '.fs-meta', 'batches');

        // Thirty-two generations allowed by count, one byte by budget: the byte ceiling is what bites.
        const id = addRoot(m, m.root, '--mode', 'always', '--keep-batches', '32', '--max-bytes', '1');
        for (let round = 0; round < 3; round += 1) {
          writeFileSync(join(m.root, 'a.txt'), `round ${round}\n`);
          const before = rootById(m, id).head_batch;
          await eventually(
            async () => rootById(m, id).head_batch > before,
            `generation ${round} was never published`,
          );
        }
        await eventually(
          async () => existsSync(batches) && readdirSync(batches).length === 1,
          'the byte ceiling never trimmed the archive to the newest generation',
        );

        // `keep` is the default: removing the root leaves the history alone.
        const kept = cliOk(m, 'root', 'remove', id);
        expect(kept.out).toContain('history keep');
        expect(existsSync(join(m.runtime, 'roots', `${id}.sock`))).toBe(false);
        expect(existsSync(batches)).toBe(true);

        // `delete` removes the generations with the root.
        const id2 = addRoot(m, m.root, '--mode', 'always', '--on-remove', 'delete');
        const before = rootById(m, id2).head_batch;
        writeFileSync(join(m.root, 'a.txt'), 'another\n');
        await eventually(async () => rootById(m, id2).head_batch > before, 'no publish before the delete');
        const removed = cliOk(m, 'root', 'remove', id2);
        expect(removed.out).toContain('history delete');
        expect(existsSync(batches)).toBe(false);
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    60000,
  );

  unixTest(
    'a watching root is driven by events, not by the clock',
    async () => {
      const m = machine();
      writeFileSync(join(m.root, 'a.txt'), 'one\n');
      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const id = addRoot(m, m.root, '--idle', '0');
        const peer = await connect(join(m.runtime, 'roots', `${id}.sock`));
        expectHello(await peer.frame());
        await readBatch(peer);
        await readUntilState(peer, (state) => state.state === 'watching');

        const afterWake = rootById(m, id);
        expect(afterWake.passes).toBe(1);

        // A watcher, not a timer: nothing changing means nothing running. A pass every interval would show up
        // here as dozens of passes.
        await Bun.sleep(1200);
        expect(rootById(m, id).passes).toBe(1);

        // Our own output is never an event: publishing writes `.fs-meta`, and a pass that reacted to its own writes
        // would never stop. A `.git` *entry appearing* is the one git path that does force a pass
        // (`plans/worktrees.md` G33): it is how a directory becomes a nested repository, and waiting for the 60 s
        // safety pass would leave a new worktree unscanned for up to a minute. Events *inside* `.git` stay ignored.
        // The pass finds nothing to publish, so the generation and the published-pass count do not move; the
        // event-pass counter does.
        mkdirSync(join(m.root, '.git'), { recursive: true });
        await eventually(
          async () => rootById(m, id).event_passes === 1,
          'the .git entry did not force a pass',
        );
        writeFileSync(join(m.root, '.git', 'HEAD'), 'ref: refs/heads/main\n');
        await Bun.sleep(400);
        expect(rootById(m, id).event_passes).toBe(1);
        expect(rootById(m, id).passes).toBe(1);

        // A real change is one event, one pass, and `STATE.reason` says a watcher caused it.
        writeFileSync(join(m.root, 'b.txt'), 'two\n');
        const batch = await readBatch(peer);
        expect(batch.entries.map((entry) => entry.name)).toEqual(['b.txt']);
        const watched = await readUntilState(peer, (state) => state.state === 'watching' && state.headBatch === batch.number);
        expect(watched.reason).toBe('watcher');
        await eventually(async () => rootById(m, id).passes === 2, 'the event did not become exactly one pass');
        // The cause split says the same thing the wire does: both extra passes came from events, not from the
        // safety net, and no safety pass has run (the root has been in use the whole time).
        const after = rootById(m, id);
        expect(after.event_passes).toBe(2);
        expect(after.safety_passes).toBe(0);
        peer.end();
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    60000,
  );

  unixTest(
    'a nested root is guarded by its parent, not warned about',
    async () => {
      // R2 (`plans/worktrees.md` § 5): the parent's internal ignore hides the child before it is served. A write
      // inside the child publishes only in the child; the parent keeps describing the same names.
      const m = machine();
      const sub = join(m.root, 'packages', 'a');
      mkdirSync(sub, { recursive: true });
      writeFileSync(join(m.root, 'top.txt'), 'top\n');
      writeFileSync(join(sub, 'one.txt'), 'one\n');

      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const parentId = addRoot(m, m.root, '--mode', 'always', '--idle', '0');
        await eventually(
          () => existsSync(join(m.root, '.fs-meta', 'files.json')),
          'the parent did not publish its first pass',
        );
        // A user's own line is written before the guard exists; every managed-block operation must preserve it.
        const ignorePath = join(m.root, '.fs-meta', 'ignore');
        writeFileSync(ignorePath, 'user-own/\n');

        // The guard is **not gated** by the two switches, even when the child is added with both off.
        const inside = cliOk(
          m, 'root', 'add', sub,
          '--mode', 'always', '--idle', '0',
          '--worktrees', 'off', '--gitwatch', 'off',
        );
        expect(inside.out).toContain('added ');
        expect(inside.out).not.toContain('note:');
        const childId = inside.out.match(/added ([0-9a-f]{8})/)[1];
        expect(childId).toBeDefined();

        expect(readFileSync(ignorePath, 'utf8')).toBe('user-own/\n# fsmeta-managed\npackages/a/\n');
        const parentFiles = readFileSync(join(m.root, '.fs-meta', 'files.txt'), 'utf8');
        expect(parentFiles).toContain('top.txt');
        expect(parentFiles).toContain('packages/');
        expect(parentFiles).not.toContain('packages/a/one.txt');
        expect(parentFiles).not.toContain('packages/a/\n');

        // The child's edit is the child's pass. The parent may see the watcher event, but its pass publishes
        // nothing, so neither its count of names nor its published generation moves (§ 16b, measured).
        const parentBefore = rootById(m, parentId);
        const childBefore = rootById(m, childId);
        writeFileSync(join(sub, 'two.txt'), 'two\n');
        await eventually(
          () => rootById(m, childId).passes > childBefore.passes,
          'the child did not publish the edit',
        );
        const parentAfter = rootById(m, parentId);
        expect(parentAfter.passes).toBe(parentBefore.passes);
        expect(parentAfter.last_pass_files).toBe(parentBefore.last_pass_files);
        expect(rootById(m, childId).last_pass_files).toBeGreaterThan(childBefore.last_pass_files);

        // A parent-local edit passes the parent and leaves the child's trio alone. The parent never writes the
        // child's `.fs-meta`: the generation is the child's own.
        const childGeneration = JSON.parse(readFileSync(join(sub, '.fs-meta', 'files.json'), 'utf8')).generation;
        writeFileSync(join(m.root, 'parent-edit.txt'), 'p\n');
        await eventually(
          () => rootById(m, parentId).passes > parentAfter.passes,
          'the parent did not publish its own edit',
        );
        expect(JSON.parse(readFileSync(join(sub, '.fs-meta', 'files.json'), 'utf8')).generation).toBe(childGeneration);

        // The other direction: a parent added *after* its served children hides each of them before its first pass.
        const outer = join(m.home, 'outer');
        const inner = join(outer, 'inner');
        mkdirSync(inner, { recursive: true });
        writeFileSync(join(inner, 'x.txt'), 'x\n');
        writeFileSync(join(outer, 'outer-top.txt'), 'o\n');
        addRoot(m, inner, '--mode', 'always', '--idle', '0');
        addRoot(m, outer, '--mode', 'always', '--idle', '0');
        await eventually(
          () => existsSync(join(outer, '.fs-meta', 'files.json')),
          'the later parent did not publish its first pass',
        );
        expect(readFileSync(join(outer, '.fs-meta', 'ignore'), 'utf8')).toBe('# fsmeta-managed\ninner/\n');
        expect(readFileSync(join(outer, '.fs-meta', 'files.txt'), 'utf8')).not.toContain('inner/');

        // An `asleep` parent and an `off` parent are both passed once at add time: the guard does not depend on a
        // watcher being armed (`plans/worktrees.md` § 5, G39).
        for (const [name, modeArgs] of [['sleepy', []], ['offroot', ['--mode', 'off']]]) {
          const parent = join(m.home, name);
          const child = join(parent, 'child');
          mkdirSync(child, { recursive: true });
          writeFileSync(join(parent, 'top.txt'), 't\n');
          writeFileSync(join(child, 'inside.txt'), 'i\n');
          addRoot(m, parent, ...modeArgs);
          addRoot(m, child, '--mode', 'always', '--idle', '0');
          await eventually(
            () => existsSync(join(parent, '.fs-meta', 'files.json')),
            `the ${name} parent was not passed when its child was added`,
          );
          expect(readFileSync(join(parent, '.fs-meta', 'ignore'), 'utf8')).toContain('child/');
          expect(readFileSync(join(parent, '.fs-meta', 'files.txt'), 'utf8')).not.toContain('child/');
        }

        // The old warning field is gone; the control reply has no `warning` at all.
        const probe = join(m.root, 'packages', 'c');
        mkdirSync(probe, { recursive: true });
        const reply = await rawControl(
          join(m.runtime, 'daemon.sock'),
          JSON.stringify({ v: 1, cmd: 'root.add', path: probe }),
        );
        expect(reply.ok).toBe(true);
        expect(reply.warning).toBeUndefined();
        expect(readFileSync(ignorePath, 'utf8')).toContain('packages/c/');

        // `root remove` removes the child's line; the parent can describe the subtree again on its next pass.
        cliOk(m, 'root', 'remove', childId);
        expect(readFileSync(ignorePath, 'utf8')).not.toContain('packages/a/');
        writeFileSync(join(m.root, 'after-remove.txt'), 'r\n');
        await eventually(
          () => readFileSync(join(m.root, '.fs-meta', 'files.txt'), 'utf8').includes('packages/a/one.txt'),
          'removing the child did not let the parent describe the subtree again',
        );
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    60000,
  );

  unixTest(
    'a deleted guard block is repaired by the parent pass and at startup',
    async () => {
      // G37: the invariant is the daemon's, not the file's. A hand edit that removes the block is repaired by the
      // parent's next pass, and a hand-edited `roots.json` pair is reconciled at start before any root publishes.
      const m = machine();
      const sub = join(m.root, 'packages', 'a');
      mkdirSync(sub, { recursive: true });
      writeFileSync(join(m.root, 'top.txt'), 'top\n');
      writeFileSync(join(sub, 'one.txt'), 'one\n');
      const ignorePath = join(m.root, '.fs-meta', 'ignore');

      const daemon = startDaemon(m);
      let restarted = null;
      try {
        await waitForDaemon(m);
        const parentId = addRoot(m, m.root, '--mode', 'always', '--idle', '0');
        await eventually(
          () => existsSync(join(m.root, '.fs-meta', 'files.json')),
          'the parent did not publish its first pass',
        );
        addRoot(m, sub, '--mode', 'always', '--idle', '0');
        expect(readFileSync(ignorePath, 'utf8')).toContain('packages/a/');

        // Delete the block, keep a user line, and make the parent pass for an ordinary reason.
        writeFileSync(ignorePath, 'keep-me/\n');
        const before = rootById(m, parentId);
        writeFileSync(join(m.root, 'kick.txt'), 'k\n');
        await eventually(
          () => rootById(m, parentId).passes > before.passes,
          'the parent did not pass after the block was deleted',
        );
        expect(readFileSync(ignorePath, 'utf8')).toBe('keep-me/\n# fsmeta-managed\npackages/a/\n');

        // Restart with the block missing: startup reconciliation writes it before the parent's first pass.
        await stopDaemon(daemon);
        writeFileSync(ignorePath, 'keep-me/\n');
        restarted = startDaemon(m);
        await waitForDaemon(m);
        await eventually(
          () => readFileSync(ignorePath, 'utf8').includes('packages/a/'),
          'startup did not reconcile the guard',
        );
        expect(readFileSync(ignorePath, 'utf8')).toBe('keep-me/\n# fsmeta-managed\npackages/a/\n');
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        if (restarted !== null) await stopDaemon(restarted);
        await stopDaemon(daemon);
      }
    },
    60000,
  );

  unixTest(
    'the guard holds with both switches off',
    async () => {
      // R5: the switches stop worktree handling and git signals; they never stop the nested-root guard.
      const m = machine();
      m.env.FSMETA_WORKTREES = '0';
      const parent = join(m.home, 'plainparent');
      const child = join(parent, 'child');
      mkdirSync(child, { recursive: true });
      writeFileSync(join(parent, 'top.txt'), 't\n');
      writeFileSync(join(child, 'inside.txt'), 'i\n');

      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        addRoot(m, parent);
        addRoot(m, child);
        await eventually(
          () => existsSync(join(parent, '.fs-meta', 'files.json')),
          'the unflagged parent was not passed',
        );
        expect(readFileSync(join(parent, '.fs-meta', 'ignore'), 'utf8')).toContain('child/');
        expect(readFileSync(join(parent, '.fs-meta', 'files.txt'), 'utf8')).not.toContain('child/');
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    60000,
  );

  unixTest(
    'root add refuses when it cannot arrange the guard',
    async () => {
      // R2: refuse (exit 4), never warn-and-continue. A directory named `.fs-meta/ignore` makes the write fail
      // without relying on read-only permissions (which are not portable on this host).
      const m = machine();
      mkdirSync(join(m.root, '.fs-meta', 'ignore'), { recursive: true });
      const sub = join(m.root, 'packages', 'a');
      mkdirSync(sub, { recursive: true });
      writeFileSync(join(m.root, 'top.txt'), 'top\n');
      writeFileSync(join(sub, 'one.txt'), 'one\n');

      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        addRoot(m, m.root, '--mode', 'always', '--idle', '0');
        const refused = cli(m, 'root', 'add', sub);
        expect(refused.code).toBe(4);
        expect(refused.text).toContain('.fs-meta/ignore');
        expect(refused.text).toContain(m.root);
        expect(roots(m).some((root) => root.root === sub)).toBe(false);
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    60000,
  );

  unixTest(
    'a root stuck in a write does not delay another root\'s batches',
    async () => {
      // The rule: a batch belongs to one root, so its latency must not depend on another root's pass. Each root
      // has its own scheduler task; a shared loop over every root would stall here, because the stuck root's
      // replay never returns and the loop would be inside it.
      const m = machine();
      const quiet = join(m.home, 'quiet');
      mkdirSync(quiet, { recursive: true });
      writeFileSync(join(quiet, 'q.txt'), 'q\n');
      // Enough entries that the replay of the first batch overflows a socket buffer several times.
      for (let i = 0; i < 8000; i += 1) writeFileSync(join(m.root, `f${i}.txt`), 'x');

      const daemon = startDaemon(m);
      const stuckClients = [];
      try {
        await waitForDaemon(m);
        const stuckId = addRoot(m, m.root, '--mode', 'always', '--idle', '0');
        const quietId = addRoot(m, quiet, '--mode', 'always', '--idle', '0');

        // The quiet root's own client: this is what must keep receiving.
        const quietPeer = await connect(join(m.runtime, 'roots', `${quietId}.sock`));
        expectHello(await quietPeer.frame());
        await readBatch(quietPeer);
        await readUntilState(quietPeer, (state) => state.state === 'watching');

        // A client that subscribes to the stuck root and then stops reading: it blocks its event loop, so the
        // kernel buffer fills and the daemon's write into it blocks — that root's pass is now stuck.
        const stuckScript = `
          const { connect } = require('node:net');
          const socket = connect(process.argv[1]);
          const hello = Buffer.alloc(32);
          hello.writeUInt16LE(0x01, 0); hello.writeUInt32LE(24, 4); hello.writeUInt16LE(0x0101, 8);
          hello.writeUInt16LE(64, 10); hello.writeUInt8(1, 13); hello.writeBigUInt64LE(1n << 20n, 24);
          const subscribe = Buffer.alloc(16);
          subscribe.writeUInt16LE(0x06, 0); subscribe.writeUInt32LE(8, 4);
          socket.on('connect', () => { socket.write(hello); socket.write(subscribe); });
          const until = Date.now() + 15000;
          while (Date.now() < until) {}
        `;
        const stuckClient = Bun.spawn(
          [process.execPath, '-e', stuckScript, join(m.runtime, 'roots', `${stuckId}.sock`)],
          { cwd: here, stdout: 'pipe', stderr: 'pipe' },
        );
        stuckClients.push(stuckClient);
        await Bun.sleep(800); // let the replay fill the buffer and the write block

        // The stuck root's client has consumed nothing; the quiet root must still publish promptly.
        const started = Date.now();
        writeFileSync(join(quiet, 'next.txt'), 'z');
        const batch = await readBatch(quietPeer, { timeoutMs: 5000 });
        const elapsed = Date.now() - started;
        expect(batch.entries.map((entry) => entry.name)).toEqual(['next.txt']);
        // Generous: the measured pass was ~150 ms. A shared scheduler would not answer before the stuck client
        // let go, which is 15 seconds.
        expect(elapsed).toBeLessThan(3000);

        // `FORMAT.daemon.md` § 4b: a listing over many roots answers even while one root is stuck — it names the
        // root it could not read and marks itself partial, instead of blocking or inventing a state.
        const listedAt = Date.now();
        const listing = JSON.parse(cliOk(m, 'roots', 'list', '--json').out);
        expect(Date.now() - listedAt).toBeLessThan(3000);
        expect(listing.partial).toBe(true);
        const stuckEntry = listing.roots.find((root) => root.id === stuckId);
        expect(stuckEntry.available).toBe(false);
        expect(stuckEntry.reason).toBe('busy');
        expect(stuckEntry.state).toBeUndefined(); // no torn read, not even a plausible-looking one
        expect(stuckEntry.root).toBe(m.root);
        const quietEntry = listing.roots.find((root) => root.id === quietId);
        expect(quietEntry.available).toBe(true);
        expect(quietEntry.state).toBe('watching');

        // A single-root call has no `partial` field to carry a gap, so an expired budget is a refusal.
        const busyStatus = cli(m, 'root', 'status', stuckId);
        expect(busyStatus.code).toBe(4);
        expect(busyStatus.text).toContain('not available yet');

        quietPeer.end();
        for (const child of stuckClients) {
          try { child.kill('SIGKILL'); } catch {}
        }
        stuckClients.length = 0;

        // Once the stuck client is gone, the same listing is complete again.
        await eventually(
          async () => {
            const complete = JSON.parse(cliOk(m, 'roots', 'list', '--json').out);
            const entry = complete.roots.find((root) => root.id === stuckId);
            return complete.partial === false && entry.available === true ? entry : null;
          },
          'the listing never became complete again after the stuck client left',
        );
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        for (const child of stuckClients) {
          try { child.kill('SIGKILL'); } catch {}
        }
        await stopDaemon(daemon);
      }
    },
    90000,
  );

  unixTest(
    'a second subscriber during a wake is served by the same scan, not a second one',
    async () => {
      const m = machine();
      writeFileSync(join(m.root, 'a.txt'), 'one\n');
      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const id = addRoot(m, m.root, '--idle', '200ms');
        const socket = join(m.runtime, 'roots', `${id}.sock`);

        // Both connect before either batch can arrive: the second one subscribes while the root is waking.
        const first = await connect(socket);
        const second = await connect(socket);
        expectHello(await first.frame());
        expectHello(await second.frame());

        const firstBatch = await readBatch(first);
        const secondBatch = await readBatch(second);
        expect(secondBatch.number).toBe(firstBatch.number);
        expect(firstBatch.entries.map((entry) => entry.name)).toEqual(['a.txt']);
        expect(secondBatch.entries.map((entry) => entry.name)).toEqual(['a.txt']);

        const root = await eventually(
          async () => {
            const scanned = rootById(m, id);
            return scanned.state === 'watching' ? scanned : null;
          },
          'the root never reached watching',
        );
        // One wake, one pass: the second subscriber was queued into the scan already running.
        expect(root.wakes).toBe(1);
        expect(root.passes).toBe(1);
        expect(root.clients).toBe(2);

        first.end();
        second.end();
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    60000,
  );

  unixTest(
    'a root that vanishes is reported missing, and recovers when its directory comes back',
    async () => {
      const m = machine();
      writeFileSync(join(m.root, 'a.txt'), 'one\n');
      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const id = addRoot(m, m.root, '--mode', 'always');
        await eventually(async () => rootById(m, id).head_batch >= 1, 'the root never published a first pass');

        // A watched root notices the disappearance on its next pass: missing is reported, the phase moves off.
        rmSync(m.root, { recursive: true, force: true });
        const gone = await eventually(
          async () => {
            const root = rootById(m, id);
            return root?.missing === true ? root : null;
          },
          'the root was never reported missing after its directory disappeared',
        );
        expect(gone.state).toBe('off');
        // Reported, never dropped: the record is the user's.
        expect(gone.root).toBe(m.root);

        // And the same stat brings it back, with the configured mode restored, without a restart.
        mkdirSync(m.root, { recursive: true });
        writeFileSync(join(m.root, 'a.txt'), 'one\n');
        const back = await eventually(
          async () => {
            const root = rootById(m, id);
            return root?.missing === false ? root : null;
          },
          'the root never recovered after its directory came back',
        );
        expect(back.mode).toBe('always');
        await eventually(
          async () => rootById(m, id).state === 'watching',
          'the recovered root did not resume watching in always mode',
        );
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    60000,
  );

  unixTest(
    'removing a root with a live subscriber is refused unless forced',
    async () => {
      const m = machine();
      writeFileSync(join(m.root, 'a.txt'), 'one\n');
      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const id = addRoot(m, m.root);
        const peer = await connect(join(m.runtime, 'roots', `${id}.sock`));
        expectHello(await peer.frame());
        await readBatch(peer);

        const refused = cli(m, 'root', 'remove', id);
        expect(refused.code).toBe(4);
        expect(refused.text).toContain('subscriber');

        const forced = cli(m, 'root', 'remove', id, '--force');
        expect(forced.code).toBe(0);
        expect(rootById(m, id)).toBeUndefined();
        peer.end();
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    60000,
  );
});

describe('the CLI contract: exit codes', () => {
  unixTest('no daemon is exit 3, and a missing root is exit 2', async () => {
    const m = machine();
    // Nothing started: every command that needs the control socket says so with 3.
    for (const args of [
      ['daemon', 'status'],
      ['daemon', 'stop'],
      ['roots', 'list'],
      ['root', 'status', 'a1b2c3d4'],
    ]) {
      const result = cli(m, ...args);
      expect({ args, code: result.code }).toEqual({ args, code: 3 });
    }

    const daemon = startDaemon(m);
    try {
      await waitForDaemon(m);
      const missing = cli(m, 'root', 'status', 'a1b2c3d4');
      expect(missing.code).toBe(2);
      expect(missing.text).toContain('no such root');

      const addMissing = cli(m, 'root', 'add', join(m.home, 'does-not-exist'));
      expect(addMissing.code).toBe(2);
      expect(addMissing.text).toContain('no such directory');

      expect(cli(m, 'daemon', 'stop').code).toBe(0);
      // And after a polite stop, the status command is back to 3.
      await eventually(async () => cli(m, 'daemon', 'status').code === 3, 'the daemon never stopped');
    } finally {
      await stopDaemon(daemon);
    }
  }, 60000);

  unixTest(
    'a control request from another protocol version is refused with 5',
    async () => {
      const m = machine();
      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const reply = await rawControl(join(m.runtime, 'daemon.sock'), '{"v":2,"cmd":"status"}');
        expect(reply.ok).toBe(false);
        expect(reply.code).toBe(5);
        expect(reply.message).toContain('version');
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    60000,
  );
});

// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
// Git-aware watching (`plans/worktrees.md` § 5b–§ 5d, M3)
//
// These drive a **real** `git` in `.tmp/`. The plan's criterion is about a real checkout, and hand-written `.git`
// state would only confirm what the test already believes; the host's git is probed once and the cases skip with the
// reason when it is missing (the classification, the latch predicate and the refcount are unit-tested in
// `src/daemon/gitwatch.zig`, which needs no git at all).
// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

const gitVersion = (() => {
  try {
    const probe = Bun.spawnSync(['git', '--version'], { stdout: 'pipe', stderr: 'pipe' });
    return probe.exitCode === 0 ? probe.stdout.toString().trim() : null;
  } catch {
    return null;
  }
})();
const GIT_REASON =
  'this host has no `git` on PATH: the git-watch cases need a real repository, and hand-written `.git` state is not a checkout';
const gitTest =
  gitVersion !== null && afUnixAvailable
    ? test
    : (name, fn) => test.skip(`${name} [skipped: ${gitVersion === null ? GIT_REASON : AF_UNIX_REASON}]`, fn);

/** Run git and accept a non-zero exit (a conflicting merge is an expected failure, not a test error). */
function gitTry(cwd, ...args) {
  const result = Bun.spawnSync(['git', ...args], {
    cwd,
    env: {
      ...process.env,
      GIT_AUTHOR_NAME: 'fsmeta test',
      GIT_AUTHOR_EMAIL: 'test@fsmeta.invalid',
      GIT_COMMITTER_NAME: 'fsmeta test',
      GIT_COMMITTER_EMAIL: 'test@fsmeta.invalid',
      GIT_CONFIG_NOSYSTEM: '1',
      GIT_TERMINAL_PROMPT: '0',
    },
    stdout: 'pipe',
    stderr: 'pipe',
  });
  return { code: result.exitCode, out: result.stdout.toString(), text: `${result.stdout}${result.stderr}` };
}

/** Run git and require success. */
function git(cwd, ...args) {
  const result = gitTry(cwd, ...args);
  if (result.code !== 0) throw new Error(`git ${args.join(' ')} exited ${result.code} in ${cwd}:\n${result.text}`);
  return result.out;
}

/** A repository with one commit on `main` and a clean tree. */
function makeRepo(dir) {
  mkdirSync(dir, { recursive: true });
  git(dir, 'init', '-q');
  git(dir, 'checkout', '-q', '-b', 'main');
  writeFileSync(join(dir, 'a.txt'), 'one\n');
  git(dir, 'add', 'a.txt');
  git(dir, 'commit', '-q', '-m', 'one');
}

/** A branch whose content differs from `main` by one file, so a checkout really rewrites the tree. */
function makeFeatureBranch(dir) {
  git(dir, 'checkout', '-q', '-b', 'feature');
  writeFileSync(join(dir, 'b.txt'), 'feature only\n');
  git(dir, 'add', 'b.txt');
  git(dir, 'commit', '-q', '-m', 'feature');
  git(dir, 'checkout', '-q', 'main');
}

/** One root's `root status --json`, parsed. */
function rootStatusOf(m, id) {
  return JSON.parse(cliOk(m, 'root', 'status', id, '--json').out).root;
}

/** One root's log file, `<base>/logs/<id>.log`. */
async function rootLogText(m, id) {
  return Bun.file(join(m.runtime, 'logs', `${id}.log`)).text();
}

/** Read frames until `quietMs` passes with nothing arriving. */
async function drainFrames(peer, quietMs = 400) {
  while (await peer.maybeFrame(quietMs)) {}
}

/**
 * Assert that no batch arrives within `timeoutMs`. `STATE` frames (a publish announces its transition between
 * batches) and `GIT_EVENT` frames (a start or finish around the pass) are expected and skipped; a second
 * `START_BATCH` is the failure.
 */
async function expectNoBatch(peer, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const frame = await peer.maybeFrame(Math.max(50, deadline - Date.now()));
    if (!frame) return;
    expect([KIND.STATE, KIND.GIT_EVENT]).toContain(frame.kind);
  }
}

/** How many times the daemon printed that it armed a metadata watch (one per common dir, never two for one repo). */
function armedCount(text) {
  return (text.match(/git metadata watch armed for/g) ?? []).length;
}

describe('git-aware watching, behind the gitwatch flag', () => {
  gitTest(
    'a real checkout publishes one batch, and root status reports the branch it landed on',
    async () => {
      const m = machine();
      const repo = join(m.home, 'repo');
      makeRepo(repo);
      makeFeatureBranch(repo);

      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const id = addRoot(m, repo, '--mode', 'always');
        const socket = join(m.runtime, 'roots', `${id}.sock`);

        // The metadata arm is on, and the branch was read from `$GIT_DIR/HEAD` without running git.
        await eventually(async () => (await rootLogText(m, id)).includes('git: metadata watch for'), 'the root never armed its metadata watch');
        const initial = rootStatusOf(m, id);
        expect(initial.head).toBe('main');
        expect(initial.detached).toBe(false);
        expect(initial.in_progress).toBe('');

        const peer = await connect(socket);
        expectHello(await peer.frame());
        await readUntilState(peer, (state) => state.state === 'watching');
        await drainFrames(peer); // the wake batch and its replay are history, not the checkout
        const before = rootById(m, id);

        // A real checkout: moving to `feature` adds `b.txt` to the tree.
        git(repo, 'checkout', '-q', 'feature');
        const batch = await readBatch(peer);
        expect(batch.number).toBe(before.head_batch + 1);
        expect(batch.entries.map((entry) => entry.name)).toEqual(['b.txt']);
        expect(batch.entries[0].kind).toBe('added');

        // One checkout, one batch: a second batch would be a mid-write pass or a duplicated burst.
        await expectNoBatch(peer, 1500);
        expect(rootById(m, id).head_batch).toBe(batch.number);
        expect(rootStatusOf(m, id).head).toBe('feature');

        // And back: the branch switch is one batch again, and the git state follows it.
        git(repo, 'checkout', '-q', 'main');
        const back = await readBatch(peer);
        expect(back.number).toBe(batch.number + 1);
        expect(back.entries.map((entry) => entry.name)).toEqual(['b.txt']);
        expect(back.entries[0].kind).toBe('deleted');
        await expectNoBatch(peer, 1500);
        expect(rootStatusOf(m, id).head).toBe('main');
        peer.end();
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    90000,
  );

  gitTest(
    'a commit in one worktree does not pass its sibling root, and a ref-only update passes neither',
    async () => {
      const m = machine();
      const repo = join(m.home, 'repo');
      makeRepo(repo);
      const wt = join(m.home, 'wt');
      git(repo, 'worktree', 'add', '-q', '-b', 'wtbranch', wt);

      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const mainId = addRoot(m, repo, '--mode', 'always');
        const wtId = addRoot(m, wt, '--mode', 'always');
        // Both roots are `always`, so their wake passes settle on their own; let those finish first.
        await Bun.sleep(800);
        const mainBefore = rootById(m, mainId);
        const wtBefore = rootById(m, wtId);

        // A commit with no file change: the only metadata that moves is a `refs/` update (repo-wide) and the
        // worktree's own `logs/HEAD` (tree-changing for that root, and for nobody else).
        git(wt, 'commit', '-q', '--allow-empty', '-m', 'empty');
        await eventually(
          async () => rootById(m, wtId).event_passes > wtBefore.event_passes,
          'the worktree root never passed after its own HEAD moved',
        );
        await Bun.sleep(600);
        const mainAfter = rootById(m, mainId);
        expect(mainAfter.event_passes).toBe(mainBefore.event_passes);
        expect(mainAfter.head_batch).toBe(mainBefore.head_batch);

        // A ref-only update is the shape of a fetch: `git update-ref` writes `refs/heads/moved.lock`, renames it over
        // the ref, and touches `logs/refs`. Repo-wide, so it passes neither root — and the ref lock is not a latch,
        // because a shared `refs/**/*.lock` must never block a sibling's pass (§ 5b).
        const beforeRef = { main: rootById(m, mainId), wt: rootById(m, wtId) };
        git(repo, 'update-ref', 'refs/heads/moved', 'HEAD');
        await Bun.sleep(900);
        expect(rootById(m, mainId).event_passes).toBe(beforeRef.main.event_passes);
        expect(rootById(m, wtId).event_passes).toBe(beforeRef.wt.event_passes);
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    90000,
  );

  gitTest(
    'with gitwatch off the metadata watch is never armed and a HEAD-only change is no pass at all',
    async () => {
      const m = machine();
      const repo = join(m.home, 'repo');
      makeRepo(repo);
      makeFeatureBranch(repo);
      // A branch with identical content: switching to it changes HEAD and nothing in the tree.
      git(repo, 'branch', 'twin', 'main');

      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const id = addRoot(m, repo, '--mode', 'always', '--gitwatch', 'off');
        await Bun.sleep(700);

        // No git state is reported, and nothing was resolved: the switch means the metadata is never read.
        const status = rootStatusOf(m, id);
        expect(status.head).toBe('');
        expect(status.detached).toBe(false);
        expect(status.in_progress).toBe('');
        const log = await rootLogText(m, id);
        expect(log).not.toContain('git:');

        // A HEAD-only checkout would be a git pass with the flag on. With it off there is no pass and no batch: the
        // tree did not change, so the only event source that could have produced one is switched off.
        const before = rootById(m, id);
        git(repo, 'checkout', '-q', 'twin');
        expect(rootById(m, id).head_batch).toBe(before.head_batch);
        expect(rootById(m, id).event_passes).toBe(before.event_passes);
        expect(rootById(m, id).passes).toBe(before.passes);

        // The ordinary working-tree burst is still exactly one pass — not one for the files and one for HEAD.
        const beforeBurst = rootById(m, id);
        git(repo, 'checkout', '-q', 'feature');
        await eventually(async () => rootById(m, id).head_batch > beforeBurst.head_batch, 'the working-tree burst never published');
        await Bun.sleep(700);
        expect(rootById(m, id).event_passes).toBe(beforeBurst.event_passes + 1);
        expect(rootById(m, id).head_batch).toBe(beforeBurst.head_batch + 1);
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    90000,
  );

  gitTest(
    'a lock in the worktree git dir defers the pass, and the poll resumes it',
    async () => {
      const m = machine();
      const repo = join(m.home, 'repo');
      makeRepo(repo);
      const wt = join(m.home, 'wt');
      git(repo, 'worktree', 'add', '-q', '-b', 'wtbranch', wt);

      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        // The *worktree* root: its `$GIT_DIR` is `<repo>/.git/worktrees/wt`, a directory no tree watcher covers.
        const id = addRoot(m, wt, '--mode', 'always');
        await Bun.sleep(800);
        const gitDir = git(wt, 'rev-parse', '--absolute-git-dir').trim();
        const before = rootById(m, id);

        // Exactly the file git creates while it writes the index. Creating it is not a fake checkout: the case is the
        // latch, and the checkout itself is the test above.
        writeFileSync(join(gitDir, 'index.lock'), '');
        writeFileSync(join(wt, 'deferred.txt'), 'x\n');
        await Bun.sleep(1000);
        expect(rootById(m, id).head_batch).toBe(before.head_batch);
        expect(rootById(m, id).event_passes).toBe(before.event_passes);

        // Nothing watches that directory for a delete event (a linked worktree's `.git` is a file outside the tree),
        // so only the poll can lift the latch — the prototype's documented bug is that a delete event was the only
        // way it ever cleared.
        rmSync(join(gitDir, 'index.lock'), { force: true });
        await eventually(
          async () => rootById(m, id).head_batch > before.head_batch,
          'the deferred pass never ran after the lock was removed',
        );
        expect(rootById(m, id).head_batch).toBe(before.head_batch + 1);
        expect(rootById(m, id).last_pass_files).toBeGreaterThanOrEqual(2); // a.txt and deferred.txt

        // A shared ref lock is not this root's latch: a working-tree change must still publish while it exists.
        const sharedLock = join(repo, '.git', 'refs', 'heads', 'held.lock');
        writeFileSync(sharedLock, '');
        const beforeShared = rootById(m, id);
        writeFileSync(join(wt, 'still.txt'), 'y\n');
        await eventually(
          async () => rootById(m, id).head_batch > beforeShared.head_batch,
          'a shared refs/heads/*.lock blocked this root\'s pass',
        );
        rmSync(sharedLock, { force: true });
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    90000,
  );

  gitTest(
    'one metadata arm per repository: adding two roots arms it once, removing the last releases it',
    async () => {
      const m = machine();
      const repo = join(m.home, 'repo');
      makeRepo(repo);
      const wt = join(m.home, 'wt');
      git(repo, 'worktree', 'add', '-q', '-b', 'wtbranch', wt);

      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const mainId = addRoot(m, repo, '--mode', 'always');
        const wtId = addRoot(m, wt, '--mode', 'always');

        // The two roots resolve to one common dir: the first arms it, the second joins it.
        await eventually(async () => (await rootLogText(m, wtId)).includes('git: metadata watch for'), 'the worktree root never armed or joined the arm');
        expect(await rootLogText(m, mainId)).toContain('(1 root(s) of this repository)');
        expect(await rootLogText(m, wtId)).toContain('(2 root(s) of this repository)');
        expect(armedCount(daemon.output.text)).toBe(1);

        // Removing one leaves the arm (and the watcher) in place: `root remove` is a root's lifetime, not a repo's.
        cliOk(m, 'root', 'remove', wtId, '--force');
        await eventually(async () => !existsSync(join(m.runtime, 'roots', `${wtId}.sock`)), 'the removed root kept its socket');
        expect(daemon.output.text.match(/git metadata watch released/g) ?? []).toHaveLength(0);

        // Removing the last root disarms it, exactly once.
        cliOk(m, 'root', 'remove', mainId, '--force');
        await eventually(
          async () => (daemon.output.text.match(/git metadata watch released/g) ?? []).length === 1,
          'the last root of the repository did not release the metadata watch',
        );
        expect(armedCount(daemon.output.text)).toBe(1);
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    90000,
  );

  gitTest(
    'root status reports a detached HEAD and a merge in progress',
    async () => {
      const m = machine();
      const repo = join(m.home, 'repo');
      makeRepo(repo);
      git(repo, 'checkout', '-q', '-b', 'other');
      writeFileSync(join(repo, 'a.txt'), 'other\n');
      git(repo, 'commit', '-q', '-am', 'other');
      // The branches must diverge, or the merge is a fast-forward and leaves no `MERGE_HEAD` to report.
      git(repo, 'checkout', '-q', 'main');
      writeFileSync(join(repo, 'a.txt'), 'main changed\n');
      git(repo, 'commit', '-q', '-am', 'main changed');

      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const id = addRoot(m, repo, '--mode', 'always');

        git(repo, 'checkout', '-q', '--detach');
        const detached = await eventually(async () => {
          const status = rootStatusOf(m, id);
          return status.detached ? status : null;
        }, 'the root never reported a detached HEAD');
        expect(detached.head.startsWith('detached:')).toBe(true);
        expect(detached.in_progress).toBe('');

        // A conflicting merge leaves `MERGE_HEAD`: the state a consumer asks about, not an error to hide.
        git(repo, 'checkout', '-q', 'main');
        gitTry(repo, 'merge', 'other');
        const merged = await eventually(async () => {
          const status = rootStatusOf(m, id);
          return status.in_progress === 'merge' ? status : null;
        }, 'the root never reported the merge in progress');
        expect(merged.head).toBe('main');
        expect(merged.detached).toBe(false);
        gitTry(repo, 'merge', '--abort');
        const aborted = await eventually(async () => {
          const status = rootStatusOf(m, id);
          return status.in_progress === '' ? status : null;
        }, 'the root never cleared the merge state after the abort');
        expect(aborted.head).toBe('main');
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    90000,
  );
});

// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
// `GIT_EVENT` on the wire (`plans/worktrees.md` § 5d, M4)
//
// The daemon's second added frame, kind `0x0A` at protocol `0x0102`. These tests read the real socket and assert the
// ordering contract itself — the finish only after the batch that reflects it has gone to *that client* — rather
// than a timing that happens to hold.
// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

/** A path as git writes it in a `gitdir` file: forward slashes, and case-insensitive on Windows. */
function samePathText(a, b) {
  const normal = (value) => (process.platform === 'win32' ? value.replaceAll('\\', '/').toLowerCase() : value);
  return normal(a) === normal(b);
}

/**
 * Read frames until a `GIT_EVENT` satisfies `predicate`, recording the interleaving so the ordering can be asserted
 * instead of assumed. A `GIT_EVENT` inside a batch fails here: the transaction would be broken.
 */
async function readUntilGitEvent(peer, predicate, timeoutMs = 12000) {
  const log = [];
  const batches = [];
  let openBatch = null;
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const frame = await peer.frame(Math.max(250, deadline - Date.now()));
    switch (frame.kind) {
      case KIND.START_BATCH: {
        const number = Number(frame.payload.readBigUInt64LE(0));
        openBatch = number;
        batches.push({ number, ended: false });
        log.push(`START_BATCH:${number}`);
        break;
      }
      case KIND.CHANGE_ENTRY:
        expect(openBatch).not.toBeNull();
        log.push('CHANGE_ENTRY');
        break;
      case KIND.END_BATCH: {
        const number = Number(frame.payload.readBigUInt64LE(0));
        expect(openBatch).toBe(number);
        openBatch = null;
        const batch = batches.find((candidate) => candidate.number === number && !candidate.ended);
        if (batch) batch.ended = true;
        log.push(`END_BATCH:${number}`);
        break;
      }
      case KIND.STATE:
        expect(openBatch).toBeNull();
        log.push('STATE');
        break;
      case KIND.GIT_EVENT: {
        expect(openBatch).toBeNull();
        const event = parseGitEvent(frame);
        log.push(`GIT_EVENT:${event.phase}:${event.kind}`);
        if (predicate(event)) return { event, log, batches };
        break;
      }
      default:
        throw new Error(`unexpected frame 0x${frame.kind.toString(16)}`);
    }
  }
  throw new Error(`no matching GIT_EVENT; saw ${log.join(', ')}`);
}

/** Every event (and batch, for the "no batch" assertions) that arrives within `ms`; tolerates STATE frames. */
async function collectFrames(peer, ms) {
  const events = [];
  const batches = [];
  let inBatch = false;
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    const frame = await peer.maybeFrame(Math.max(50, deadline - Date.now()));
    if (!frame) break;
    if (frame.kind === KIND.START_BATCH) {
      inBatch = true;
      batches.push(Number(frame.payload.readBigUInt64LE(0)));
      continue;
    }
    if (frame.kind === KIND.END_BATCH) {
      inBatch = false;
      continue;
    }
    if (frame.kind === KIND.CHANGE_ENTRY) {
      expect(inBatch).toBe(true);
      continue;
    }
    if (frame.kind === KIND.STATE) continue;
    if (frame.kind === KIND.GIT_EVENT) {
      expect(inBatch).toBe(false);
      events.push(parseGitEvent(frame));
      continue;
    }
    throw new Error(`unexpected frame 0x${frame.kind.toString(16)}`);
  }
  return { events, batches };
}

/** Assert no `GIT_EVENT` arrives within `ms`; STATE frames and a batch are still tolerated and reported. */
async function expectNoGitEvent(peer, ms) {
  const { events } = await collectFrames(peer, ms);
  expect(events).toEqual([]);
}

describe('git events on the wire, behind the gitwatch flag', () => {
  gitTest(
    'a checkout finishes only after the batch that reflects it, and the batch carries the file',
    async () => {
      const m = machine();
      const repo = join(m.home, 'repo');
      makeRepo(repo);
      makeFeatureBranch(repo);

      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const id = addRoot(m, repo, '--mode', 'always');
        const peer = await connect(join(m.runtime, 'roots', `${id}.sock`));
        expectHello(await peer.frame());
        await readUntilState(peer, (state) => state.state === 'watching');
        await drainFrames(peer);
        const before = rootStatusOf(m, id).head_batch;

        git(repo, 'checkout', '-q', 'feature');
        const { event, log, batches } = await readUntilGitEvent(peer, (candidate) => candidate.phase === 'finish' && candidate.kind === 'branch');

        // The frame is 20 bytes of the documented layout, sent from the metadata timeline.
        expect(event.source).toBe('metadata');
        expect(event.status).toBe('ok');
        expect(event.headBatch).toBe(before + 1);
        expect(event.atMs).toBeGreaterThan(1_600_000_000_000);

        // The pass that reflected the checkout published one batch, and the finish came after its END_BATCH.
        const ended = batches.filter((batch) => batch.ended);
        expect(ended).toHaveLength(1);
        expect(ended[0].number).toBe(before + 1);
        const finishIndex = log.indexOf('GIT_EVENT:finish:branch');
        expect(finishIndex).toBeGreaterThan(log.lastIndexOf(`END_BATCH:${ended[0].number}`));
        expect(log.indexOf(`START_BATCH:${ended[0].number}`)).toBeLessThan(finishIndex);

        // Nothing else publishes: one checkout, one batch, one finish.
        await expectNoBatch(peer, 1200);
        expect(rootStatusOf(m, id).head).toBe('feature');
        const counters = rootStatusOf(m, id);
        expect(counters.git_events).toBeGreaterThanOrEqual(2); // at least a start and a finish
        expect(counters.git_passes).toBeGreaterThanOrEqual(1);
        peer.end();
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    90000,
  );

  gitTest(
    'a HEAD-only change finishes after a pass that published nothing',
    async () => {
      const m = machine();
      const repo = join(m.home, 'repo');
      makeRepo(repo);
      git(repo, 'branch', 'twin', 'main');

      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const id = addRoot(m, repo, '--mode', 'always');
        const peer = await connect(join(m.runtime, 'roots', `${id}.sock`));
        expectHello(await peer.frame());
        await readUntilState(peer, (state) => state.state === 'watching');
        await drainFrames(peer);
        const before = rootStatusOf(m, id).head_batch;

        git(repo, 'checkout', '-q', 'twin');
        const { event, batches } = await readUntilGitEvent(peer, (candidate) => candidate.phase === 'finish' && candidate.kind === 'branch');
        // § 5d rule 3: the guarantee is "never before the pass", not "always a batch".
        expect(batches.filter((batch) => batch.ended)).toHaveLength(0);
        expect(event.headBatch).toBe(before);
        expect(rootStatusOf(m, id).head).toBe('twin');
        peer.end();
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    90000,
  );

  gitTest(
    'with gitwatch off no GIT_EVENT is ever sent, and the batch is the only frame that changes',
    async () => {
      const m = machine();
      const repo = join(m.home, 'repo');
      makeRepo(repo);
      makeFeatureBranch(repo);
      git(repo, 'branch', 'twin', 'main');

      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const id = addRoot(m, repo, '--mode', 'always', '--gitwatch', 'off');
        const peer = await connect(join(m.runtime, 'roots', `${id}.sock`));
        expectHello(await peer.frame());
        await readUntilState(peer, (state) => state.state === 'watching');
        await drainFrames(peer);

        // A HEAD-only checkout is nothing at all with the flag off: no pass, no batch, no event.
        git(repo, 'checkout', '-q', 'twin');
        const quiet = await collectFrames(peer, 1000);
        expect(quiet.events).toEqual([]);
        expect(quiet.batches).toEqual([]);

        // A content checkout is the ordinary working-tree burst: one batch, and still no event.
        git(repo, 'checkout', '-q', 'feature');
        const batch = await readBatch(peer);
        expect(batch.entries.map((entry) => entry.name)).toEqual(['b.txt']);
        expect(batch.events).toEqual([]);
        await expectNoGitEvent(peer, 1200);
        const status = rootStatusOf(m, id);
        expect(status.git_events).toBe(0);
        expect(status.git_passes).toBe(0);
        peer.end();
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    90000,
  );

  gitTest(
    'a worktree appearing and leaving is an event for every served root of the repository',
    async () => {
      const m = machine();
      const repo = join(m.home, 'repo');
      makeRepo(repo);
      const first = join(m.home, 'wt-one');
      git(repo, 'worktree', 'add', '-q', '-b', 'wt-one', first);

      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const mainId = addRoot(m, repo, '--mode', 'always');
        const firstId = addRoot(m, first, '--mode', 'always');
        const mainPeer = await connect(join(m.runtime, 'roots', `${mainId}.sock`));
        expectHello(await mainPeer.frame());
        await readUntilState(mainPeer, (state) => state.state === 'watching');
        await drainFrames(mainPeer);
        const firstPeer = await connect(join(m.runtime, 'roots', `${firstId}.sock`));
        expectHello(await firstPeer.frame());
        await readUntilState(firstPeer, (state) => state.state === 'watching');
        await drainFrames(firstPeer);

        // `git worktree add` has no hook at all for the *add itself* (the M4 spike: `worktree move`/`remove` fire
        // nothing), so this is the metadata timeline: the `worktrees/<id>` directory appears, its `gitdir` names the
        // worktree, and the finish is the metadata heuristic.
        const added = join(m.home, 'wt-two');
        git(repo, 'worktree', 'add', '-q', '-b', 'wt-two', added);
        const [mainEvent, firstEvent] = await Promise.all([
          readUntilGitEvent(mainPeer, (candidate) => candidate.kind === 'worktree' && candidate.phase === 'finish'),
          readUntilGitEvent(firstPeer, (candidate) => candidate.kind === 'worktree' && candidate.phase === 'finish'),
        ]);
        expect(samePathText(mainEvent.event.path, added)).toBe(true);
        expect(samePathText(firstEvent.event.path, added)).toBe(true);
        // § 5d: a worktree event is about the repository, so its `head_batch` is the receiving root's own head.
        expect(mainEvent.event.headBatch).toBe(rootStatusOf(m, mainId).head_batch);
        expect(firstEvent.event.headBatch).toBe(rootStatusOf(m, firstId).head_batch);

        // A removal is a single finish whose path is no longer knowable: `path_len = 0`.
        git(repo, 'worktree', 'remove', '--force', added);
        const [mainGone, firstGone] = await Promise.all([
          readUntilGitEvent(mainPeer, (candidate) => candidate.kind === 'worktree' && candidate.phase === 'finish' && candidate.path === ''),
          readUntilGitEvent(firstPeer, (candidate) => candidate.kind === 'worktree' && candidate.phase === 'finish' && candidate.path === ''),
        ]);
        expect(mainGone.event.path).toBe('');
        expect(firstGone.event.path).toBe('');
        mainPeer.end();
        firstPeer.end();
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    120000,
  );

  gitTest(
    'a burst of ref updates is one commit event, not one per ref',
    async () => {
      const m = machine();
      const repo = join(m.home, 'repo');
      makeRepo(repo);

      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const id = addRoot(m, repo, '--mode', 'always');
        const peer = await connect(join(m.runtime, 'roots', `${id}.sock`));
        expectHello(await peer.frame());
        await readUntilState(peer, (state) => state.state === 'watching');
        await drainFrames(peer);

        // One process, five refs: the shape of a fetch or a scripted loop. The names are branches, so the kind is
        // `commit`; coalescing per kind means one frame, not five.
        const refs = ['a', 'b', 'c', 'd', 'e'].map((name) => `create refs/heads/burst-${name} HEAD`);
        const update = Bun.spawnSync(['git', 'update-ref', '--stdin'], {
          cwd: repo,
          env: { ...process.env, GIT_CONFIG_NOSYSTEM: '1' },
          stdin: Buffer.from(`${refs.join('\n')}\n`),
          stdout: 'pipe',
          stderr: 'pipe',
        });
        expect(update.exitCode).toBe(0);

        const { events } = await collectFrames(peer, 1500);
        const commits = events.filter((event) => event.kind === 'commit');
        expect(commits).toHaveLength(1);
        expect(commits[0].phase).toBe('finish');
        // A repo-wide event has no pass of its own to wait for, so its `head_batch` is the head it already had.
        expect(commits[0].headBatch).toBe(rootStatusOf(m, id).head_batch);
        peer.end();
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    90000,
  );

  gitTest(
    'a worktree added to a served repository is seeded, and worktrees=off falls back to a cold scan',
    async () => {
      // R4 / § 5e: the base generation is copied, a genesis batch 1 is written, and the normal pass publishes the
      // branch difference as generation 2. `last_pass_hashed` is the measurement: the seed hashes 0 files, the
      // `worktrees=off` worktree hashes the whole tree.
      const m = machine();
      const repo = join(m.home, 'repo');
      makeRepo(repo);
      for (let i = 0; i < 6; i += 1) writeFileSync(join(repo, `f${i}.txt`), `f${i}\n`);
      git(repo, 'add', '-A');
      git(repo, 'commit', '-q', '-m', 'the base files');
      const seededRoot = join(m.home, 'wt-seeded');
      const coldRoot = join(m.home, 'wt-cold');
      git(repo, 'worktree', 'add', '-q', '-b', 'seedbranch', seededRoot);
      git(repo, 'worktree', 'add', '-q', '-b', 'coldbranch', coldRoot);

      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const repoId = addRoot(m, repo, '--mode', 'always');
        await eventually(
          () => existsSync(join(repo, '.fs-meta', 'files.json')),
          'the base root did not publish its first pass',
        );
        const baseFiles = readFileSync(join(repo, '.fs-meta', 'files.txt'), 'utf8').split('\n').filter(Boolean).length;
        expect(rootById(m, repoId)).toBeDefined();
        await Bun.sleep(200); // let the base pass release its lock: the seed snapshot must be the settled state
        writeFileSync(join(seededRoot, 'branch.txt'), 'branch only\n');

        const seededId = addRoot(m, seededRoot, '--mode', 'always');
        await eventually(
          () => existsSync(join(seededRoot, '.fs-meta', 'batches', '00000001', 'files.json')),
          'the seed did not write a genesis batch',
        );
        await eventually(
          () => rootStatusOf(m, seededId).head_batch >= 2,
          'the seeded root did not publish its diff',
        );
        const seeded = rootStatusOf(m, seededId);
        expect(seeded.last_pass_hashed).toBeLessThanOrEqual(1);
        expect(JSON.parse(readFileSync(join(seededRoot, '.fs-meta', 'files.json'), 'utf8')).generation).toBeGreaterThanOrEqual(2);

        // The same checkout with the feature off is an ordinary root: no genesis, a cold hash of every file.
        const coldId = addRoot(m, coldRoot, '--mode', 'always', '--worktrees', 'off');
        await eventually(
          () => {
            const status = rootStatusOf(m, coldId);
            return status.head_batch >= 1 && status.last_pass_hashed > 0 ? status : null;
          },
          'the worktrees=off root did not pass',
        );
        const cold = rootStatusOf(m, coldId);
        expect(JSON.parse(readFileSync(join(coldRoot, '.fs-meta', 'files.json'), 'utf8')).generation).toBe(1);
        expect(cold.last_pass_hashed).toBeGreaterThanOrEqual(baseFiles - 1);
        expect(seeded.last_pass_hashed).toBeLessThan(cold.last_pass_hashed);
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    90000,
  );

  gitTest(
    'a worktree discovered live is adopted when on-worktree serve is set, and ignored by default',
    async () => {
      // The adoption policy belongs to the discovering root. `serve` adds the worktree as a root (seeded); the
      // default `ignore` reports it and adds nothing. The parent's trio already excludes it by the boundary rule.
      const m = machine();
      const repo = join(m.home, 'repo');
      makeRepo(repo);
      writeFileSync(join(repo, 'base-only.txt'), 'base\n');
      git(repo, 'add', '-A');
      git(repo, 'commit', '-q', '-m', 'base');
      const adopted = join(m.home, 'auto-wt');
      const ignored = join(m.home, 'ignored-wt');
      git(repo, 'worktree', 'add', '-q', '-b', 'autobranch', adopted);
      git(repo, 'worktree', 'add', '-q', '-b', 'ignoredbranch', ignored);

      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        addRoot(m, repo, '--mode', 'always', '--on-worktree', 'serve');
        await eventually(
          () => existsSync(join(repo, '.fs-meta', 'files.json')),
          'the serving root did not publish',
        );
        await Bun.sleep(200);

        // Make the adoption visible: create the worktree while the metadata watch is armed.
        const dynamic = join(m.home, 'dynamic-wt');
        git(repo, 'worktree', 'add', '-q', '-b', 'dynamicbranch', dynamic);
        const found = await eventually(
          () => roots(m).find((candidate) => candidate.root === dynamic) ?? null,
          'the discovered worktree was not adopted',
        );
        await eventually(
          () => existsSync(join(dynamic, '.fs-meta', 'batches', '00000001', 'files.json')),
          'the adopted worktree was not seeded',
        );
        writeFileSync(join(dynamic, 'dynamic-only.txt'), 'dynamic\n');
        cliOk(m, 'root', 'wake', found.id);
        await eventually(
          () => rootStatusOf(m, found.id).head_batch >= 2,
          'the adopted worktree did not publish its diff',
        );
        expect(rootStatusOf(m, found.id).last_pass_hashed).toBeLessThanOrEqual(1);

        // A second repository serves with the default `ignore`: its worktree is reported and not added.
        const quietRepo = join(m.home, 'quiet-repo');
        makeRepo(quietRepo);
        addRoot(m, quietRepo, '--mode', 'always');
        const quietWt = join(m.home, 'quiet-wt');
        git(quietRepo, 'worktree', 'add', '-q', '-b', 'quietbranch', quietWt);
        await Bun.sleep(1500);
        expect(roots(m).some((candidate) => candidate.root === quietWt)).toBe(false);

        // `worktrees=off` is stronger: it does not even arm the discovery, even with `serve` set.
        const offRepo = join(m.home, 'off-repo');
        makeRepo(offRepo);
        addRoot(m, offRepo, '--mode', 'always', '--worktrees', 'off', '--on-worktree', 'serve');
        const offWt = join(m.home, 'off-wt');
        git(offRepo, 'worktree', 'add', '-q', '-b', 'offbranch', offWt);
        await Bun.sleep(1200);
        expect(roots(m).some((candidate) => candidate.root === offWt)).toBe(false);

        // With `gitwatch` off there is no metadata event, but the pass that sees the new boundary still adopts it
        // when the discovering root says `serve` (§ 5, G43). The worktree lives inside the parent here, so this also
        // exercises seed-before-guard.
        const passRepo = join(m.home, 'pass-repo');
        makeRepo(passRepo);
        addRoot(m, passRepo, '--mode', 'always', '--gitwatch', 'off', '--on-worktree', 'serve');
        const nestedWt = join(passRepo, 'nested-wt');
        git(passRepo, 'worktree', 'add', '-q', '-b', 'nestedbranch', nestedWt);
        const passAdopted = await eventually(
          () => roots(m).find((candidate) => candidate.root === nestedWt) ?? null,
          'the pass-time discovery did not adopt the worktree',
        );
        await eventually(
          () => existsSync(join(nestedWt, '.fs-meta', 'batches', '00000001', 'files.json')),
          'the pass-time adopted worktree was not seeded',
        );
        expect(passAdopted.id).toMatch(/^[0-9a-f]{8}$/);
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    90000,
  );

  gitTest(
    'a vanished worktree root becomes missing immediately and keeps its archive',
    async () => {
      // § 5f: the metadata directory disappearing is the removal signal; the root is `missing`, not stuck, and the
      // daemon never deletes batches. The directory is renamed (not deleted) so the archive can be checked intact.
      const m = machine();
      const repo = join(m.home, 'repo');
      makeRepo(repo);
      const wt = join(m.home, 'rem-wt');
      const moved = join(m.home, 'rem-wt-moved');
      git(repo, 'worktree', 'add', '-q', '-b', 'rembranch', wt);
      const metadata = join(repo, '.git', 'worktrees', 'rem-wt');

      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        addRoot(m, repo, '--mode', 'always');
        const wtId = addRoot(m, wt, '--mode', 'always');
        await eventually(
          () => existsSync(join(wt, '.fs-meta', 'batches', '00000001', 'files.json')),
          'the worktree root was not seeded',
        );

        renameSync(wt, moved);
        rmSync(metadata, { recursive: true, force: true });
        const missingRoot = await eventually(
          () => {
            const status = rootById(m, wtId);
            return status?.missing ? status : null;
          },
          'the vanished worktree root was not marked missing',
        );
        expect(missingRoot.missing).toBe(true);
        expect(existsSync(join(moved, '.fs-meta', 'batches'))).toBe(true);
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    90000,
  );
});

// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
// Hooks (`plans/worktrees.md` § 5c, M5)
//
// The hooks are a local file operation (`hooks install` resolves the git dirs itself, so it works with no daemon);
// the daemon reads their per-repository spool on its tick and feeds the same `GIT_EVENT` pipeline the metadata
// timeline feeds, with `source = hook`. These cases use a real `git`, because the criterion is about what git does
// when it runs a hook — a hand-written spool line would only test the parser.
// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

/** The repository's common dir, asked of git itself (the test's own view, not the daemon's). */
function commonDirOf(root) {
  return git(root, 'rev-parse', '--path-format=absolute', '--git-common-dir').trim();
}

/** `<common>/fsmeta-events.log`, where the hook appends and the daemon reads. */
function spoolOf(root) {
  return join(commonDirOf(root), 'fsmeta-events.log');
}

/**
 * Read frames from `peer` until a `GIT_EVENT` satisfies `predicate`, recording the interleaving. The same guard as
 * `readUntilGitEvent`: a `GIT_EVENT` inside a batch is a broken transaction, and a failure prints what was seen.
 */
async function untilGitEvent(peer, predicate, timeoutMs = 15000) {
  const log = [];
  const events = [];
  let openBatch = null;
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const frame = await peer.frame(Math.max(250, deadline - Date.now()));
    switch (frame.kind) {
      case KIND.START_BATCH: {
        openBatch = Number(frame.payload.readBigUInt64LE(0));
        log.push(`START_BATCH:${openBatch}`);
        break;
      }
      case KIND.CHANGE_ENTRY:
        expect(openBatch).not.toBeNull();
        log.push('CHANGE_ENTRY');
        break;
      case KIND.END_BATCH: {
        const number = Number(frame.payload.readBigUInt64LE(0));
        expect(openBatch).toBe(number);
        openBatch = null;
        log.push(`END_BATCH:${number}`);
        break;
      }
      case KIND.STATE:
        expect(openBatch).toBeNull();
        log.push('STATE');
        break;
      case KIND.GIT_EVENT: {
        expect(openBatch).toBeNull();
        const event = parseGitEvent(frame);
        events.push(event);
        log.push(`GIT_EVENT:${event.phase}:${event.kind}:${event.source}`);
        if (predicate(event)) return { event, events, log };
        break;
      }
      default:
        throw new Error(`unexpected frame 0x${frame.kind.toString(16)}`);
    }
  }
  throw new Error(`no matching GIT_EVENT; saw ${log.join(', ')}`);
}

describe('hooks: the file half, the spool, and the git events it feeds', () => {
  gitTest(
    'with the metadata watch disarmed, hooks still start and finish around the batch',
    async () => {
      // The criterion is that the hook path is a signal of its own: with the metadata *watch* off (the test guard
      // `FSMETA_GIT_ARM`, FORMAT.daemon.md § 8) nothing can produce an event except the spool, so every frame this
      // case sees is `source = hook`.
      const m = machine();
      const repo = join(m.home, 'repo');
      makeRepo(repo);
      makeFeatureBranch(repo);
      m.env.FSMETA_GIT_ARM = 'off';

      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const id = addRoot(m, repo, '--mode', 'always');
        const install = cliOk(m, 'daemon', 'hooks', 'install', repo);
        expect(install.out).toContain('installed 6 hook(s)');
        expect(daemon.output.text).not.toContain('git metadata watch armed for');

        const peer = await connect(join(m.runtime, 'roots', `${id}.sock`));
        expectHello(await peer.frame());
        await readUntilState(peer, (state) => state.state === 'watching');
        await drainFrames(peer);
        const before = rootStatusOf(m, id).head_batch;

        git(repo, 'checkout', '-q', 'feature');
        // `post-checkout` is the last hook a checkout fires, so waiting for its `branch` finish means the whole
        // operation is in the log — the earlier ref-transaction and index finishes arrive in the ticks before it.
        const checkout = await untilGitEvent(
          peer,
          (candidate) => candidate.phase === 'finish' && candidate.kind === 'branch' && candidate.source === 'hook',
          30000,
        );

        // The pass that reflected the checkout published generation `before + 1`, and the finish came after its END_BATCH.
        const batch = before + 1;
        const endIndex = checkout.log.indexOf(`END_BATCH:${batch}`);
        expect(endIndex).toBeGreaterThanOrEqual(0);
        const finishIndex = checkout.log.indexOf('GIT_EVENT:finish:branch:hook');
        expect(finishIndex).toBeGreaterThan(endIndex);
        expect(checkout.event.headBatch).toBe(batch);

        // The operation's start (the ref transaction's `prepared`) precedes its finish. A checkout fires several ref
        // transactions, each of which is a start/finish pair of its own; the coalescing rule is one event per
        // `(kind, phase)` *per pass*, not one per operation.
        const starts = checkout.log.filter((entry) => entry.startsWith('GIT_EVENT:start'));
        expect(starts.length).toBeGreaterThanOrEqual(1);
        expect(starts).toContain('GIT_EVENT:start:other:hook');
        expect(checkout.log.indexOf('GIT_EVENT:start:other:hook')).toBeLessThan(finishIndex);
        expect(checkout.log).toContain('GIT_EVENT:finish:other:hook');
        expect(checkout.events.every((event) => event.source === 'hook')).toBe(true);

        // The counters moved for hook-sourced events exactly as they do for the timeline's.
        const counters = rootStatusOf(m, id);
        expect(counters.git_events).toBeGreaterThanOrEqual(2);
        expect(counters.git_passes).toBeGreaterThanOrEqual(1);
        expect(counters.head).toBe('feature');
        await expectNoBatch(peer, 1200);
        peer.end();
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    90000,
  );

  gitTest(
    'a hook fired in an unserved worktree feeds the served root and writes no .fs-meta there',
    async () => {
      // The spool is per repository (§ 5c), so a checkout in a worktree fs-meta does not serve still reaches the daemon.
      // The event is repo-wide (`head_batch` is the receiving root's head, not a generation), and nothing creates a
      // `.fs-meta` in the unserved tree: the hook owns no directory but git's own.
      const m = machine();
      const repo = join(m.home, 'repo');
      makeRepo(repo);
      makeFeatureBranch(repo);
      const wt = join(m.home, 'wt-unserved');
      git(repo, 'worktree', 'add', '-q', '-b', 'wtbranch', wt);

      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const id = addRoot(m, repo, '--mode', 'always');
        cliOk(m, 'daemon', 'hooks', 'install', repo);
        const peer = await connect(join(m.runtime, 'roots', `${id}.sock`));
        expectHello(await peer.frame());
        await readUntilState(peer, (state) => state.state === 'watching');
        await drainFrames(peer);

        // A branch switch inside the unserved worktree: hooks live in the common dir, so they run there too.
        git(repo, 'branch', 'wt-twin', 'wtbranch');
        git(wt, 'checkout', '-q', 'wt-twin');
        const event = await untilGitEvent(peer, (candidate) => candidate.source === 'hook' && candidate.phase === 'finish');
        expect(event.event.headBatch).toBe(rootStatusOf(m, id).head_batch);

        // The common spool is where the line went, and the unserved tree has no fs-meta directory of ours.
        expect(Bun.file(spoolOf(repo)).size).toBeGreaterThan(0);
        expect(existsSync(join(wt, '.fs-meta'))).toBe(false);
        // Nothing changed in the served root's tree, so no batch follows the event.
        await expectNoBatch(peer, 1200);
        peer.end();
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    90000,
  );

  gitTest(
    'install works with no daemon, chains an existing hook, and uninstall restores it byte for byte',
    async () => {
      const m = machine();
      const repo = join(m.home, 'repo');
      makeRepo(repo);
      // The user's own post-checkout, kept byte-identical through install --force and uninstall.
      const hooksDir = join(repo, '.git', 'hooks');
      const original = '#!/bin/sh\nprintf "post-checkout %s\\n" "$*" >> "$(git rev-parse --show-toplevel)/user-hook.log"\nexit 0\n';
      writeFileSync(join(hooksDir, 'post-checkout'), original);

      // The root is recorded once, by a daemon that is then stopped: the `gitwatch` answer must come from roots.json.
      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        addRoot(m, repo, '--mode', 'always');
      } finally {
        await stopDaemon(daemon);
      }

      // No daemon: a plain install refuses the foreign hook and names it, and changes nothing.
      const refused = cli(m, 'daemon', 'hooks', 'install', repo);
      expect(refused.code).toBe(4);
      expect(refused.text).toContain(join(hooksDir, 'post-checkout'));
      expect(readFileSync(join(hooksDir, 'post-checkout'), 'utf8')).toBe(original);

      // `status --json` names the user's hook as `foreign` before anything of ours is written, and the other five as
      // `absent`: the report is what `install` refuses on, not a guess.
      const before = JSON.parse(cliOk(m, 'daemon', 'hooks', 'status', repo, '--json').out);
      const userHooks = before.repositories.find((entry) => samePathText(entry.common, commonDirOf(repo)));
      expect(userHooks.hooks['post-checkout']).toBe('foreign');
      expect(userHooks.hooks['reference-transaction']).toBe('absent');

      const forced = cliOk(m, 'daemon', 'hooks', 'install', repo, '--force');
      expect(forced.out).toContain('installed 6 hook(s)');
      expect(forced.out).toContain('chained 1 existing hook');
      const wrapper = readFileSync(join(hooksDir, 'post-checkout'), 'utf8');
      expect(wrapper).toContain('# fsmeta-managed');
      expect(wrapper).toContain('post-checkout.fsmeta-orig');
      expect(readFileSync(join(hooksDir, 'post-checkout.fsmeta-orig'), 'utf8')).toBe(original);

      // `status --json` reports ours/chained and the spool size, grouped by repository.
      const status = JSON.parse(cliOk(m, 'daemon', 'hooks', 'status', repo, '--json').out);
      const repository = status.repositories.find((entry) => samePathText(entry.common, commonDirOf(repo)));
      expect(repository.hooks['reference-transaction']).toBe('ours');
      expect(repository.hooks['post-checkout']).toBe('chained');
      expect(repository.spool_bytes).toBe(0);

      // A real checkout runs our hook and then the user's — the chained original still works.
      git(repo, 'checkout', '-q', '-b', 'chained-branch');
      expect(existsSync(join(repo, 'user-hook.log'))).toBe(true);
      expect(readFileSync(join(repo, 'user-hook.log'), 'utf8')).toContain('post-checkout');
      expect(Bun.file(spoolOf(repo)).size).toBeGreaterThan(0);

      // Uninstall restores the original byte for byte and removes every wrapper of ours.
      const removed = cliOk(m, 'daemon', 'hooks', 'uninstall', repo);
      expect(removed.out).toContain('restored 1 original');
      expect(readFileSync(join(hooksDir, 'post-checkout'), 'utf8')).toBe(original);
      expect(existsSync(join(hooksDir, 'post-checkout.fsmeta-orig'))).toBe(false);
      expect(existsSync(join(hooksDir, 'reference-transaction'))).toBe(false);
      expect(existsSync(join(hooksDir, 'post-merge'))).toBe(false);
    },
    90000,
  );

  gitTest(
    'a stale spool line is ignored, and a spool past the cap is truncated rather than replayed',
    async () => {
      const m = machine();
      const repo = join(m.home, 'repo');
      makeRepo(repo);
      makeFeatureBranch(repo);

      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const id = addRoot(m, repo, '--mode', 'always');
        cliOk(m, 'daemon', 'hooks', 'install', repo);
        const peer = await connect(join(m.runtime, 'roots', `${id}.sock`));
        expectHello(await peer.frame());
        await readUntilState(peer, (state) => state.state === 'watching');
        await drainFrames(peer);
        const spool = spoolOf(repo);

        // (a) A line stamped before this daemon started is a leftover from a hook that fired while no daemon ran: it is
        // discarded, not replayed as a fresh event.
        const stale = { at: Math.floor(Date.now() / 1000) - 3600, hook: 'post-merge', phase: 'finish', worktree: repo, args: '0' };
        writeFileSync(spool, `${existsSync(spool) ? readFileSync(spool, 'utf8') : ''}${JSON.stringify(stale)}\n`);
        const quiet = await collectFrames(peer, 1200);
        expect(quiet.events).toEqual([]);
        expect(quiet.batches).toEqual([]);

        // (b) A spool over the hook's cap: the *hook* truncates it before appending (§ 5c), so the old lines are gone
        // rather than replayed and the mailbox stays bounded for a repository that goes months without a daemon.
        const fillerAt = Math.floor(Date.now() / 1000) - 3600;
        const filler = Array.from({ length: 900 }, () =>
          JSON.stringify({ at: fillerAt, hook: 'post-merge', phase: 'finish', worktree: repo, args: '0' }),
        ).join('\n');
        writeFileSync(spool, `${filler}\n`);
        expect(Buffer.byteLength(readFileSync(spool))).toBeGreaterThan(64 * 1024);
        const full = await collectFrames(peer, 1200);
        expect(full.events).toEqual([]);

        git(repo, 'checkout', '-q', 'feature');
        const event = await untilGitEvent(peer, (candidate) => candidate.source === 'hook' && candidate.phase === 'finish');
        expect(event.event.headBatch).toBeGreaterThanOrEqual(rootStatusOf(m, id).head_batch - 1);
        const text = readFileSync(spool, 'utf8');
        expect(Buffer.byteLength(text)).toBeLessThan(64 * 1024);
        expect(text).not.toContain('"hook":"post-merge"');
        peer.end();
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    90000,
  );

  gitTest(
    'install refuses gitwatch off, a set core.hooksPath and an unwritable hooks path, naming each',
    async () => {
      const m = machine();
      const repo = join(m.home, 'repo');
      makeRepo(repo);

      // 1. `gitwatch` off: the spool would never be read, so installing is a trap.
      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const id = addRoot(m, repo, '--mode', 'always', '--gitwatch', 'off');
        const off = cli(m, 'daemon', 'hooks', 'install', repo);
        expect(off.code).toBe(4);
        expect(off.text).toContain('gitwatch off');
        expect(existsSync(join(repo, '.git', 'hooks', 'reference-transaction'))).toBe(false);
        // The root is removed so the next step starts from a clean record for the same repository.
        cliOk(m, 'root', 'remove', id, '--force');
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }

      // 2. `core.hooksPath` moves the directory git reads: installing ours would be silent, so it is refused with it.
      git(repo, 'config', 'core.hooksPath', '.git/my-hooks');
      const daemon2 = startDaemon(m);
      try {
        await waitForDaemon(m);
        addRoot(m, repo, '--mode', 'always');
        const moved = cli(m, 'daemon', 'hooks', 'install', repo);
        expect(moved.code).toBe(4);
        expect(moved.text).toContain('.git/my-hooks');
        git(repo, 'config', '--unset', 'core.hooksPath');
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon2.output.text}`);
      } finally {
        await stopDaemon(daemon2);
      }

      // 3. An unwritable hooks path: a file where the directory belongs is the portable stand-in for a read-only
      //    `<common>` (Windows has no read-only directory attribute that blocks creation), and the message names it.
      const hooksDir = join(repo, '.git', 'hooks');
      rmSync(hooksDir, { recursive: true, force: true });
      writeFileSync(hooksDir, 'not a directory\n');
      const daemon3 = startDaemon(m);
      try {
        await waitForDaemon(m);
        const readOnly = cli(m, 'daemon', 'hooks', 'install', repo);
        expect(readOnly.code).toBe(4);
        expect(readOnly.text).toContain(hooksDir);
        expect(readFileSync(hooksDir, 'utf8')).toBe('not a directory\n');
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon3.output.text}`);
      } finally {
        await stopDaemon(daemon3);
      }
    },
    120000,
  );
});

// ──────────────────────────────────────────────
// M7: the CLI and the documentation's claims
// ──────────────────────────────────────────────

describe('the M7 CLI: worktree listing, live switches and exclude', () => {
  gitTest(
    'roots list groups by common dir and marks a linked worktree; root set flips both switches live',
    async () => {
      const m = machine();
      const repo = join(m.home, 'repo');
      makeRepo(repo);
      const linked = join(m.home, 'linked');
      git(repo, 'worktree', 'add', '-q', '-b', 'wtbranch', linked);
      const common = commonDirOf(repo);

      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const mainId = addRoot(m, repo, '--mode', 'always');
        const linkedId = addRoot(m, linked, '--mode', 'always');

        // `--json` stays the flat array, with the two host-state fields filled from the resolved git location. The
        // git dirs are resolved on the root's first pass, so wait for both roots rather than racing the scheduler.
        const entries = await eventually(async () => {
          const list = roots(m);
          const main = list.find((entry) => entry.id === mainId);
          const worktree = list.find((entry) => entry.id === linkedId);
          return main?.common_dir && worktree?.worktree ? list : null;
        }, 'the roots never reported their resolved common dirs');
        const main = entries.find((entry) => entry.id === mainId);
        const worktree = entries.find((entry) => entry.id === linkedId);
        expect(main.worktree).toBe(false);
        expect(main.common_dir.length).toBeGreaterThan(0);
        expect(samePathText(main.common_dir, common)).toBe(true);
        expect(worktree.worktree).toBe(true);
        expect(samePathText(worktree.common_dir, common)).toBe(true);

        // Text output: sorted adjacency under a `repo <common dir>` header, and the marker on the linked root.
        const text = cliOk(m, 'roots', 'list').out;
        const lines = text.split('\n');
        const header = lines.findIndex((line) => line.startsWith('repo '));
        const repoLine = lines.findIndex((line) => !line.startsWith('repo ') && line.includes(repo));
        const linkedLine = lines.findIndex((line) => line.includes(linked));
        expect(header).toBeGreaterThanOrEqual(0);
        expect(samePathText(lines[header].slice('repo '.length), common)).toBe(true);
        expect(repoLine).toBeGreaterThan(header);
        expect(linkedLine).toBeGreaterThan(repoLine);
        expect(lines[linkedLine]).toContain('worktree');
        expect(lines[repoLine]).not.toContain('worktree');

        // `gitwatch off` applies live: the arm and the resolved git dirs go, so the git fields are empty at once.
        const off = cliOk(m, 'root', 'set', mainId, 'gitwatch', 'off');
        expect(off.out).toContain('gitwatch off');
        const withoutGit = rootStatusOf(m, mainId);
        expect(withoutGit.gitwatch).toBe(false);
        expect(withoutGit.head).toBe('');
        expect(withoutGit.common_dir).toBe('');
        expect(withoutGit.worktree).toBe(false);
        await eventually(
          async () => (await rootLogText(m, mainId)).includes('control: gitwatch off'),
          'the daemon did not log the gitwatch flip',
        );

        // ... and on again resolves the same repository immediately (`HEAD` is read on demand).
        cliOk(m, 'root', 'set', mainId, 'gitwatch', 'on');
        const withGit = await eventually(
          async () => {
            const status = rootStatusOf(m, mainId);
            return status.gitwatch && status.head === 'main' ? status : null;
          },
          'gitwatch on did not restore the git status',
        );
        expect(samePathText(withGit.common_dir, common)).toBe(true);

        // `worktrees off` stops the worktree event but not the boundary rule or the root itself.
        const peer = await connect(join(m.runtime, 'roots', `${mainId}.sock`));
        expectHello(await peer.frame());
        await readUntilState(peer, (state) => state.state === 'watching');
        await drainFrames(peer);

        cliOk(m, 'root', 'set', mainId, 'worktrees', 'off');
        expect(rootStatusOf(m, mainId).worktrees).toBe(false);
        const offWt = join(m.home, 'off-wt');
        git(repo, 'worktree', 'add', '-q', '-b', 'offbranch', offWt);
        const quiet = await collectFrames(peer, 1500);
        expect(quiet.events.filter((event) => event.kind === 'worktree')).toEqual([]);

        // The switch never hides a boundary: a worktree *inside* the served repository is absent from its trio with
        // the handling off (the engine's rule, not the daemon's flag). A pass that publishes nothing still moves
        // `last_pass_ms`; `passes` only counts published generations, so it is not the clock to wait on.
        const beforeInside = rootStatusOf(m, mainId).last_pass_ms;
        const nestedWt = join(repo, 'inside-wt');
        git(repo, 'worktree', 'add', '-q', '-b', 'insidebranch', nestedWt);
        await eventually(
          async () => rootStatusOf(m, mainId).last_pass_ms > beforeInside,
          'the repository never passed after a worktree appeared inside it',
        );
        const files = readFileSync(join(repo, '.fs-meta', 'files.txt'), 'utf8');
        expect(files).not.toContain('inside-wt');

        // Back on, the next worktree add produces the repo-wide event with its path.
        cliOk(m, 'root', 'set', mainId, 'worktrees', 'on');
        expect(rootStatusOf(m, mainId).worktrees).toBe(true);
        const onWt = join(m.home, 'on-wt');
        git(repo, 'worktree', 'add', '-q', '-b', 'onbranch', onWt);
        // A metadata `start` can be written before git has filled in `worktrees/<id>/gitdir`, and the plan makes an
        // empty path mean "the path is no longer knowable"; the finish carries the path, so wait for a named event.
        const event = await readUntilGitEvent(peer, (candidate) => candidate.kind === 'worktree' && candidate.path.length > 0);
        expect(event.event.kind).toBe('worktree');
        expect(event.event.path.length).toBeGreaterThan(0);
        peer.end();

        // `daemon status` reports the effective values, and both were flipped back on above.
        const status = cliOk(m, 'daemon', 'status').out;
        expect(status).toContain('worktrees on');
        expect(status).toContain('gitwatch on');
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    120000,
  );

  gitTest(
    'root add --worktree asserts a linked worktree, and --nested acknowledges the guard without weakening it',
    async () => {
      const m = machine();
      const repo = join(m.home, 'repo');
      makeRepo(repo);
      const linked = join(m.home, 'linked');
      git(repo, 'worktree', 'add', '-q', '-b', 'wtbranch', linked);

      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const mainId = addRoot(m, repo, '--mode', 'always');

        // A plain directory is refused by the assertion, with its path in the message.
        const refused = cli(m, 'root', 'add', m.root, '--worktree');
        expect(refused.code).toBe(4);
        expect(refused.text).toContain('not a linked worktree');
        expect(refused.text).toContain(m.root);
        expect(roots(m).some((entry) => entry.root === m.root)).toBe(false);

        // A linked worktree is accepted, marked, and seeded from the served base (the base is already serving).
        const added = cliOk(m, 'root', 'add', linked, '--worktree', '--mode', 'always');
        expect(added.out).toContain('linked worktree of');
        const linkedId = added.out.match(/added ([0-9a-f]{8})/)[1];
        const linkedStatus = await eventually(async () => {
          const status = rootStatusOf(m, linkedId);
          return status.worktree && status.common_dir ? status : null;
        }, 'the linked worktree root never resolved its common dir');
        expect(samePathText(linkedStatus.common_dir, commonDirOf(repo))).toBe(true);

        // `--nested` says the intent was acknowledged; the parent's managed block is still written, so the child is
        // absent from the parent's trio.
        const child = join(repo, 'packages', 'child');
        mkdirSync(child, { recursive: true });
        writeFileSync(join(child, 'inner.txt'), 'inner\n');
        const beforeNestedPass = rootStatusOf(m, mainId).last_pass_ms;
        const nestedAdd = cliOk(m, 'root', 'add', child, '--nested', '--mode', 'always');
        expect(nestedAdd.out).toContain('nested: acknowledged');
        const ignore = readFileSync(join(repo, '.fs-meta', 'ignore'), 'utf8');
        expect(ignore).toContain('packages/child/');
        await eventually(
          async () => rootStatusOf(m, mainId).last_pass_ms > beforeNestedPass,
          'the parent never republished after the nested add',
        );
        expect(readFileSync(join(repo, '.fs-meta', 'files.txt'), 'utf8')).not.toContain('packages/child');
        expect(mainId).not.toBe(linkedId);
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    90000,
  );

  gitTest(
    'fsmeta exclude is idempotent, preserves existing lines, writes LF and refuses a non-repository',
    async () => {
      const m = machine();
      const repo = join(m.home, 'repo');
      makeRepo(repo);
      const excludePath = join(commonDirOf(repo), 'info', 'exclude');
      // A user's own line, replaced with a small known file so "preserved" is byte-for-byte.
      writeFileSync(excludePath, '*.log\n# a user line\n');

      const first = cliOk(m, 'exclude', repo);
      expect(first.out).toContain(excludePath);
      const text = readFileSync(excludePath, 'utf8');
      expect(text).toBe('*.log\n# a user line\n# fsmeta: our own directory\n.fs-meta/\n');
      expect(text).not.toContain('\r');
      expect((text.match(/# fsmeta: our own directory/g) ?? []).length).toBe(1);

      // Idempotent: a second run writes nothing.
      const second = cliOk(m, 'exclude', repo);
      expect(second.out).toContain('already carries');
      expect(readFileSync(excludePath, 'utf8')).toBe(text);

      // Refused when the path is not a repository, naming it, and nothing is created.
      const plain = join(m.home, 'plain');
      mkdirSync(plain, { recursive: true });
      const refused = cli(m, 'exclude', plain);
      expect(refused.code).toBe(1);
      expect(refused.text).toContain(plain);
      expect(refused.text).toContain('not a git working copy');
      expect(existsSync(join(plain, 'info', 'exclude'))).toBe(false);

      // The mark is honoured by git itself: `git status` ignores the untracked `.fs-meta` directory.
      mkdirSync(join(repo, '.fs-meta'), { recursive: true });
      writeFileSync(join(repo, '.fs-meta', 'files.txt'), 'x\n');
      expect(git(repo, 'status', '--porcelain').trim()).toBe('');
    },
    60000,
  );
});

// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
// The two M4 gaps: a failed pass's finish, and the hook/worktree source boundary
//
// `plans/worktrees.md` M4 left two of its claims as code paths rather than tests: "a failed pass emits
// `status = failed`" and "a `worktree` event can only come from the metadata watch" (no hook carries that kind,
// even though `worktree add` does fire its other hooks in the new worktree's context). Both cases work from
// **outside** the daemon — a sabotaged `.fs-meta` in the first, a real git plus the real hooks in the second — so
// neither proves itself with daemon code edited to fit.
// ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

/** The six hooks `daemon hooks install` writes (`FORMAT.daemon.md` § 6a): the only lines the spool can hold. */
const MANAGED_HOOKS = [
  'reference-transaction',
  'post-checkout',
  'post-merge',
  'post-rewrite',
  'post-index-change',
  'post-commit',
];

/** The common spool's lines, parsed: what the installed hooks actually wrote (append-only, so a slice is a delta). */
function parsedSpool(path) {
  return existsSync(path) ? readFileSync(path, 'utf8').split('\n').filter(Boolean).map((line) => JSON.parse(line)) : [];
}

describe('the two M4 gaps: a failed finish, and what a hook cannot say about a worktree', () => {
  gitTest(
    'a pass that fails still finishes the pending kind with status = failed, and the root records why',
    async () => {
      // § 5d rule 5: "a failed pass is reported, not hidden". The pass is made to fail from outside the daemon: the
      // trio's `files.meta` is a directory, so the engine's read of the previous generation fails with `IsDir`. The
      // sabotage is a `.fs-meta` event, which the watcher ignores (§ 2b rule 2), so it cannot trigger the pass on
      // its own — the git signal does, and the pending kind is still there when the engine fails.
      const m = machine();
      const repo = join(m.home, 'repo');
      makeRepo(repo);
      // A branch with *identical content*: switching to it is a metadata-only change (`HEAD`), so the pass that
      // runs is the one the git signal asked for, not an unrelated working-tree burst.
      git(repo, 'branch', 'twin', 'main');

      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const id = addRoot(m, repo, '--mode', 'always');
        await eventually(
          () => existsSync(join(repo, '.fs-meta', 'files.meta')),
          'the root did not publish its first pass',
        );
        const peer = await connect(join(m.runtime, 'roots', `${id}.sock`));
        expectHello(await peer.frame());
        await readUntilState(peer, (state) => state.state === 'watching');
        await drainFrames(peer);
        const before = rootStatusOf(m, id);

        const meta = join(repo, '.fs-meta', 'files.meta');
        const saved = `${meta}.saved`;
        renameSync(meta, saved);
        mkdirSync(meta);

        // A HEAD-only checkout: the metadata watch stamps `branch` (and git's own index/other writes), and the pass
        // that follows cannot read the trio. Its finish is written from the failure arm, with `status = failed`.
        git(repo, 'checkout', '-q', 'twin');
        const failed = await untilGitEvent(
          peer,
          (candidate) => candidate.phase === 'finish' && candidate.kind === 'branch',
          20000,
        );

        // Every finish the pending kinds produced is a failed one from the signal's source, and no batch exists:
        // the failed pass published nothing, so the finish's `head_batch` is the head the root already had.
        const finishes = failed.events.filter((event) => event.phase === 'finish');
        expect(finishes.length).toBeGreaterThanOrEqual(1);
        expect(finishes.every((event) => event.status === 'failed')).toBe(true);
        const starts = failed.events.filter((event) => event.phase === 'start');
        expect(starts.length).toBeGreaterThanOrEqual(1);
        expect(starts.every((event) => event.status === 'ok' && event.source === 'metadata')).toBe(true);
        expect(failed.event.source).toBe('metadata');
        expect(failed.event.status).toBe('failed');
        expect(failed.event.headBatch).toBe(before.head_batch);
        expect(failed.log.some((entry) => entry.startsWith('START_BATCH'))).toBe(false);

        // The root reports the failure instead of hiding it, and stays a *watching* root: a transient read error is
        // recorded and retried (`failLocked`), not turned into "missing" (§ 2a, § 4 `last_error`).
        const failedStatus = rootStatusOf(m, id);
        expect(failedStatus.last_error).toBe('IsDir');
        expect(failedStatus.missing).toBe(false);
        expect(failedStatus.mode).toBe('always');
        expect(failedStatus.state).toBe('watching');
        expect(failedStatus.head).toBe('twin'); // the git state was resolved before the pass failed
        expect(failedStatus.head_batch).toBe(before.head_batch); // a failed pass publishes nothing
        expect(failedStatus.git_passes).toBeGreaterThan(before.git_passes); // a finish did wait for that pass

        // Restore the trio and prove the root is still serving: the next change is published and clears the error.
        await drainFrames(peer, 600);
        rmSync(meta, { recursive: true, force: true });
        renameSync(saved, meta);
        writeFileSync(join(repo, 'recovered.txt'), 'back\n');
        const recovered = await eventually(
          async () => {
            const status = rootStatusOf(m, id);
            return status.head_batch === before.head_batch + 1 && status.last_error === '' ? status : null;
          },
          'the root did not recover after the trio was restored',
          20000,
        );
        expect(recovered.missing).toBe(false);
        peer.end();
        cliOk(m, 'root', 'remove', id, '--force');
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    90000,
  );

  gitTest(
    'with hooks installed, a worktree add and remove are metadata events, and no hook line is a worktree event',
    async () => {
      // Gap C: a `worktree` event cannot be hook-sourced because no hook carries the kind — the metadata watch is
      // the only source. The hooks *do* fire around an add (M4's spike: in the new worktree's context), so this
      // pins the negative the contract needs rather than a claim that the spool stays empty.
      const m = machine();
      const repo = join(m.home, 'repo');
      makeRepo(repo);
      // A second linked worktree that stays behind keeps `worktrees/` alive, so this case observes the ordinary
      // add/remove pair. The last-removal shape — where the empty parent goes too — is its own case below.
      git(repo, 'worktree', 'add', '-q', '-b', 'seedbranch', join(m.home, 'seed-wt'));

      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const id = addRoot(m, repo, '--mode', 'always');
        cliOk(m, 'daemon', 'hooks', 'install', repo);
        const peer = await connect(join(m.runtime, 'roots', `${id}.sock`));
        expectHello(await peer.frame());
        await readUntilState(peer, (state) => state.state === 'watching');
        await drainFrames(peer);

        const spool = spoolOf(repo);
        const spoolBeforeAdd = parsedSpool(spool);

        // The event is the metadata timeline's: `worktrees/<id>` appears and its `gitdir` names the new path.
        const added = join(m.home, 'wt-hooked');
        git(repo, 'worktree', 'add', '-q', '-b', 'hookbranch', added);
        const appeared = await untilGitEvent(
          peer,
          (candidate) => candidate.kind === 'worktree' && candidate.phase === 'finish' && candidate.path.length > 0,
          20000,
        );
        expect(appeared.event.source).toBe('metadata');
        expect(samePathText(appeared.event.path, added)).toBe(true);
        // § 5d: a worktree event is about the repository, not this root's tree, so `head_batch` is the root's head.
        expect(appeared.event.headBatch).toBe(rootStatusOf(m, id).head_batch);
        // Every worktree event the client saw is the metadata watch's: a hook cannot produce the kind.
        expect(appeared.events.filter((event) => event.kind === 'worktree').every((event) => event.source === 'metadata')).toBe(true);

        await drainFrames(peer, 600);
        const addLines = parsedSpool(spool).slice(spoolBeforeAdd.length);
        // What `worktree add` actually wrote on this host (git 2.54.0.windows.1): ref transactions in the parent
        // repository and the new worktree, then `post-index-change` and `post-checkout` in the new worktree. None
        // of them is a worktree event: the six managed hooks have no such mapping, and no args name one.
        expect(addLines.length).toBeGreaterThan(0);
        expect(addLines.every((line) => MANAGED_HOOKS.includes(line.hook))).toBe(true);
        expect(addLines.every((line) => !line.hook.includes('worktree') && !line.args.includes('worktree'))).toBe(true);
        expect(addLines.some((line) => samePathText(line.worktree, added))).toBe(true);

        // A removal is the metadata timeline's too: the directory is gone, so the path is no longer knowable and
        // `path_len = 0` (§ GIT_EVENT). No hook names the worktree it removes; what the spool shows is incidental.
        const spoolBeforeRemove = parsedSpool(spool);
        git(repo, 'worktree', 'remove', added);
        const gone = await untilGitEvent(
          peer,
          (candidate) => candidate.kind === 'worktree' && candidate.phase === 'finish' && candidate.path === '',
          20000,
        );
        expect(gone.event.source).toBe('metadata');
        expect(gone.event.path).toBe('');
        expect(gone.events.filter((event) => event.kind === 'worktree').every((event) => event.source === 'metadata')).toBe(true);

        const removeLines = parsedSpool(spool).slice(spoolBeforeRemove.length);
        expect(removeLines.every((line) => MANAGED_HOOKS.includes(line.hook))).toBe(true);
        expect(removeLines.every((line) => !line.hook.includes('worktree') && !line.args.includes('worktree'))).toBe(true);
        // On this git the removal still leaves one incidental line — the removed worktree's index read-lock
        // release, `post-index-change` with args "0 0" — which maps to `index`, never to `worktree`. A git that
        // fires nothing at all (0 lines) is the other acceptable shape; anything else is a new hook to account for.
        expect(removeLines.length).toBeLessThanOrEqual(1);
        if (removeLines.length === 1) {
          expect(removeLines[0].hook).toBe('post-index-change');
          expect(removeLines[0].phase).toBe('finish');
          expect(removeLines[0].args).toBe('0 0');
        }
        peer.end();
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    120000,
  );

  gitTest(
    'removing the last linked worktree still finishes with an empty path',
    async () => {
      // The last worktree takes the empty `worktrees/` directory with it. On ReadDirectoryChangesW the child's
      // removal is not delivered separately — the surviving event names the parent — so the daemon must still answer
      // "a worktree left this repo" with one finish and `path_len = 0` (§ 5d), not stay silent because the id is gone.
      const m = machine();
      const repo = join(m.home, 'repo');
      makeRepo(repo);
      const only = join(m.home, 'only-wt');
      git(repo, 'worktree', 'add', '-q', '-b', 'only', only);
      const daemon = startDaemon(m);
      try {
        await waitForDaemon(m);
        const id = addRoot(m, repo, '--mode', 'always');
        const peer = await connect(join(m.runtime, 'roots', `${id}.sock`));
        expectHello(await peer.frame());
        await readUntilState(peer, (state) => state.state === 'watching');
        await drainFrames(peer);

        git(repo, 'worktree', 'remove', only);
        const gone = await untilGitEvent(
          peer,
          (candidate) => candidate.kind === 'worktree' && candidate.phase === 'finish' && candidate.path === '',
          20000,
        );
        expect(gone.event.source).toBe('metadata');
        expect(existsSync(join(repo, '.git', 'worktrees'))).toBe(false);
        // `root status` records the last git signal too (`plans/worktrees.md` § 8.12), so an idle root can be told
        // from one whose watcher died.
        const last = rootStatusOf(m, id);
        expect(last.last_git_kind).toBe('worktree');
        expect(last.last_git_phase).toBe('finish');
        peer.end();
      } catch (error) {
        throw new Error(`${error.message}\ndaemon output:\n${daemon.output.text}`);
      } finally {
        await stopDaemon(daemon);
      }
    },
    60000,
  );
});
