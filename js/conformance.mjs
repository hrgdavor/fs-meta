#!/usr/bin/env bun
// The Bun port against the v2 conformance vectors.
//
//   bun fs-meta/js/conformance.mjs
//
// This is the port's definition of done, and today it is a report card: each case is materialised in a temp
// directory and handed to the port's own opener, and the verdict the port produces is compared with the one the
// format requires. A case the port cannot classify, accepts when it should reject, or rejects for the wrong reason
// is a line with the reason, not a silent pass.
//
// Exit code 1 when anything disagrees, so it can become the gate the moment the port starts passing: no test file
// needs to be rewritten when it does.
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { loadTrio } from "./fsmeta.mjs";

const vectors = JSON.parse(readFileSync(new URL("../conformance/fsmeta-vectors-v2.json", import.meta.url), "utf8"));

const results = [];
for (const testCase of vectors.cases) {
  const root = mkdtempSync(join(tmpdir(), "fsmeta-v2-"));
  try {
    const metaDir = join(root, ".fs-meta");
    mkdirSync(metaDir, { recursive: true });
    writeFileSync(join(metaDir, "files.meta"), Buffer.from(testCase.meta, "hex"));
    writeFileSync(join(metaDir, "files.txt"), testCase.txt);
    writeFileSync(join(metaDir, "files.json"), testCase.json);

    let observed;
    try {
      const trio = loadTrio(metaDir);
      // The port may answer with a verdict, with entries, or with a plain object: take whatever it says, and
      // record the shape so the next change has something to work against.
      if (trio === null || trio === undefined) observed = "null";
      else if (typeof trio === "string") observed = trio;
      else if (typeof trio.verdict === "string") observed = trio.verdict;
      else if (Array.isArray(trio.entries) || Array.isArray(trio.files)) observed = "ok";
      else observed = "ok (" + Object.keys(trio).join(",") + ")";
    } catch (error) {
      observed = "threw: " + String(error.message ?? error);
    }

    results.push({ name: testCase.name, expect: testCase.expect, observed, pass: observed === testCase.expect });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

console.log(`\n## Bun port vs ${vectors.cases.length} conformance vectors\n`);
console.log("| case | expected | observed | |");
console.log("| ---- | -------- | -------- |-|");
for (const row of results) {
  console.log(`| ${row.name} | ${row.expect} | ${row.observed.replace(/\|/g, "\\|")} | ${row.pass ? "pass" : "**fail**"} |`);
}

const passed = results.filter((row) => row.pass).length;
const summary = {
  okAccepted: results.filter((row) => row.expect === "ok" && row.pass).length,
  rejected: results.filter((row) => row.expect !== "ok" && row.pass).length,
  total: results.length,
};
console.log(`\n${passed}/${results.length} cases agree (${summary.okAccepted} valid trios, ${summary.rejected} rejections)`);
console.log(`bun conformance checked in ${Math.round(performance.now())}ms`);

if (passed !== results.length) process.exit(1);