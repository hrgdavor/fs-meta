#!/usr/bin/env bun
// The vendored .gitignore vectors, run against the copy of the matcher this project ships.
//
//   bun test test
//
// Two JS matchers exist in this ecosystem and only one was measured: gitignore/js/gitignore.mjs has its own runner, while
// fs-meta/js/gitignore.mjs is a copy that had already drifted by four fixes before this test existed. The fixture is
// vendored from gitignore v0.2.0 (the version build.zig.zon pins), so refreshing the pin and forgetting the copy now fails
// here instead of silently changing which files a walk skips.
import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { parseGitignore, GitIgnoreRules } from '../js/gitignore.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const vectors = JSON.parse(readFileSync(join(here, '..', 'conformance', 'gitignore-vectors.json'), 'utf8'));

describe('the vendored .gitignore vectors', () => {
  for (const testCase of vectors.cases) {
    test(testCase.name, () => {
      // Shallowest file first: GitIgnoreRules consults its stack from the top, so the deepest file answers first.
      const files = [...testCase.ruleFiles].sort(
        (left, right) => left.dir.split('/').length - right.dir.split('/').length,
      );
      const rules = new GitIgnoreRules();
      for (const file of files) {
        rules.push(parseGitignore(file.dir, file.rules));
      }
      const decision = rules.decide(testCase.path, testCase.isDir);
      const observed = decision === true ? 'exclude' : decision === false ? 'include' : 'no-opinion';
      expect(observed).toBe(testCase.expect);
    });
  }
});
