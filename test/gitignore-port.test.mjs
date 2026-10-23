#!/usr/bin/env bun
// The vendored .gitignore vectors, run against the dependency this project consumes.
//
//   bun test test
//
// fs-meta implements no matcher of its own: the matcher is `@hrg/gitignore` (the gitignore project, whose Zig
// port `build.zig.zon` pins at the same version), consumed here through the package entry point. The fixture is
// vendored from gitignore v0.2.0, so upgrading the dependency without refreshing the vectors — or the reverse —
// fails here instead of silently changing which files a walk skips.
import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { parseGitignore, GitIgnoreRules } from '@hrg/gitignore';

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
