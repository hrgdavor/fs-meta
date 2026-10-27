#!/usr/bin/env bun
// Generate the v2 conformance vectors from the reference engine.
//
//   bun fs-meta/conformance/gen-vectors-v2.mjs
//
// Each case starts from a trio the **engine published** for a small tree — two files and a directory — so the `ok`
// case is not a hand-written fixture that happens to verify, it is a real generation. Every other case is that trio
// with exactly one thing broken, and the expected verdict is the one `fsmeta verify` reports. The case is written to
// `.tmp/vectors/<name>/.fs-meta/` and checked against the reference before it is recorded, so the file cannot
// describe behaviour the engine does not have.
//
// The output carries the three files as text/hex, no hashes: a reader compares bytes, and the hashes are inside the
// bytes it compares.
import { spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
// Generated under Bun, whose native hash is the same std.hash.Wyhash the engine calls.
import { wyhash64Hex } from "../js/layout.mjs";

const module_dir = join(import.meta.dir, "..");
const engine = process.env.FSMETA ?? join(module_dir, "zig-out", "bin", process.platform === "win32" ? "fsmeta.exe" : "fsmeta");
// Inside the module: the engine s absolute-path handling refuses a scratch tree outside it, and a generator that cannot run is worse than one with a scratch directory.`nconst scratch = join(module_dir, ".tmp", "vectors");
const out = join(import.meta.dir, "fsmeta-vectors-v2.json");

const run = (command, cwd) => {
  const result = spawnSync(engine, command, { cwd, stdio: ["ignore", "pipe", "pipe"] });
  return { status: result.status, output: String(result.stdout ?? ""), error: String(result.stderr ?? "") };
};
const must = (command, cwd) => {
  const result = run(command, cwd);
  if (result.status !== 0 && !result.output.includes("ok")) {
    throw new Error(`${command.join(" ")} failed in ${cwd}: ${result.output}${result.error}`);
  }
  return result.output;
};

// ---- the tree the valid case describes
// Inside the module: the engine refuses a scratch tree outside it (a known absolute-path limitation), and a
// generator that cannot run is worse than one with a scratch directory.
const scratch = join(module_dir, ".tmp", "vectors");
rmSync(scratch, { recursive: true, force: true });
const tree = join(scratch, "tree");
mkdirSync(join(tree, "src"), { recursive: true });
writeFileSync(join(tree, "a.txt"), "hello\n");
writeFileSync(join(tree, "src", "b.java"), "class B {}\n");
must(["refresh", tree, "--updated", "2026-10-19T00:00:00Z", "--hash", "text"], module_dir);
const valid = {
  meta: readFileSync(join(tree, ".fs-meta", "files.meta")),
  txt: readFileSync(join(tree, ".fs-meta", "files.txt")),
  json: readFileSync(join(tree, ".fs-meta", "files.json"), "utf8"),
};

// ---- the boundary rule (FORMAT.md § 16): a nested repository is not described
// A second real generation, from a tree that contains a clone. The trio must validate `ok` *and* the clone's name
// must be absent from it — a vector that only checked the verdict would not distinguish "the rule ran" from "the
// tree happened to have nothing nested".
const nested_tree = join(scratch, "nested-repository");
mkdirSync(join(nested_tree, "clone", ".git", "objects"), { recursive: true });
writeFileSync(join(nested_tree, "visible.txt"), "hello\n");
writeFileSync(join(nested_tree, "clone", ".git", "HEAD"), "ref: refs/heads/main\n");
writeFileSync(join(nested_tree, "clone", "secret.txt"), "not described\n");
must(["refresh", nested_tree, "--updated", "2026-10-19T00:00:01Z", "--hash", "text"], module_dir);
const nested = {
  meta: readFileSync(join(nested_tree, ".fs-meta", "files.meta")),
  txt: readFileSync(join(nested_tree, ".fs-meta", "files.txt")),
  json: readFileSync(join(nested_tree, ".fs-meta", "files.json"), "utf8"),
};
if (nested.txt.includes("clone") || nested.txt.includes("secret.txt")) {
  throw new Error(`the boundary rule did not hold: ${nested.txt}`);
}
if (!nested.json.includes('"nestedRepos": true')) {
  throw new Error(`the boundary rule was not recorded in files.json: ${nested.json}`);
}

const cases = [];
function add(name, expect, files) {
  const dir = join(scratch, name);
  mkdirSync(join(dir, ".fs-meta"), { recursive: true });
  writeFileSync(join(dir, ".fs-meta", "files.meta"), files.meta);
  writeFileSync(join(dir, ".fs-meta", "files.txt"), files.txt);
  writeFileSync(join(dir, ".fs-meta", "files.json"), files.json);
  const observed = run(["verify", dir], module_dir).output.trim();
  const verdict = observed.split(/[:(]/)[0].trim();
  if (verdict !== expect) {
    throw new Error(`${name}: expected ${expect}, engine says ${observed}`);
  }
  cases.push({
    name,
    expect,
    json: files.json,
    txt: files.txt.toString("utf8"),
    meta: files.meta.toString("hex"),
  });
  console.log(`  ${name.padEnd(24)} ${expect}`);
}

// A mutation of `files.meta` that must survive the whole-file check: the sidekick commitment is rebuilt around it
// so the case reaches the per-entry validation the case is about.
const mutateMeta = (mutate) => {
  const meta = Buffer.from(valid.meta);
  mutate(meta);
  const value = doc();
  value.meta = { ...value.meta, bytes: meta.length, wyhash: wyhash64Hex(meta) };
  return { meta, json: JSON.stringify(value, null, 2) + "\n" };
};

const mutated = (changes) => ({
  meta: changes.meta ?? valid.meta,
  txt: changes.txt ?? valid.txt,
  json: changes.json ?? valid.json,
});
const doc = () => JSON.parse(valid.json);
const withJson = (mutate) => {
  const value = doc();
  mutate(value);
  return JSON.stringify(value, null, 2) + "\n";
};

console.log("verifying the cases against the reference:");
add("ok", "ok", mutated({}));
// The boundary rule's vector: a real generation from a tree with a nested clone. `ok` plus the absence of the
// clone's names is the pair a reader can check; the `nestedRepos` record is in the json bytes.
add("ok-nested-repository", "ok", { meta: nested.meta, txt: nested.txt, json: nested.json });
add("unsupported-format", "unsupported-format", mutated({ json: withJson((value) => (value.format = "other")) }));
add("unsupported-version", "unsupported-version", mutated({ json: withJson((value) => (value.version = 2)) }));
add("unsupported-entry-size", "unsupported-entry-size", mutated({ json: withJson((value) => (value.entrySize = 48)) }));
add("unsupported-hash", "unsupported-hash", mutated({ json: withJson((value) => (value.hash.content = "sha256")) }));
add("meta-size-mismatch", "meta-size-mismatch", mutated({ meta: valid.meta.subarray(0, valid.meta.length - 8) }));
add("meta-hash-mismatch", "meta-hash-mismatch", mutated({ meta: (() => {
  const copy = Buffer.from(valid.meta);
  copy[0] ^= 0xff;
  return copy;
})() }));
add("txt-size-mismatch", "txt-size-mismatch", mutated({ txt: valid.txt.subarray(0, valid.txt.length - 1) }));
add("txt-hash-mismatch", "txt-hash-mismatch", mutated({ txt: (() => {
  const copy = Buffer.from(valid.txt);
  copy[0] = "z".charCodeAt(0);
  return copy;
})() }));
add("entry-out-of-range", "entry-out-of-range", mutated(mutateMeta((meta) => meta.writeBigUInt64LE(9999n, 32))));
add("name-hash-mismatch", "name-hash-mismatch", mutated(mutateMeta((meta) => meta.writeBigUInt64LE(meta.readBigUInt64LE(24) ^ 1n, 24))));
add("invalid-flags", "invalid-flags", mutated(mutateMeta((meta) => meta.writeUInt32LE(0, 44))));
add("unknown-json-keys-preserved", "ok", mutated({
  json: withJson((value) => {
    value.xTool = { note: "preserved", n: 1 };
  }),
}));
add("torn-publish-old-json-new-data", "meta-hash-mismatch", mutated({
  // The commit record is the json: data files newer than it is the crash case, modelled by hashing different bytes.
  meta: (() => {
    const copy = Buffer.from(valid.meta);
    copy[copy.length - 1] ^= 0xff;
    return copy;
  })(),
}));

const document = {
  version: 1,
  format: "fs-meta",
  generatedBy: "fs-meta/conformance/gen-vectors-v2.mjs (Zig reference)",
  tree: { files: 3, directories: 1 },
  note: "Each case is `<name>/.fs-meta/{files.meta,files.txt,files.json}`; files.meta is hex, files.txt is the text (each name LF-terminated), files.json is as written. A reader materialises the three, runs its validation, and must report `expect`.",
  cases,
};
writeFileSync(out, JSON.stringify(document, null, 2) + "\n");
console.log(`\n${cases.length} cases written to ${out.replace(/\\/g, "/")}`);
console.log("generated in " + (process.uptime() * 1000).toFixed(0) + "ms");