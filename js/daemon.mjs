// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//
// The daemon client: find the root a running `fsmeta daemon` serves, ask it for
// the names it has cached, and bootstrap that answer from the trio when the batch
// window no longer reaches back to generation 1.
//
// **This is a client. It connects to the Zig `fsmeta daemon`; it is not a daemon,
// it never starts one, and it contains no watcher, scheduler, server or publish
// service.** Only the Zig engine implements the daemon (AGENTS.md § 1);
// `./fsmeta.mjs` is the trio reader, and this module is its socket counterpart.
//
// This is the consumer side of `FORMAT.daemon.md` and `FORMAT.socket.md`, and it
// deliberately imports only Node builtins statically. The daemon's registry and
// frames are host state, not trio content, so a Node process can use them even
// though the trio reader (`layout.mjs`) currently requires Bun's native wyhash
// and throws at import time. The trio is loaded through a dynamic import below
// and is simply skipped when that reader cannot load.
//
// Three shapes are exported:
//
//   namesForRoot(directory)      one call: resolve the served root, read the trio
//                                as a baseline when available, replay what the
//                                daemon has after it, and return the current names
//   queryNames(socketPath)       replay names from the wire without a baseline
//   replayNames(socketPath)      the same, from an explicit batch and baseline
//
// `namesForRoot` is the one a tool wants: it is correct after the daemon's
// retention has pruned the oldest batches, because the trio supplies the state
// at generation `g` and the replay supplies only the changes after `g`. An `auto`
// root that was asleep is handled by the same path: subscribing wakes it, and
// the wake scan is published as a batch on top of the trio.

import { connect } from 'node:net';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { homedir } from 'node:os';
import { isAbsolute, join, relative, resolve, sep } from 'node:path';

import { translateGlob } from '@hrg/gitignore';

/** Message kinds, `FORMAT.socket.md` § Messages. */
export const KIND = {
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

/** The protocol this client speaks: major 1, minor 5 (`0x0105`). It subscribes with the original form; the
 *  staged-build frames are for clients that opt into `SUBSCRIBE_V2`/`SUBSCRIBE_V3` (`FORMAT.socket.md` § BUILD_STAGES). */
export const PROTOCOL = 0x0105;

/** Every frame's payload is at most 1 MiB (`FORMAT.socket.md` § Framing). */
export const MAX_FRAME = 1024 * 1024;

/** Entry size the format pins (`FORMAT.md` § 5). */
export const ENTRY_SIZE = 64;

/** Change bits carried by a batch entry (`FORMAT.md` § 17.2). */
export const CHANGE_ADDED = 0x20;
export const CHANGE_CHANGED = 0x40;
export const CHANGE_DELETED = 0x80;

/** Type bits this client needs (`FORMAT.md` § 6). */
export const FLAG_IS_DIR = 0x04;
export const FLAG_SYMLINK = 0x10;

/** `ERROR` codes that change what a caller can do (`FORMAT.socket.md` § Values). */
export const ERROR_BATCH_TOO_OLD = 2;
export const ERROR_BATCH_GAP = 3;

const FRAME_HEADER = 8;
const HELLO_PAYLOAD = 24;

const u64 = (value) => BigInt.asUintN(64, BigInt(value));

// ------------------------------------------------------------------ roots.json

/**
 * The daemon's durable root list, by platform (`FORMAT.daemon.md` § 1b):
 * `$FSMETA_CONFIG_HOME/fsmeta/roots.json`, `$XDG_CONFIG_HOME/fsmeta/roots.json`,
 * `~/.config/fsmeta/roots.json`, or `%APPDATA%\fsmeta\roots.json` on Windows.
 */
export function rootsConfigPath(env = process.env) {
  if (env.FSMETA_CONFIG_HOME) return join(env.FSMETA_CONFIG_HOME, 'fsmeta', 'roots.json');
  if (env.XDG_CONFIG_HOME) return join(env.XDG_CONFIG_HOME, 'fsmeta', 'roots.json');
  if (process.platform === 'win32') {
    return join(env.APPDATA ?? join(homedir(), 'AppData', 'Roaming'), 'fsmeta', 'roots.json');
  }
  return join(homedir(), '.config', 'fsmeta', 'roots.json');
}

/**
 * The `roots.json` document, or `null` when it is missing or malformed. A daemon
 * that was never started is a normal state, not an error.
 */
export function readRoots(configPath = rootsConfigPath()) {
  let document;
  try {
    document = JSON.parse(readFileSync(configPath, 'utf8'));
  } catch {
    return null;
  }
  if (document === null || typeof document !== 'object' || !Array.isArray(document.roots)) return null;
  return document;
}

/** `path` resolved through the filesystem where possible, so symlinks compare equal. */
export function canonicalPath(path) {
  const absolute = resolve(path);
  try {
    return realpathSync.native(absolute);
  } catch {
    return absolute;
  }
}

/** True when `child` is `parent` or lives under it. */
export function isInside(parent, child) {
  const candidate = relative(canonicalPath(parent), canonicalPath(child));
  return candidate === '' || (!isAbsolute(candidate) && candidate !== '..' && !candidate.startsWith(`..${sep}`));
}

/**
 * The longest served root containing `directory`, or `null`. `roots.json` only
 * says what was added once; whether the daemon is running is decided by the
 * socket attempt in `namesForRoot`.
 */
export function findRootForPath(directory, { configPath = rootsConfigPath(), document = null } = {}) {
  const roots = (document ?? readRoots(configPath))?.roots ?? [];
  const target = canonicalPath(directory);
  const candidates = roots
    .filter((record) => record !== null && typeof record === 'object'
      && typeof record.root === 'string' && typeof record.socket === 'string' && record.socket !== '')
    .map((record) => ({ ...record, canonical: canonicalPath(record.root) }))
    .filter((record) => isInside(record.canonical, target))
    .sort((left, right) => right.canonical.length - left.canonical.length);
  return candidates[0] ?? null;
}

// ------------------------------------------------------------------ frames

/** The 8-byte frame prefix. Exported so a test or another client can build frames. */
export function framePrefix(kind, length, flags = 0) {
  const prefix = Buffer.alloc(FRAME_HEADER);
  prefix.writeUInt16LE(kind, 0);
  prefix.writeUInt16LE(flags, 2);
  prefix.writeUInt32LE(length, 4);
  return prefix;
}

/** One complete frame: prefix + payload. */
export function frame(kind, payload, flags = 0) {
  return Buffer.concat([framePrefix(kind, payload.length, flags), payload]);
}

/** The client's `HELLO` payload (`FORMAT.socket.md` § Handshake). */
export function helloPayload({
  protocol = PROTOCOL,
  entrySize = ENTRY_SIZE,
  hashAlgorithm = 0,
  role = 1, // client
  capabilities = 0,
  reserved = 0,
  generation = 0n,
  maxFrame = MAX_FRAME,
} = {}) {
  const payload = Buffer.alloc(HELLO_PAYLOAD);
  payload.writeUInt16LE(protocol, 0);
  payload.writeUInt16LE(entrySize, 2);
  payload.writeUInt8(hashAlgorithm, 4);
  payload.writeUInt8(role, 5);
  payload.writeUInt8(capabilities, 6);
  payload.writeUInt8(reserved, 7);
  payload.writeBigUInt64LE(u64(generation), 8);
  payload.writeBigUInt64LE(u64(maxFrame), 16);
  return payload;
}

/**
 * The extended `SUBSCRIBE` payload: `from_batch`, include patterns, exclude
 * patterns (`FORMAT.socket.md` § SUBSCRIBE filter patterns). Exclude wins over
 * include. An empty pattern list is the pass-all form.
 */
export function subscribePayload({ fromBatch = 0n, include = [], exclude = [] } = {}) {
  const parts = [];
  const head = Buffer.alloc(8 + 2);
  head.writeBigUInt64LE(u64(fromBatch), 0);
  head.writeUInt16LE(include.length, 8);
  parts.push(head);
  for (const pattern of include) parts.push(lengthPrefixed(pattern));

  const excludeCount = Buffer.alloc(2);
  excludeCount.writeUInt16LE(exclude.length, 0);
  parts.push(excludeCount);
  for (const pattern of exclude) parts.push(lengthPrefixed(pattern));

  return Buffer.concat(parts);
}

/**
 * `SUBSCRIBE_V3`: `from_batch`, `from_stage_batch`, `stage`, `flags`, then the same include/exclude
 * section as `subscribePayload` (`FORMAT.socket.md` § BUILD_STAGES). `flags` bit 0 is the builder role.
 */
export function subscribeV3Payload({
  fromBatch = 0n,
  fromStageBatch = 0n,
  stage = 0,
  builder = false,
  include = [],
  exclude = [],
} = {}) {
  const head = Buffer.alloc(20);
  head.writeBigUInt64LE(u64(fromBatch), 0);
  head.writeBigUInt64LE(u64(fromStageBatch), 8);
  head.writeUInt16LE(stage, 16);
  head.writeUInt16LE(builder ? 1 : 0, 18);

  const includeCount = Buffer.alloc(2);
  includeCount.writeUInt16LE(include.length, 0);
  const parts = [head, includeCount];
  for (const pattern of include) parts.push(lengthPrefixed(pattern));
  const excludeCount = Buffer.alloc(2);
  excludeCount.writeUInt16LE(exclude.length, 0);
  parts.push(excludeCount);
  for (const pattern of exclude) parts.push(lengthPrefixed(pattern));
  return Buffer.concat(parts);
}

/** `SUBSCRIBE_V2`: the stage header without the stage-batch replay cursor. A V2 subscriber starts at the stage
 *  head; use {@link subscribeV3Payload} when the producer's archived artifact batches are needed. */
export function subscribeV2Payload({
  fromBatch = 0n,
  stage = 0,
  builder = false,
  include = [],
  exclude = [],
} = {}) {
  const head = Buffer.alloc(12);
  head.writeBigUInt64LE(u64(fromBatch), 0);
  head.writeUInt16LE(stage, 8);
  head.writeUInt16LE(builder ? 1 : 0, 10);
  const includeCount = Buffer.alloc(2);
  includeCount.writeUInt16LE(include.length, 0);
  const parts = [head, includeCount];
  for (const pattern of include) parts.push(lengthPrefixed(pattern));
  const excludeCount = Buffer.alloc(2);
  excludeCount.writeUInt16LE(exclude.length, 0);
  parts.push(excludeCount);
  for (const pattern of exclude) parts.push(lengthPrefixed(pattern));
  return Buffer.concat(parts);
}

/** `BUILD_STARTED`: the generation a builder is working from. */
export function buildStartedPayload(generation) {
  const payload = Buffer.alloc(8);
  payload.writeBigUInt64LE(u64(generation), 0);
  return payload;
}

/** `BUILD_DONE`: the generation acknowledged and `0 = ok`, `1 = failed`, `2 = cancelled`. */
export function buildDonePayload(generation, status = 0) {
  const payload = Buffer.alloc(9);
  payload.writeBigUInt64LE(u64(generation), 0);
  payload.writeUInt8(status, 8);
  return payload;
}

/** A `STAGE_BATCH_START` server payload (`u16 stage`, `u64 generation`, `u64 parent`, `u64 started_ns`). */
export function parseStageBatchStart(payload) {
  if (payload.length !== 26) throw new Error('daemon sent a short STAGE_BATCH_START');
  return {
    stage: payload.readUInt16LE(0),
    generation: payload.readBigUInt64LE(2),
    parent: payload.readBigUInt64LE(10),
    startedNs: payload.readBigUInt64LE(18),
  };
}

/** A `STAGE_BATCH_END` server payload. */
export function parseStageBatchEnd(payload) {
  if (payload.length !== 43) throw new Error('daemon sent a short STAGE_BATCH_END');
  return {
    stage: payload.readUInt16LE(0),
    generation: payload.readBigUInt64LE(2),
    added: payload.readBigUInt64LE(10),
    changed: payload.readBigUInt64LE(18),
    deleted: payload.readBigUInt64LE(26),
    changesHash: payload.readBigUInt64LE(34),
    status: payload.readUInt8(42),
  };
}

function lengthPrefixed(text) {
  const bytes = Buffer.from(text, 'utf8');
  if (bytes.length > 0xffff) throw new Error(`filter pattern is too long: ${text}`);
  const length = Buffer.alloc(2);
  length.writeUInt16LE(bytes.length, 0);
  return Buffer.concat([length, bytes]);
}

/** The entry fields this client reads: type/change flags and the name. */
export function parseEntry(payload) {
  if (payload.length < ENTRY_SIZE) throw new Error('daemon sent a short CHANGE_ENTRY');
  const nameLength = payload.readUInt32LE(40);
  if (payload.length !== ENTRY_SIZE + nameLength) {
    throw new Error(`daemon sent ${payload.length} bytes for an entry whose name is ${nameLength}`);
  }
  return {
    flags: payload.readUInt32LE(44),
    name: payload.subarray(ENTRY_SIZE, ENTRY_SIZE + nameLength).toString('utf8'),
  };
}

// ------------------------------------------------------------------ trio baseline

/**
 * The names in a served root's trio, with the generation they describe, or
 * `null` when the trio is absent, unusable, or the reader cannot load here.
 *
 * Directories are omitted; regular files and symlinks are kept — a caller that
 * rewrites files should filter symlinks itself, because the trio records them
 * rather than following them.
 */
async function trioBaseline(record, fsMeta = null) {
  const directory = join(record.root, '.fs-meta');
  if (!existsSync(directory)) return null;

  let reader = fsMeta;
  if (reader === null) {
    try {
      // The reader imports layout.mjs, which needs Bun's native wyhash today;
      // under Node that import throws and this baseline is skipped.
      reader = await import('./fsmeta.mjs');
    } catch {
      return null;
    }
  }

  let load;
  try {
    load = reader.loadTrioIfPresent(directory);
  } catch {
    return null;
  }
  if (!load || !load.ok) return null;

  const names = new Map();
  load.pair.names.forEach((name, index) => {
    const entry = load.pair.entries[index];
    if ((entry.flags & FLAG_IS_DIR) !== 0) return;
    names.set(name, entry.flags);
  });
  return { names, generation: BigInt(load.config.generation) };
}

// ------------------------------------------------------------------ the socket client

/** The `ERROR` word for a code, so a caller can branch without reading text. */
function errorWord(code) {
  if (code === 1) return 'protocol';
  if (code === ERROR_BATCH_TOO_OLD) return 'batch-too-old';
  if (code === ERROR_BATCH_GAP) return 'batch-gap';
  return `error-${code}`;
}

/**
 * One consumer filter pattern (`filter.zig` § Semantics): a pattern with a `/`
 * is anchored to the root and matches the whole name; one without is a basename
 * matched at any depth. Both use git's wildmatch, through the shared translator.
 */
function compilePattern(pattern) {
  const anchored = pattern.includes('/');
  const body = pattern.startsWith('/') ? pattern.slice(1) : pattern;
  return { anchored, regex: new RegExp(`^${translateGlob(body)}$`) };
}

/** Compile the include/exclude pair once per query. */
function compileFilter(include, exclude) {
  return {
    include: include.map(compilePattern),
    exclude: exclude.map(compilePattern),
  };
}

/** `filter.zig`'s decision, including "exclude wins over include". */
function filterMatches(filter, name) {
  const base = name.slice(name.lastIndexOf('/') + 1);
  for (const pattern of filter.exclude) {
    if (pattern.regex.test(pattern.anchored ? name : base)) return false;
  }
  if (filter.include.length === 0) return true;
  for (const pattern of filter.include) {
    if (pattern.regex.test(pattern.anchored ? name : base)) return true;
  }
  return false;
}

/**
 * A live staged subscription (`FORMAT.socket.md` § BUILD_STAGES).
 *
 * `connectStageClient()` sends `HELLO` and `SUBSCRIBE_V3`, then exposes every frame as an event:
 * `batch_start` / `change` / `batch_end` for the root stream and `stage_ready` /
 * `stage_batch_start` / `stage_change` / `stage_batch_end` for the producer stage. A builder can
 * acknowledge with `sendBuildStarted()` / `sendBuildDone()`.
 *
 * The root stream is kept as well as the stage stream: a builder needs the generation it is
 * acknowledging, and a consumer may want both the source batch and the artifact batch. Events are
 * delivered in wire order; `nextEvent()` and `events` are for pull-style callers, `onEvent` for a
 * callback-style one.
 */
export class StageClient {
  /**
   * @param {import('node:net').Socket} socket
   * @param {{ stage?: number, builder?: boolean, onEvent?: (event: any) => void }} options
   */
  constructor(socket, { stage = 0, builder = false, onEvent = null } = {}) {
    this.socket = socket;
    this.stage = stage;
    this.builder = builder;
    this.onEvent = onEvent;
    this.serverGeneration = 0n;
    this.closed = false;
    this.buffered = Buffer.alloc(0);
    this.queue = [];
    this.waiters = [];
    this.failure = null;
    this.currentStage = stage;
    this.currentBatch = null;
    this.currentStageBatch = null;

    socket.on('data', chunk => this.#onData(chunk));
    socket.on('error', error => this.#fail(error));
    socket.on('close', () => {
      this.closed = true;
      this.#wake();
    });
  }

  /**
   * Connect, greet, and subscribe.
   *
   * @param {string} socketPath
   * @param {{
   *   stage?: number,
   *   builder?: boolean,
   *   fromBatch?: bigint|number,
   *   fromStageBatch?: bigint|number|null,
   *   include?: string[],
   *   exclude?: string[],
   *   onEvent?: (event: any) => void,
   *   timeoutMs?: number,
   * }} [options] `fromStageBatch: null` selects `SUBSCRIBE_V2` (no stage archive); the default is V3.
   * @returns {Promise<StageClient>}
   */
  static connect(socketPath, options = {}) {
    const {
      stage = 0, builder = false, fromBatch = 0n, fromStageBatch = 0n,
      include = [], exclude = [], timeoutMs = 10_000, onEvent = null,
    } = options;
    return new Promise((resolvePromise, reject) => {
      const socket = connect({ path: socketPath });
      socket.setNoDelay(true);
      const client = new StageClient(socket, { stage, builder, onEvent });
      let connected = false;
      const timer = setTimeout(() => {
        client.close();
        const error = new Error(`daemon did not greet within ${timeoutMs} ms`);
        error.reachable = connected;
        reject(error);
      }, timeoutMs);
      timer.unref?.();

      socket.on('connect', () => {
        connected = true;
        socket.write(frame(KIND.HELLO, helloPayload({ generation: fromBatch })));
        const v2 = fromStageBatch === null;
        socket.write(frame(v2 ? KIND.SUBSCRIBE_V2 : KIND.SUBSCRIBE_V3, v2
          ? subscribeV2Payload({ fromBatch, stage, builder, include, exclude })
          : subscribeV3Payload({
            fromBatch,
            fromStageBatch,
            stage,
            builder,
            include,
            exclude,
          })));
      });
      socket.on('error', () => {});
      const poll = setInterval(() => {
        const hello = client.queue.find(event => event.type === 'hello');
        if (!hello) return;
        clearInterval(poll);
        clearTimeout(timer);
        client.#removeQueued('hello');
        resolvePromise(client);
      }, 0);
      poll.unref?.();
      socket.once('error', error => {
        clearInterval(poll);
        clearTimeout(timer);
        reject(error);
      });
    });
  }

  /** The next event, or a rejection after `timeoutMs` / a protocol error. */
  nextEvent(timeoutMs = 0) {
    if (this.failure) return Promise.reject(this.failure);
    if (this.queue.length > 0) return Promise.resolve(this.queue.shift());
    if (this.closed) return Promise.reject(new Error('the stage connection is closed'));
    if (timeoutMs <= 0) {
      return new Promise((resolve, reject) => this.waiters.push({ resolve, reject }));
    }
    return Promise.race([
      new Promise((resolve, reject) => this.waiters.push({ resolve, reject })),
      new Promise((_, reject) => {
        const timer = setTimeout(() => reject(new Error(`no stage event within ${timeoutMs} ms`)), timeoutMs);
        timer.unref?.();
      }),
    ]);
  }

  /** Pull events until the connection closes. */
  get events() {
    const client = this;
    return {
      [Symbol.asyncIterator]() {
        return {
          async next() {
            try {
              return { value: await client.nextEvent(), done: false };
            } catch (error) {
              if (client.closed && !client.failure) return { value: undefined, done: true };
              throw error;
            }
          },
          async return() {
            client.close();
            return { value: undefined, done: true };
          },
        };
      },
    };
  }

  /** `BUILD_STARTED`: the generation this builder is working from. */
  sendBuildStarted(generation) {
    this.#requireOpen();
    this.socket.write(frame(KIND.BUILD_STARTED, buildStartedPayload(generation)));
  }

  /** `BUILD_DONE`: acknowledge through `generation` with status `ok|failed|cancelled`. */
  sendBuildDone(generation, status = 0) {
    this.#requireOpen();
    if (status !== 0 && status !== 1 && status !== 2) throw new Error(`unknown build status ${status}`);
    this.socket.write(frame(KIND.BUILD_DONE, buildDonePayload(generation, status)));
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    try { this.socket.end(); } catch {}
    try { this.socket.destroy(); } catch {}
    this.#wake();
  }

  #requireOpen() {
    if (this.closed) throw new Error('the stage connection is closed');
    if (this.failure) throw this.failure;
  }

  #removeQueued(type) {
    this.queue = this.queue.filter(event => event.type !== type);
  }

  #emit(event) {
    this.onEvent?.(event);
    this.queue.push(event);
    this.#wake();
  }

  #wake() {
    while (this.waiters.length > 0 && this.queue.length > 0) {
      this.waiters.shift().resolve(this.queue.shift());
    }
    if (this.closed) {
      while (this.waiters.length > 0) this.waiters.shift().reject(new Error('the stage connection is closed'));
    }
  }

  #fail(error) {
    this.failure = error;
    while (this.waiters.length > 0) this.waiters.shift().reject(error);
  }

  #onData(chunk) {
    this.buffered = Buffer.concat([this.buffered, chunk]);
    try {
      while (this.buffered.length >= FRAME_HEADER) {
        const length = this.buffered.readUInt32LE(4);
        if (length > MAX_FRAME) throw new Error(`daemon sent a ${length}-byte frame; the limit is ${MAX_FRAME}`);
        if (this.buffered.length < FRAME_HEADER + length) return;
        const kind = this.buffered.readUInt16LE(0);
        const payload = this.buffered.subarray(FRAME_HEADER, FRAME_HEADER + length);
        this.buffered = this.buffered.subarray(FRAME_HEADER + length);
        this.#dispatch(kind, payload);
      }
    } catch (error) {
      this.#fail(error);
      this.close();
    }
  }

  #dispatch(kind, payload) {
    switch (kind) {
      case KIND.HELLO: {
        if (payload.length !== HELLO_PAYLOAD) throw new Error('daemon sent a short HELLO');
        const protocol = payload.readUInt16LE(0);
        if (protocol >>> 8 !== PROTOCOL >>> 8) throw new Error(`daemon speaks protocol 0x${protocol.toString(16)}`);
        if (payload.readUInt16LE(2) !== ENTRY_SIZE) throw new Error('daemon uses a different entry size');
        if (payload.readUInt8(4) !== 0) throw new Error('daemon uses a different hash');
        this.serverGeneration = payload.readBigUInt64LE(8);
        this.#emit({ type: 'hello', generation: this.serverGeneration, protocol });
        return;
      }
      case KIND.STATE:
        this.#emit({ type: 'state', payload });
        return;
      case KIND.GIT_EVENT:
        this.#emit({ type: 'git_event', kind: payload.readUInt8(2), payload });
        return;
      case KIND.PING:
        this.socket.write(frame(KIND.PONG, Buffer.alloc(0)));
        return;
      case KIND.PONG:
        return;
      case KIND.START_BATCH:
        if (payload.length !== 16) throw new Error('daemon sent a short START_BATCH');
        this.currentBatch = { generation: payload.readBigUInt64LE(0), parent: payload.readBigUInt64LE(8) };
        this.#emit({ type: 'batch_start', ...this.currentBatch });
        return;
      case KIND.CHANGE_ENTRY: {
        const entry = parseEntry(payload);
        this.#emit({ type: 'change', ...entry });
        return;
      }
      case KIND.END_BATCH: {
        if (payload.length !== 40) throw new Error('daemon sent a short END_BATCH');
        const event = {
          type: 'batch_end',
          generation: payload.readBigUInt64LE(0),
          added: payload.readBigUInt64LE(8),
          changed: payload.readBigUInt64LE(16),
          deleted: payload.readBigUInt64LE(24),
          changesHash: payload.readBigUInt64LE(32),
        };
        this.currentBatch = null;
        this.#emit(event);
        return;
      }
      case KIND.STAGE_READY:
        if (payload.length !== 18) throw new Error('daemon sent a short STAGE_READY');
        this.#emit({
          type: 'stage_ready',
          stage: payload.readUInt16LE(0),
          headBatch: payload.readBigUInt64LE(2),
          releasedThrough: payload.readBigUInt64LE(10),
        });
        return;
      case KIND.STAGE_BATCH_START: {
        const start = parseStageBatchStart(payload);
        this.currentStage = start.stage;
        this.currentStageBatch = start;
        this.#emit({ type: 'stage_batch_start', ...start });
        return;
      }
      case KIND.STAGE_CHANGE_ENTRY: {
        const entry = parseEntry(payload);
        this.#emit({ type: 'stage_change', stage: this.currentStage, ...entry });
        return;
      }
      case KIND.STAGE_BATCH_END: {
        const end = parseStageBatchEnd(payload);
        this.currentStageBatch = null;
        this.#emit({ type: 'stage_batch_end', ...end });
        return;
      }
      case KIND.ERROR: {
        if (payload.length < 2) throw new Error('daemon sent a short ERROR');
        const code = payload.readUInt16LE(0);
        const detail = payload.subarray(2).toString('utf8');
        const error = new Error(`daemon refused the subscribe (${errorWord(code)}): ${detail}`);
        error.code = errorWord(code);
        throw error;
      }
      default:
        throw new Error(`daemon sent unknown frame kind 0x${kind.toString(16)}`);
    }
  }
}

/**
 * Replay `CHANGE_ENTRY` frames after `fromBatch` into `baseline`, and resolve
 * when the replay reaches the generation the daemon greeted with.
 *
 * Returns `{ names, head }`; `names` is a Map of name → flags. Throws on an
 * unreachable socket, an `ERROR` frame, a malformed frame or a timeout. The
 * thrown error carries `reachable: true` once the connection was established,
 * and `code` is the `ERROR` word when the daemon sent one.
 *
 * When `head === fromBatch`, there is nothing to replay and the baseline is
 * returned immediately. A caller with no baseline must pass `fromBatch: 0n`.
 */
export function replayNames(socketPath, {
  fromBatch = 0n,
  include = [],
  exclude = [],
  baseline = null,
  timeoutMs = 10_000,
} = {}) {
  return new Promise((resolvePromise, reject) => {
    const names = new Map(baseline ?? []);
    let buffered = Buffer.alloc(0);
    let head = null;
    let settled = false;
    let connected = false;

    const socket = connect({ path: socketPath });
    socket.setNoDelay(true);

    const timer = setTimeout(() => {
      fail(new Error(`daemon did not finish the replay within ${timeoutMs} ms`));
    }, timeoutMs);
    timer.unref?.();

    function finish(namesOut, generation) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.end();
      socket.destroy();
      resolvePromise({ names: namesOut, head: generation });
    }

    function fail(error) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try {
        error.reachable = connected;
      } catch {
        // A frozen error object is still a rejection; the flag is best effort.
      }
      socket.destroy();
      reject(error);
    }

    function onMessage(kind, payload) {
      switch (kind) {
        case KIND.HELLO: {
          if (payload.length !== HELLO_PAYLOAD) {
            throw new Error(`daemon greeted with ${payload.length} bytes, not 24`);
          }
          const protocol = payload.readUInt16LE(0);
          const entrySize = payload.readUInt16LE(2);
          const hashAlgorithm = payload.readUInt8(4);
          if (protocol >>> 8 !== PROTOCOL >>> 8) {
            const error = new Error(`daemon speaks protocol 0x${protocol.toString(16)}; this client needs major 1`);
            error.code = 'protocol';
            throw error;
          }
          if (entrySize !== ENTRY_SIZE) {
            const error = new Error(`daemon uses ${entrySize}-byte entries, not ${ENTRY_SIZE}`);
            error.code = 'unsupported-entry-size';
            throw error;
          }
          if (hashAlgorithm !== 0) {
            const error = new Error(`daemon hashes with algorithm ${hashAlgorithm}, not wyhash64`);
            error.code = 'unsupported-hash';
            throw error;
          }
          head = payload.readBigUInt64LE(8);
          if (head < fromBatch) {
            const error = new Error(`daemon head ${head} is behind the baseline ${fromBatch}`);
            error.code = 'baseline-ahead';
            throw error;
          }
          if (head === fromBatch) finish(new Map(names), head);
          break;
        }
        case KIND.START_BATCH:
          break;
        case KIND.CHANGE_ENTRY: {
          const { flags, name } = parseEntry(payload);
          if ((flags & CHANGE_DELETED) !== 0 || (flags & FLAG_IS_DIR) !== 0) names.delete(name);
          else names.set(name, flags);
          break;
        }
        case KIND.END_BATCH: {
          if (payload.length < 8) throw new Error('daemon sent a short END_BATCH');
          const number = payload.readBigUInt64LE(0);
          if (head !== null && number >= head) finish(new Map(names), head);
          break;
        }
        case KIND.ERROR: {
          if (payload.length < 2) throw new Error('daemon sent a short ERROR');
          const code = payload.readUInt16LE(0);
          const detail = payload.subarray(2).toString('utf8');
          const error = new Error(`daemon refused the subscribe (${errorWord(code)}): ${detail}`);
          error.code = errorWord(code);
          throw error;
        }
        case KIND.PING:
          socket.write(frame(KIND.PONG, Buffer.alloc(0)));
          break;
        case KIND.PONG:
        case KIND.STATE:
        case KIND.GIT_EVENT:
          break; // informational; the replay still ends at END_BATCH
        default: {
          const error = new Error(`daemon sent unknown frame kind 0x${kind.toString(16)}`);
          error.code = 'protocol';
          throw error;
        }
      }
    }

    socket.on('connect', () => {
      connected = true;
      try {
        // Simultaneous greeting: both sides send HELLO without waiting. The
        // SUBSCRIBE can follow immediately because the server reads in order.
        socket.write(frame(KIND.HELLO, helloPayload({ generation: fromBatch })));
        socket.write(frame(KIND.SUBSCRIBE, subscribePayload({ fromBatch, include, exclude })));
      } catch (error) {
        fail(error);
      }
    });

    socket.on('data', (chunk) => {
      buffered = Buffer.concat([buffered, chunk]);
      try {
        while (buffered.length >= FRAME_HEADER) {
          const kind = buffered.readUInt16LE(0);
          const flags = buffered.readUInt16LE(2);
          const length = buffered.readUInt32LE(4);
          if (flags !== 0) {
            const error = new Error(`daemon set unsupported frame flags 0x${flags.toString(16)}`);
            error.code = 'protocol';
            throw error;
          }
          if (length > MAX_FRAME) {
            const error = new Error(`daemon sent a ${length}-byte frame, over the 1 MiB limit`);
            error.code = 'frame-too-large';
            throw error;
          }
          if (buffered.length < FRAME_HEADER + length) break;
          const payload = buffered.subarray(FRAME_HEADER, FRAME_HEADER + length);
          buffered = buffered.subarray(FRAME_HEADER + length);
          onMessage(kind, payload);
          if (settled) return;
        }
      } catch (error) {
        fail(error);
      }
    });

    socket.on('error', (error) => {
      fail(new Error(`daemon socket ${socketPath}: ${error.message}`));
    });

    socket.on('close', () => {
      if (!settled) fail(new Error('daemon closed the connection before the replay finished'));
    });
  });
}

/**
 * The names the daemon currently has, replayed from `fromBatch` with no
 * baseline. `fromBatch: 0n` (the default) is the full retained history; a root
 * whose oldest batch has been pruned answers `batch-too-old`, which is what
 * `namesForRoot` avoids by bootstrapping from the trio.
 *
 * Patterns are server-side filters (`FORMAT.socket.md` § SUBSCRIBE filter
 * patterns); no baseline is filtered by this function.
 */
export async function queryNames(socketPath, { fromBatch = 0n, include = [], exclude = [], timeoutMs } = {}) {
  const result = await replayNames(socketPath, { fromBatch, include, exclude, timeoutMs });
  return [...result.names.keys()].sort();
}

/**
 * The current names a running daemon has for the root containing `directory`,
 * or `null` when no daemon serves it, the socket is unreachable, or the answer
 * cannot be made complete.
 *
 * The trio is read first as a baseline at generation `g` (when the reader is
 * available), and the replay asks only for the batches after `g`. That is what
 * makes the answer survive batch retention and an `auto` root that was asleep:
 * subscribing wakes the root and the wake scan arrives as the next batch.
 * Without a trio reader (Node today), the fallback is a replay from 0, which is
 * complete only while the daemon still retains batch 1.
 *
 * Names are workspace-relative, `/`-separated, sorted, and include regular files
 * and symlinks; directories are omitted. `include`/`exclude` use the daemon's
 * filter semantics (`filter.zig`, `FORMAT.socket.md` § SUBSCRIBE filter patterns):
 * a pattern without `/` matches the basename at any depth, a pattern with `/` is
 * anchored to the root, and exclude wins over include. They are sent to the
 * daemon and also applied to the trio baseline, so the answer is filtered either
 * way.
 */
export async function namesForRoot(directory, {
  configPath = rootsConfigPath(),
  timeoutMs = 10_000,
  fsMeta = null,
  include = [],
  exclude = [],
} = {}) {
  const record = findRootForPath(directory, { configPath });
  if (record === null) return null;

  const baseline = await trioBaseline(record, fsMeta);
  const fromBatch = baseline?.generation ?? 0n;

  let result;
  try {
    result = await replayNames(record.socket, {
      fromBatch,
      baseline: baseline?.names ?? null,
      include,
      exclude,
      timeoutMs,
    });
  } catch {
    // Unreachable, a protocol error, an old batch window, or a malformed
    // frame: the caller walks the tree. A partial list is never returned.
    return null;
  }

  if (baseline === null && result.head === 0n) return null; // no batch and no trio: nothing trustworthy

  const filter = compileFilter(include, exclude);
  return {
    root: record,
    names: [...result.names.keys()].filter((name) => filterMatches(filter, name)).sort(),
    generation: result.head,
    source: baseline === null ? 'replay' : (result.head === fromBatch ? 'trio' : 'trio+replay'),
  };
}
