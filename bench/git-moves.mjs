#!/usr/bin/env bun
// Jump a test project between two commits and check that a cold start survives the git operation.
//
//   bun fs-meta/bench/git-moves.mjs <repo> <old-commit> <new-commit> [--engine path] [--label name]
//
// A move between commits is a **warm** start: the trio exists and describes the tree the developer just left.
// That is the pass being measured, and it is the one a watcher will live on.
//
//   checkout old → bootstrap: build the trio (setup, not measured; this is the cold baseline)
//   checkout new → refresh: the reconciliation under test, and it is warm
//   checkout old → refresh back: the same reconciliation in the other direction
//
// Correctness is asserted against an **independent oracle**: the full walk (`scan --hash none`) must report exactly
// the name set the trio describes, after every move. The cold baseline is kept next to the moves so each warm pass
// is reported as a fraction of the cold start of the *same* tree — the number that shows what a warm start buys.
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";

const argv = process.argv.slice(2);
const positional = argv.filter((value) => !value.startsWith("--") && !argv[argv.indexOf(value) - 1]?.startsWith("--"));
const [repo, oldCommit, newCommit] = positional;
if (!repo || !oldCommit || !newCommit) {
  console.error("usage: bun fs-meta/bench/git-moves.mjs <repo> <old> <new> [--engine path] [--label name]");
  process.exit(2);
}
const flag = (name, fallback) => {
  const at = argv.indexOf(name);
  return at >= 0 && at + 1 < argv.length ? argv[at + 1] : fallback;
};
const engine = flag(
  "--engine",
  join(import.meta.dir, "..", "zig-out", "bin", process.platform === "win32" ? "fsmeta.exe" : "fsmeta"),
);
const label = flag("--label", repo);
const updates = "2026-10-18T00:00:00Z";

function sh(command, args, options = {}) {
  const result = spawnSync(command, args, { cwd: options.cwd, stdio: ["ignore", "pipe", "pipe"] });
  if (result.error) throw result.error;
  if (result.status !== 0 && !options.allowFailure) {
    throw new Error(`${command} ${args.join(" ")} exited ${result.status}: ${String(result.stderr ?? "")}`);
  }
  return String(result.stdout ?? "");
}

function git(...args) {
  return sh("git", args, { cwd: repo });
}

function run(command) {
  const started = performance.now();
  const result = spawnSync(engine, command, { stdio: ["ignore", "pipe", "pipe"] });
  const elapsed = performance.now() - started;
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command.join(" ")} exited ${result.status}: ${String(result.stderr ?? "")}`);
  return { elapsed, output: String(result.stdout ?? "") };
}

const names = (output) => {
  const found = [...output.matchAll(/^(\S+) \d+ \d+ (.+)$/gm)].map((match) => match[2]);
  return found;
};
const trioNames = () => {
  const path = join(repo, ".fs-meta", "files.txt");
  return existsSync(path) ? readFileSync(path, "utf8").split("\n").filter((name) => name.length > 0) : [];
};
const sorted = (list) => [...list].sort();
const same = (left, right) => left.length === right.length && left.every((value, index) => value === right[index]);

const steps = [];
function step(name, { cold = false, setup = false } = {}) {
  if (cold) rmSync(join(repo, ".fs-meta"), { recursive: true, force: true });
  const refresh = run(["refresh", repo, "--updated", updates]);
  const verify = run(["verify", repo]);
  const walk = run(["scan", repo, "--hash", "none"]);
  const fromTrio = sorted(trioNames());
  const fromWalk = sorted(names(walk.output));
  const counts = /added (\d+), removed (\d+), modified (\d+), renamed (\d+)/.exec(refresh.output);
  const generation = /generation (\d+)/.exec(refresh.output);
  steps.push({
    name,
    setup,
    ms: refresh.elapsed,
    generation: generation ? generation[1] : "?",
    names: fromTrio.length,
    added: counts ? counts[1] : "?",
    removed: counts ? counts[2] : "?",
    modified: counts ? counts[3] : "?",
    agree: same(fromTrio, fromWalk),
    walkNames: fromWalk.length,
  });
}

git("checkout", "--quiet", oldCommit);
step(`bootstrap at ${oldCommit.slice(0, 7)} (cold, setup)`, { cold: true, setup: true });
git("checkout", "--quiet", newCommit);
step(`checkout ${newCommit.slice(0, 7)} → refresh (warm)`);
git("checkout", "--quiet", oldCommit);
step(`checkout ${oldCommit.slice(0, 7)} → refresh back (warm)`);

const sha = (ref) => git("rev-parse", "--short", ref).trim();
console.log(`\n## ${label}\n`);
console.log(`moves: ${sha(oldCommit)} → ${sha(newCommit)} → ${sha(oldCommit)} · changed paths: ` +
  `${git("diff", "--name-status", oldCommit, newCommit).trim().split("\n").filter(Boolean).length}\n`);
const cold = steps.find((entry) => entry.setup);
const coldMs = cold ? cold.ms : 0;
console.log("| step | refresh | vs cold | generation | names | added | removed | modified | trio == walk |");
console.log("| ---- | ------: | ------: | ---------: | ----: | ----: | ------: | -------: | ------------ |");
for (const entry of steps) {
  const ratio = entry.setup || coldMs === 0 ? "—" : `${((entry.ms / coldMs) * 100).toFixed(0)}%`;
  console.log(`| ${entry.name} | ${entry.ms.toFixed(1)} ms | ${ratio} | ${entry.generation} | ${entry.names} | ` +
    `${entry.added} | ${entry.removed} | ${entry.modified} | ${entry.agree ? "yes" : "NO"} (${entry.walkNames}) |`);
}
const measured = steps.filter((entry) => !entry.setup);
const failed = steps.filter((entry) => !entry.agree);
const total = measured.reduce((sum, entry) => sum + entry.ms, 0);
console.log(`\n${measured.length} warm moves, ${failed.length} name-set disagreements` +
  (failed.length ? " — " + failed.map((entry) => entry.name).join(", ") : ""));
if (coldMs > 0) {
  console.log(`cold baseline ${coldMs.toFixed(1)} ms (setup) · warm moves ` +
    `${measured.map((entry) => entry.ms.toFixed(1) + " ms").join(" + ")} = ${(total / coldMs * 100).toFixed(0)}% of one cold start`);
}
console.log(`git moves finished in ${total.toFixed(0)} ms of warm refreshes`);