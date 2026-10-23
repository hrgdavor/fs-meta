#!/usr/bin/env bun
// Watch mode, verified end to end: start the watcher on a tree, move the tree between two commits underneath it,
// and check what it published.
//
//   bun fs-meta/bench/watch-test.mjs <tree> <old> <new> [--watcher path] [--timeout 60000]
//
// Three assertions, and the third is the one a unit test cannot make:
//
//   1. **The watcher boots and publishes** — its bootstrap pass produces a trio.
//   2. **One batch, one publish per move** — a checkout of ~100 files must not produce a publish per file event. A
//      small tolerance is allowed, because the grace window can legitimately split a very long checkout in two.
//   3. **The trio agrees with the walk** — after each move, the names in `files.txt` are exactly the name set of a
//      full walk (`scan --hash none`), the same oracle the manual git-move harness uses.
//
// The watcher is killed at the end; its log is printed when something fails, because a watcher that builds is not
// a watcher that works.
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";

const argv = process.argv.slice(2);
const [tree, oldCommit, newCommit] = argv.filter((value) => !value.startsWith("--"));
const flag = (name, fallback) => {
  const at = argv.indexOf(name);
  return at >= 0 && at + 1 < argv.length ? argv[at + 1] : fallback;
};
const engine = flag("--engine", join(import.meta.dir, "..", "zig-out", "bin", process.platform === "win32" ? "fsmeta.exe" : "fsmeta"));
const watcher = flag("--watcher", join(import.meta.dir, "..", "zig-out", "bin", process.platform === "win32" ? "watcher.exe" : "watcher"));
const timeoutMs = Number(flag("--timeout", "60000"));

if (!tree || !oldCommit || !newCommit) {
  console.error("usage: bun fs-meta/bench/watch-test.mjs <tree> <old> <new> [--watcher path] [--timeout ms]");
  process.exit(2);
}
if (!existsSync(watcher) || !existsSync(engine)) {
  console.error("build both first: zig build -Doptimize=ReleaseFast && zig build watcher");
  process.exit(2);
}

const git = (...args) => {
  const result = spawnSync("git", ["-C", tree, ...args], { stdio: ["ignore", "pipe", "pipe"] });
  if (result.status !== 0) throw new Error(`git ${args.join(" ")}: ${String(result.stderr ?? "")}`);
  return String(result.stdout ?? "");
};

const trioNames = () => {
  const path = join(tree, ".fs-meta", "files.txt");
  return existsSync(path) ? readFileSync(path, "utf8").split("\n").filter((name) => name.length > 0) : [];
};
const walkNames = () => {
  const result = spawnSync(engine, ["scan", tree, "--hash", "none"], { stdio: ["ignore", "pipe", "pipe"] });
  if (result.status !== 0) throw new Error(`scan failed: ${String(result.stderr ?? "")}`);
  return [...String(result.stdout ?? "").matchAll(/^\S+ \d+ \d+ (.+)$/gm)].map((match) => match[1]);
};
const sorted = (list) => [...list].sort();
const same = (left, right) => left.length === right.length && left.every((value, index) => value === right[index]);

const publishes = (log) => (log.match(/published/g) ?? []).length;
const passes = (log) => (log.match(/\[fs-meta\] pass/g) ?? []).length;

async function waitFor(predicate, deadlineMs, label) {
  const started = Date.now();
  while (Date.now() - started < deadlineMs) {
    if (predicate()) return true;
    await Bun.sleep(50);
  }
  console.error(`timed out waiting for ${label}`);
  return false;
}

// A clean start: no trio, so the bootstrap is a cold pass and its publish is unambiguous.
rmSync(join(tree, ".fs-meta"), { recursive: true, force: true });
git("checkout", "--quiet", oldCommit);

let log = "";
const proc = Bun.spawn([watcher], { cwd: tree, stdout: "ignore", stderr: "pipe" });
const drained = (async () => {
  for await (const chunk of proc.stderr) log += new TextDecoder().decode(chunk);
})();

const rows = [];
const record = (label, publishCount, trio, walk) => {
  rows.push({ label, publishes: publishCount, names: trio.length, agree: same(sorted(trio), sorted(walk)), walk: walk.length });
};

try {
  if (!(await waitFor(() => log.includes("watching"), timeoutMs, "the bootstrap"))) throw new Error("no bootstrap");
  record("bootstrap", publishes(log), trioNames(), walkNames());

  const afterBoot = publishes(log);
  git("checkout", "--quiet", newCommit);
  if (!(await waitFor(() => publishes(log) > afterBoot, timeoutMs, `a publish for ${newCommit.slice(0, 7)}`))) {
    throw new Error("the checkout produced no publish");
  }
  await Bun.sleep(300); // let a straggling second batch land, so the count is honest
  record(`checkout ${newCommit.slice(0, 7)}`, publishes(log) - afterBoot, trioNames(), walkNames());

  const afterMove = publishes(log);
  git("checkout", "--quiet", oldCommit);
  if (!(await waitFor(() => publishes(log) > afterMove, timeoutMs, `a publish for ${oldCommit.slice(0, 7)}`))) {
    throw new Error("the way back produced no publish");
  }
  await Bun.sleep(300);
  record(`checkout ${oldCommit.slice(0, 7)}`, publishes(log) - afterMove, trioNames(), walkNames());
} catch (error) {
  // Print what the watcher itself did before rethrowing: "no publish" without its log is not a diagnosis.
  console.error(String(error));
  console.error("--- watcher log (stderr) ---");
  console.error(log);
  throw error;
} finally {
  proc.kill();
  await drained.catch(() => {});
}

const sha = (ref) => git("rev-parse", "--short", ref).trim();
console.log(`\n## watch mode — ${sha(oldCommit)} → ${sha(newCommit)} → ${sha(oldCommit)}\n`);
console.log("| phase | passes | publishes | names | trio == walk |");
console.log("| ----- | -----: | --------: | ----: | ------------ |");
for (const row of rows) {
  console.log(`| ${row.label} | ${passes(log)} | ${row.publishes} | ${row.names} | ${row.agree ? "yes" : "NO"} (${row.walk}) |`);
}
const failed = rows.filter((row) => !row.agree);
const overPublished = rows.filter((row) => row.label !== "bootstrap" && row.publishes > 2);
if (failed.length > 0 || overPublished.length > 0) {
  console.log("\n--- watcher log ---\n" + log.split("\n").slice(-40).join("\n"));
}
console.log(`\n${rows.length} phases, ${failed.length} name-set disagreements, ${overPublished.length} over-publishing phases`);
console.log(`watch test finished in ${passes(log)} passes`);