#!/usr/bin/env bun
// Detailed benchmark of the fs-meta engine against a real tree.
//
//   bun fs-meta/bench/bench.mjs <tree> [--repeat 7] [--label name] [--engine path]
//
// Measures the four operations a consumer performs, reports min/median/mean/max over repetitions, and prints a
// Markdown table that can be pasted into `doc/benchmark.md`. Composition (files, directories, bytes) is counted by
// this script, skipping the directories a tree does not describe: `.git`, `node_modules`, `target`, build output
// and the trio itself.
//
// The cold `refresh` is measured with the trio removed before each repetition, because that is the real cold
// start: no `.fs-meta` at all. The warm one runs against the trio the cold pass just published, so it measures
// exactly the "nothing changed" cost — the number this project lives or dies by.
import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, rmSync, statSync } from "node:fs";
import { join } from "node:path";

const argv = process.argv.slice(2);
const tree = argv[0];
if (!tree || tree.startsWith("--")) {
  console.error("usage: bun fs-meta/bench/bench.mjs <tree> [--repeat 7] [--label name] [--engine path]");
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
const repeat = Number(flag("--repeat", "7"));
const label = flag("--label", tree);
if (!existsSync(engine)) {
  console.error("no engine at " + engine + " — build it first (zig build -Doptimize=ReleaseFast)");
  process.exit(2);
}


// `--prepare`: install the tree's declared dependencies, so a benchmark of a commit can be repeated rather than
// relying on whatever `node_modules` happens to be lying around. Skips `node_modules` itself and any build output.
function prepareTree(root) {
  const started = performance.now();
  let installs = 0;
  const visit = (dir) => {
    if (existsSync(join(dir, "package.json"))) {
      const result = spawnSync("npm", ["install", "--ignore-scripts", "--no-audit", "--no-fund", "--loglevel=error"], {
        cwd: dir,
        stdio: ["ignore", "ignore", "pipe"],
      });
      if (result.status !== 0) {
        throw new Error(`npm install in ${dir} failed: ${String(result.stderr ?? "")}`);
      }
      installs += 1;
    }
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (!entry.isDirectory() || SKIP.has(entry.name)) continue;
      visit(join(dir, entry.name));
    }
  };
  visit(root);
  return { installs, ms: performance.now() - started };
}
const SKIP = new Set([".git", "node_modules", "target", "zig-out", "zig-cache", ".zig-cache", ".fs-meta", ".tmp"]);
const updates = "2026-10-18T00:00:00Z";

function compose(root) {
  let files = 0;
  let directories = 0;
  let bytes = 0;
  const walk = (path) => {
    for (const entry of readdirSync(path, { withFileTypes: true })) {
      if (SKIP.has(entry.name)) continue;
      const child = join(path, entry.name);
      if (entry.isDirectory()) {
        directories += 1;
        walk(child);
      } else if (entry.isFile()) {
        files += 1;
        try {
          bytes += statSync(child).size;
        } catch {
          // a file that vanished while we were counting is not our problem
        }
      }
    }
  };
  walk(root);
  return { files, directories, bytes };
}

function run(command) {
  const started = performance.now();
  const result = spawnSync(engine, command, { stdio: ["ignore", "pipe", "pipe"] });
  const elapsed = performance.now() - started;
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`${command.join(" ")} exited ${result.status}: ${String(result.stderr ?? "")}`);
  }
  return { elapsed, output: String(result.stdout ?? "") };
}

function summarize(samples) {
  const sorted = [...samples].sort((a, b) => a - b);
  const sum = sorted.reduce((total, value) => total + value, 0);
  const middle = Math.floor(sorted.length / 2);
  const median = sorted.length % 2 === 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle];
  return { min: sorted[0], median, mean: sum / sorted.length, max: sorted[sorted.length - 1] };
}

const measures = [];
function measure(name, command, { cold = false } = {}) {
  const samples = [];
  for (let index = 0; index < repeat; index += 1) {
    if (cold) rmSync(join(tree, ".fs-meta"), { recursive: true, force: true });
    const { elapsed } = run(command);
    samples.push(elapsed);
  }
  measures.push({ name, ...summarize(samples), n: samples.length });
}

if (argv.includes("--prepare")) {
  const prepared = prepareTree(tree);
  console.log(`\nprepared ${prepared.installs} package.json director${prepared.installs === 1 ? "y" : "ies"} in ` +
    `${(prepared.ms / 1000).toFixed(1)} s`);
}
const composition = compose(tree);
const trio = join(tree, ".fs-meta");

// Cold first: it publishes the trio that the warm pass and `verify` then read.
measure("refresh — cold (no trio, publish)", ["refresh", tree, "--updated", updates], { cold: true });
measure("refresh — warm (nothing changed)", ["refresh", tree, "--updated", updates]);
measure("refresh — warm, gitignore off (lists node_modules)", ["refresh", tree, "--updated", updates, "--hash", "none", "--no-gitignore"]);
measure("refresh — cold, per-file stat (naive listing)", ["refresh", tree, "--updated", updates, "--per-file"], { cold: true });
measure("refresh — warm, per-file stat (naive listing)", ["refresh", tree, "--updated", updates, "--per-file"]);
measure("verify (validate the trio)", ["verify", tree]);
measure("scan — no hashing (full walk)", ["scan", tree, "--hash", "none"]);
measure("scan — content hashing", ["scan", tree]);

const names = (() => {
  const result = run(["verify", tree]);
  const match = /ok \((\d+) names\)/.exec(result.output);
  return match ? match[1] : "?";
})();
const nodeModules = (() => {
  const path = join(tree, "node_modules");
  if (!existsSync(path)) return 0;
  let count = 0;
  const walk = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (entry.isDirectory()) walk(join(dir, entry.name));
      else count += 1;
    }
  };
  walk(path);
  return count;
})();
if (nodeModules > 0) console.log(`ignored content: node_modules holds ${nodeModules} files, not in any result below\n`);
const trioBytes = ["files.meta", "files.txt", "files.json"].map((name) => {
  const path = join(trio, name);
  return existsSync(path) ? statSync(path).size : 0;
});

const ms = (value) => value.toFixed(1);
console.log(`\n## ${label}\n`);
console.log(`tree: ${composition.files} files, ${composition.directories} directories, ` +
  `${(composition.bytes / 1024 / 1024).toFixed(1)} MB · trio: ${names} names · ` +
  `${trioBytes[0]} + ${trioBytes[1]} + ${trioBytes[2]} bytes\n`);
console.log("| operation | min | median | mean | max | n |");
console.log("| --------- | --: | -----: | ---: | --: | -: |");
for (const entry of measures) {
  console.log(`| ${entry.name} | ${ms(entry.min)} | ${ms(entry.median)} | ${ms(entry.mean)} | ${ms(entry.max)} | ${entry.n} |`);
}
const warm = measures.find((entry) => entry.name.startsWith("refresh — warm"));
const cold = measures.find((entry) => entry.name.startsWith("refresh — cold"));
if (warm && cold) {
  console.log(`\ncold → warm: ${ms(cold.median)} ms → ${ms(warm.median)} ms ` +
    `(${(warm.median / cold.median * 100).toFixed(0)}% of cold), ` +
    `${(warm.median / composition.files).toFixed(3)} ms per file, ` +
    `${(composition.files / (warm.median / 1000)).toFixed(0)} files/s warm`);
}
console.log(`\nbenchmarked ${measures.reduce((total, entry) => total + entry.n, 0)} runs in ` +
  `${ms(measures.reduce((total, entry) => total + entry.median, 0))} ms of medians`);