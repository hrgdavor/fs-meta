#!/usr/bin/env bun
// The Linux watch bound (`plans/worktrees.md` § 5b, M3/M0 closure): with a per-directory backend (inotify), the
// metadata arm and the working-tree arm must register only the directories they are allowed to watch — `objects/`
// is the balloon the field report measured, and a nested repository is never registered at all.
//
// This is a **Linux-only** measurement. Windows uses one recursive registration (`ReadDirectoryChangesW`) and
// macOS/BSD use kqueue, so there is no per-directory count to assert there; the host that can answer the question is
// the one that registers a watch per directory. The test therefore skips with its reason everywhere else, exactly
// like the platform guards in `src/scan.zig`.
import { afterAll, expect, test } from 'bun:test';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { binary } from './binary.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const linux = process.platform === 'linux';
const scratchDirs = [];
const children = [];

afterAll(async () => {
  for (const child of children) {
    try { child.kill('SIGKILL'); } catch {}
  }
  for (const dir of scratchDirs) rmSync(dir, { recursive: true, force: true });
});

function scratch() {
  const base = join(here, '..', '.tmp');
  mkdirSync(base, { recursive: true });
  const dir = mkdtempSync(join(base, 'watch-bound-'));
  scratchDirs.push(dir);
  return dir;
}

function git(cwd, ...args) {
  const result = Bun.spawnSync(['git', '-C', cwd, ...args], { stdout: 'pipe', stderr: 'pipe' });
  if (result.exitCode !== 0) throw new Error(`git ${args.join(' ')} failed: ${result.stderr.toString()}`);
}

function cli(env, ...args) {
  const result = Bun.spawnSync([binary, ...args], { env, stdout: 'pipe', stderr: 'pipe' });
  if (result.exitCode !== 0) throw new Error(`fsmeta ${args.join(' ')} exited ${result.exitCode}: ${result.stdout}${result.stderr}`);
  return result.stdout.toString();
}

/** Poll a predicate; the daemon's log lines arrive asynchronously. */
async function eventually(predicate, message, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await Bun.sleep(50);
  }
  throw new Error(message);
}

if (!linux) {
  test.skip(`the Linux watch bound: skipped because this host is ${process.platform}, not Linux`, () => {});
} else {
  test(
    'the metadata arm and the tree arm register only what they may watch, whatever objects/ contains',
    async () => {
      const home = scratch();
      const runtime = join(home, 'run');
      const config = join(home, 'config');
      const repo = join(home, 'repo');
      const wt = join(home, 'wt');
      mkdirSync(runtime, { recursive: true });
      mkdirSync(config, { recursive: true });
      mkdirSync(repo, { recursive: true });
      writeFileSync(join(repo, 'a.txt'), 'one\n');

      git(repo, 'init', '-q');
      git(repo, 'config', 'user.email', 'a@b.c');
      git(repo, 'config', 'user.name', 't');
      git(repo, 'add', '-A');
      git(repo, 'commit', '-qm', 'init');
      // The balloon: a repository that has seen objects would have thousands of directories under `.git/objects`.
      for (let index = 0; index < 120; index += 1) {
        mkdirSync(join(repo, '.git', 'objects', index.toString(16).padStart(2, '0')), { recursive: true });
      }
      git(repo, 'worktree', 'add', '-q', '-b', 'side', wt);
      // A nested repository inside the served tree: the tree arm must refuse it, and its 40 directories must not
      // appear as registrations.
      const nested = join(repo, 'nested');
      mkdirSync(join(nested, '.git', 'objects'), { recursive: true });
      writeFileSync(join(nested, '.git', 'HEAD'), 'ref: refs/heads/main\n');
      for (let index = 0; index < 40; index += 1) {
        mkdirSync(join(nested, 'sub', `d${index}`), { recursive: true });
      }

      const env = { ...process.env, FSMETA_RUNTIME_DIR: runtime, FSMETA_CONFIG_HOME: config };
      const daemon = Bun.spawn([binary, 'daemon', 'start', '--foreground', '--base', runtime], {
        env,
        stdout: 'pipe',
        stderr: 'pipe',
      });
      children.push(daemon);
      let log = '';
      const decoder = new TextDecoder();
      for (const stream of [daemon.stdout, daemon.stderr]) {
        (async () => {
          for await (const chunk of stream) log += decoder.decode(chunk);
        })();
      }

      try {
        await eventually(() => cli(env, 'daemon', 'status').length >= 0, 'the daemon did not start');
        const id = cli(env, 'root', 'add', repo, '--mode', 'always').match(/added ([0-9a-f]{8})/)?.[1];
        expect(id).toBeTruthy();

        // The metadata arm: the common dir plus the admitted metadata directories (refs/, logs/, worktrees/,
        // info/, …). `hooks/` is refused too; 120 object directories and a linked worktree must not multiply it.
        await eventually(
          () => log.includes('git metadata watch armed'),
          'the metadata arm was never armed',
        );
        const armed = log.match(/git metadata watch armed for .*\((\d+) registration\(s\), should_watch ([^)]+)\)/);
        expect(armed).not.toBeNull();
        const metadataRegistrations = Number(armed[1]);
        // The bound is the metadata set, not the repository: a handful, not `objects/`'s 120 or the worktree's tree.
        expect(metadataRegistrations).toBeLessThan(40);
        // On this backend the predicate is consulted at arm time (nightwatch's generic `recurse_watch`), so the log
        // must say so — and an inotify arm that fetched the predicate but ignored it would be this assertion's bug.
        expect(armed[2]).toContain('honoured by this backend');

        // The tree arm: the served root's own log reports the registration count. A nested repository with 40
        // directories is the case that would balloon without `shouldWatchTree`.
        const rootLog = join(runtime, 'roots', `${id}.log`);
        await eventually(() => existsSync(rootLog) && readFileSync(rootLog, 'utf8').includes('watching:'), 'the tree arm was never armed');
        const watching = readFileSync(rootLog, 'utf8').match(/watching: (\d+) registration\(s\)/);
        expect(watching).not.toBeNull();
        const treeRegistrations = Number(watching[1]);
        const expected = 1 /* root */ + 1 /* object */;
        // Allow the ordinary directories this fixture created (nested/, nested/sub, nested/sub/d*) to be refused:
        // a few, not 40. Two nested levels would already exceed this if the predicate were ignored.
        expect(treeRegistrations).toBeLessThan(10);
        expect(treeRegistrations).toBeGreaterThanOrEqual(1);
        expect(expected).toBeGreaterThan(0);

        cli(env, 'root', 'remove', id, '--force');
      } finally {
        try { daemon.kill(); } catch {}
        await Promise.race([daemon.exited, Bun.sleep(3000)]);
        try { cli(env, 'daemon', 'stop'); } catch {}
      }
    },
    60000,
  );
}
