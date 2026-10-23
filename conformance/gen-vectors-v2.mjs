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
import { wyhash64Hex } from "wyhash/js/wyhash64.mjs";

const module_dir = join(import.meta.dir, "..");
const engine = process.env.FSMETA ?? join(module_dir, "zig-out", "bin", process.platform === "win32" ? "fsmeta.exe" : "fsmeta");
const scratch = join(module_dir, "..", ".tmp", "vectors");
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