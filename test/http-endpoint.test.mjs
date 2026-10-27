#!/usr/bin/env bun
// The HTTP endpoint of `fsmeta serve --http`: socket.test.mjs covers the binary protocol on the unix
// socket, and this suite covers the browser side of the same run — a socutil server that serves its UI
// at `/` and lists the socket as JSON at `/api/sockets`. The socket file is `<root>/.fs-meta/socket`,
// literally named `socket`, so its API name is `<dir-name>.<file-name>` = `fs-meta.socket`.
//
//   bun test test/http-endpoint.test.mjs
//
// The suite starts the server with `--http=0`, which asks the OS for any free port, so two runs — or two
// agents in one session — cannot collide. The port is not assumed: it is read from the
// `socutil listening on http://127.0.0.1:<port>/` line socutil prints on the server's stdout. Every wait
// is bounded; the server is killed in a finally, and its output is attached to any failure so a server
// that refused to listen is not reported as a bare timeout.
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

/** The line socutil prints once it has bound, with the port the OS actually gave it. */
const LISTEN_LINE = /socutil listening on http:\/\/127\.0\.0\.1:(\d+)\//;

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

/** Start `fsmeta serve <root> [extra...]`; its output is captured for port discovery and failure messages. */
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
// Port discovery and the endpoint, each within a bound
// ──────────────────────────────────────────────

/**
 * Read the port the server actually bound from its stdout. `--http=0` means the port is not ours to
 * choose, so the announcement is the only source of truth. Polls because the HTTP thread starts with
 * `serve` and announces after it binds.
 */
async function waitForPort(server, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const match = LISTEN_LINE.exec(server.output.text);
    if (match) return Number(match[1]);
    await Bun.sleep(20);
  }
  throw new Error(`the server did not announce a listening port within ${timeoutMs}ms\nserver output:\n${server.output.text}`);
}

/** `fetch` with its own timeout, so a stalled connection cannot outlive the poll that made it. */
function get(origin, path) {
  return fetch(`${origin}${path}`, { signal: AbortSignal.timeout(1000) });
}

/**
 * Poll `/` until it answers 200. Readiness is the endpoint answering, not a sleep: the socutil thread
 * starts with `serve`, so the first attempts can be refused or fail while it binds.
 */
async function waitForHttp(origin, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  let last = 'no attempt';
  while (Date.now() < deadline) {
    try {
      const response = await get(origin, '/');
      if (response.status === 200) return response;
      last = `HTTP ${response.status}`;
    } catch (error) {
      last = error.message;
    }
    await Bun.sleep(50);
  }
  throw new Error(`${origin}/ did not answer 200 within ${timeoutMs}ms: ${last}`);
}

/**
 * Poll `/api/sockets` until it lists the socket. The HTTP thread starts before the unix socket is bound,
 * and the listing is a fresh scan on every request, so a 200 on `/` does not yet prove the socket file
 * exists; the listing appearing is the endpoint's own readiness signal for the part under test.
 */
async function waitForListing(origin, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  let last = 'no attempt';
  while (Date.now() < deadline) {
    try {
      const response = await get(origin, '/api/sockets');
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
  throw new Error(`${origin}/api/sockets did not list the fs-meta socket within ${timeoutMs}ms: ${last}`);
}

// ──────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────

describe('fsmeta serve --http=0', () => {
  test(
    'serves the socutil UI and lists the fs-meta socket as JSON',
    async () => {
      const root = twoFileTree();
      const server = startServer(root, ['--http=0']);
      try {
        const port = await waitForPort(server);
        const origin = `http://127.0.0.1:${port}`;
        console.log(`fsmeta serve --http=0 bound http://127.0.0.1:${port}/`);

        const page = await waitForHttp(origin);
        expect(page.headers.get('content-type')).toContain('text/html');
        const html = await page.text();
        expect(html.toLowerCase()).toContain('socutil');

        const listing = await waitForListing(origin);
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
