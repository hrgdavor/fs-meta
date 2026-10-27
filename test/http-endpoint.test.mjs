#!/usr/bin/env bun
// The HTTP endpoint of `fsmeta serve --http`: socket.test.mjs covers the binary protocol on the unix
// socket, and this suite covers the browser side of the same run — a socutil server that serves its UI
// at `/` and lists the socket as JSON at `/api/sockets`. The socket file is `<root>/.fs-meta/socket`,
// literally named `socket`, so its API name is `<dir-name>.<file-name>` = `fs-meta.socket`.
//
//   bun test test/http-endpoint.test.mjs
//
// The port is deliberately not configurable (`--http` hard-codes 8765), so the suite cannot assume it is
// free: it probes first and skips when another process — a parallel agent, an earlier run — owns the
// port. Every wait is bounded; the server is killed in a finally, and its output is attached to any
// failure so a server that refused to listen is not reported as a bare timeout.
import { afterAll, describe, expect, test } from 'bun:test';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const binary = join(here, '..', 'zig-out', 'bin', process.platform === 'win32' ? 'fsmeta.exe' : 'fsmeta');
if (!existsSync(binary)) {
  throw new Error(`build the engine first: zig build (expected ${binary})`);
}

const HTTP_PORT = 8765;
const HTTP_ORIGIN = `http://127.0.0.1:${HTTP_PORT}`;

const roots = [];
const children = [];
afterAll(async () => {
  for (const child of children) {
    try { child.kill(); } catch {}
  }
  for (const root of roots) rmSync(root, { recursive: true, force: true });
});

/** Scratch under the project's `.tmp/`, the same rule the other integration suites follow. */
function scratch() {
  const base = join(here, '..', '.tmp');
  mkdirSync(base, { recursive: true });
  const dir = mkdtempSync(join(base, 'http-endpoint-'));
  roots.push(dir);
  return dir;
}

/** Publish the tree's current state in a separate process; serve needs a usable trio. */
function publish(root) {
  return execFileSync(binary, ['refresh', root, '--updated', '2026-10-24T00:00:00Z'], {
    encoding: 'utf8',
    cwd: here,
  });
}

/** A tree with a couple of files, which is all the endpoint needs: it lists the socket, not the trio. */
function twoFileTree() {
  const root = scratch();
  mkdirSync(join(root, 'src'));
  writeFileSync(join(root, 'README.md'), '# http endpoint\n');
  writeFileSync(join(root, 'src', 'a.txt'), 'one\n');
  publish(root);
  return root;
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
// The endpoint, waited for within a bound
// ──────────────────────────────────────────────

/** `fetch` with its own timeout, so a stalled connection cannot outlive the poll that made it. */
function get(path) {
  return fetch(`${HTTP_ORIGIN}${path}`, { signal: AbortSignal.timeout(1000) });
}

/**
 * Poll `/` until it answers 200. Readiness is the endpoint answering, not a sleep: the socutil thread
 * starts with `serve`, so the first attempts can be refused or fail while it binds.
 */
async function waitForHttp(timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  let last = 'no attempt';
  while (Date.now() < deadline) {
    try {
      const response = await get('/');
      if (response.status === 200) return response;
      last = `HTTP ${response.status}`;
    } catch (error) {
      last = error.message;
    }
    await Bun.sleep(50);
  }
  throw new Error(`${HTTP_ORIGIN}/ did not answer 200 within ${timeoutMs}ms: ${last}`);
}

/**
 * Poll `/api/sockets` until it lists the socket. The HTTP thread starts before the unix socket is bound,
 * and the listing is a fresh scan on every request, so a 200 on `/` does not yet prove the socket file
 * exists; the listing appearing is the endpoint's own readiness signal for the part under test.
 */
async function waitForListing(timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  let last = 'no attempt';
  while (Date.now() < deadline) {
    try {
      const response = await get('/api/sockets');
      if (response.status === 200) {
        const listing = await response.json();
        if (Array.isArray(listing.sockets) && listing.sockets.length > 0) return listing;
        last = `sockets ${JSON.stringify(listing.sockets)}`;
      } else {
        last = `HTTP ${response.status}`;
      }
    } catch (error) {
      last = error.message;
    }
    await Bun.sleep(50);
  }
  throw new Error(`${HTTP_ORIGIN}/api/sockets did not list the fs-meta socket within ${timeoutMs}ms: ${last}`);
}

// ──────────────────────────────────────────────
// Port availability
// ──────────────────────────────────────────────

/**
 * Whether something already accepts connections on `127.0.0.1:<port>`. A client connect is the probe:
 * it changes nothing on the host. A refused connection is the only answer that means free; an open
 * connection or a silent timeout counts as occupied, because a second listener would test another
 * process's server rather than this suite's.
 */
async function portIsListening(port, timeoutMs = 1500) {
  const attempt = Bun.connect({
    hostname: '127.0.0.1',
    port,
    socket: { open() {}, data() {}, close() {}, error() {} },
  }).then(
    (socket) => {
      try { socket.end(); } catch {}
      return 'listening';
    },
    () => 'free',
  );
  const verdict = await Promise.race([attempt, Bun.sleep(timeoutMs).then(() => 'timeout')]);
  return verdict !== 'free';
}

const portBusy = await portIsListening(HTTP_PORT);
const PORT_REASON = `127.0.0.1:${HTTP_PORT} already accepts connections: \`fsmeta serve --http\` binds that fixed port and another process — a parallel agent or an earlier run — owns it, so the endpoint cannot be tested without taking it over`;
const httpTest = portBusy
  ? (name, fn) => test.skip(`${name} [skipped: ${PORT_REASON}]`, fn)
  : test;

// ──────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────

describe('fsmeta serve --http', () => {
  httpTest(
    'serves the socutil UI and lists the fs-meta socket as JSON',
    async () => {
      const root = twoFileTree();
      const server = startServer(root, ['--http']);
      try {
        const page = await waitForHttp();
        expect(page.headers.get('content-type')).toContain('text/html');
        const html = await page.text();
        expect(html.toLowerCase()).toContain('socutil');

        const listing = await waitForListing();
        expect(listing.dirs).toHaveLength(1);
        expect(listing.dirs[0].name).toBe('fs-meta');
        expect(listing.sockets).toHaveLength(1);
        expect(listing.sockets[0].name).toBe('fs-meta.socket');
        expect(listing.sockets[0].file).toBe('socket');
        expect(listing.sockets[0].dirName).toBe('fs-meta');
        // The listing must describe this scratch root, not a server that happens to share the port.
        expect(normalize(listing.dirs[0].path)).toBe(normalize(join(root, '.fs-meta')));
        expect(normalize(listing.sockets[0].path)).toBe(normalize(join(root, '.fs-meta', 'socket')));
      } catch (error) {
        throw new Error(`${error.message}\nserver output:\n${server.output.text}`);
      } finally {
        await stopServer(server);
      }
    },
    20000,
  );
});
