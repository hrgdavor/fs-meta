// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//
// `.gitignore` semantics, for the walk `fsmeta scan` performs. The Java port (`GitIgnoreFile`,
// `GitIgnoreRules`) implements the same rules, and conformance/fsmeta-vectors.json's `gitignoreCases`
// materialise the same trees in both ports and compare the file lists — so this file may be read as the
// statement of the rules for either language.
//
// What a trio describes is "the files a project considers ours", and the definition of "not ours" is a
// .gitignore file read per directory. That is this repository's own answer (DEC-044: a hand-written skip
// list is a promise somebody has to remember to keep, and its failure is a silently incomplete index). So
// the rules below are git's:
//
//   * a file's patterns apply only to paths BELOW the directory holding it (which is also why a directory's
//     own .gitignore cannot exclude the directory itself);
//   * a pattern with a separator at the start or in the middle is anchored to that directory; otherwise it
//     matches at any depth;
//   * the LAST matching pattern wins, so `!keep.log` after `*.log` re-includes;
//   * a deeper file beats a shallower one;
//   * a trailing slash means directories only, and a file inside an excluded directory counts as excluded —
//     which is what makes pruning a directory equivalent to ignoring everything below it;
//   * matching is case-SENSITIVE on every platform, deliberately: a trio is written on one machine and read
//     on another, so the ports must agree with each other before they agree with a file system.

import { readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

/** The file name a walk reads per directory. */
export const GITIGNORE_FILE_NAME = '.gitignore';

/**
 * Translates one glob into a regular expression source, git's `**` rules included.
 *
 * Exported because it is the part worth testing on its own: everything else is precedence.
 */
export function translateGlob(glob) {
  let regex = '';
  for (let index = 0; index < glob.length; index++) {
    const c = glob[index];
    if (c === '\\') {
      if (index + 1 < glob.length) {
        regex += escapeRegExp(glob[++index]);
      } else {
        regex += '\\\\';
      }
      continue;
    }
    if (c === '*') {
      const doubleStar = index + 1 < glob.length && glob[index + 1] === '*';
      if (!doubleStar) {
        regex += '[^/]*';
        continue;
      }
      const first = index;
      const second = index + 1;
      const atSegmentStart = first === 0 || glob[first - 1] === '/';
      const followedBySlash = second + 1 < glob.length && glob[second + 1] === '/';
      const atEnd = second + 1 === glob.length;
      if (atSegmentStart && followedBySlash) {
        regex += '(?:.*/)?';          // "**/" — zero or more directories
        index = second + 1;           // consume the '/'
      } else if (atSegmentStart && atEnd) {
        regex += '.*';                // a trailing "/**" matches everything inside
        index = second;
      } else {
        regex += '[^/]*';             // any other consecutive asterisks are just asterisks
        index = second;
      }
      continue;
    }
    if (c === '?') {
      regex += '[^/]';
      continue;
    }
    if (c === '[') {
      const translated = translateCharacterClass(glob, index);
      regex += translated.regex;
      index = translated.close;
      continue;
    }
    regex += escapeRegExp(c);
  }
  return regex;
}

function escapeRegExp(character) {
  return /[.*+?^${}()|[\]\\/]/.test(character) ? `\\${character}` : character;
}

function translateCharacterClass(glob, open) {
  const close = glob.indexOf(']', open + 1);
  if (close < 0) {
    return { regex: '\\[', close: open };    // an unterminated class is a literal '[', like git
  }
  const body = glob.slice(open + 1, close);
  let translated = '[';
  let start = 0;
  if (body.length > 0 && (body[0] === '!' || body[0] === '^')) {
    translated += '^';
    start = 1;
  }
  for (let i = start; i < body.length; i++) {
    const c = body[i];
    if (c === '\\' && i + 1 < body.length) {
      translated += `\\${body[++i]}`;
    } else if (c === '[' || c === ']' || c === '^') {
      translated += `\\${c}`;
    } else {
      translated += c;
    }
  }
  if (translated === '[' || translated === '[^') {
    return { regex: '(?!)', close };          // an empty class matches nothing, as in git
  }
  return { regex: `${translated}]`, close };
}

/** One parsed pattern. */
function parseRule(rawLine) {
  let line = stripTrailingUnescapedSpaces(rawLine);
  if (line.length === 0 || line[0] === '#') {
    return null;
  }
  let negated = false;
  if (line[0] === '!') {
    negated = true;
    line = line.slice(1);
    if (line.length === 0) {
      return null;
    }
  }
  const directoryOnly = line.endsWith('/') && !line.endsWith('\\/');
  if (directoryOnly) {
    line = line.slice(0, -1);
  }
  const anchored = line.startsWith('/') || line.includes('/');
  if (line.startsWith('/')) {
    line = line.slice(1);
  }
  if (line.length === 0) {
    return null;
  }
  return {
    negated,
    directoryOnly,
    // Both anchors are required: Java's `Matcher.matches()` anchors the whole pattern, while JavaScript's
    // `RegExp.test` searches — and a missing `^` lets an anchored pattern match a path *suffix*. That one
    // difference is what the ignore vector `anchored-pattern` caught between the two ports.
    pattern: new RegExp(`^${anchored ? '' : '(?:.*/)?'}${translateGlob(line)}$`),
  };
}

/** Trailing spaces are ignored unless they are escaped with a backslash. */
function stripTrailingUnescapedSpaces(line) {
  let end = line.length;
  const isEscaped = (index) => {
    let backslashes = 0;
    for (let i = index - 1; i >= 0 && line[i] === '\\'; i--) {
      backslashes++;
    }
    return (backslashes & 1) === 1;
  };
  while (end > 0 && line[end - 1] === ' ' && !isEscaped(end - 1)) {
    end--;
  }
  return line.slice(0, end);
}

/**
 * One `.gitignore` file: the directory it governs (relative to the walk root, `''` at the root) and its
 * patterns.
 *
 * @param {string} relativeDirectory the directory holding the file, `/`-separated
 * @param {string} text the file's text
 */
export function parseGitignore(relativeDirectory, text) {
  let directory = relativeDirectory ?? '';
  while (directory.endsWith('/')) {
    directory = directory.slice(0, -1);
  }
  const rules = [];
  for (const line of text.split('\n')) {
    const rule = parseRule(line);
    if (rule !== null) {
      rules.push(rule);
    }
  }
  return {
    relativeDirectory: directory,
    ruleCount: rules.length,

    /**
     * What this file decides about a path relative to the walk root.
     *
     * @returns {boolean|undefined} true to exclude, false to re-include, and `undefined` when no pattern
     *   matches — which is not "included", because a shallower file may still have an opinion
     */
    decide(relativePath, isDirectory) {
      let scoped = relativePath;
      if (directory !== '') {
        const prefix = `${directory}/`;
        if (!relativePath.startsWith(prefix)) {
          return undefined;
        }
        scoped = relativePath.slice(prefix.length);
      }
      for (let index = rules.length - 1; index >= 0; index--) {
        if (matches(rules[index], scoped, isDirectory)) {
          return !rules[index].negated;
        }
      }
      return undefined;
    },
  };
}

function matches(rule, path, isDirectory) {
  if (!rule.directoryOnly) {
    return rule.pattern.test(path);
  }
  if (isDirectory && rule.pattern.test(path)) {
    return true;
  }
  // A file inside an excluded directory counts as excluded, so a directory-only pattern matches any
  // ancestor too. The walk prunes before it gets here; a caller testing a path on its own gets the same
  // answer either way.
  let slash = path.indexOf('/');
  while (slash >= 0) {
    if (rule.pattern.test(path.slice(0, slash))) {
      return true;
    }
    slash = path.indexOf('/', slash + 1);
  }
  return false;
}

/**
 * The rules of one directory, read from disk: an empty file object when the directory has none, so a walk's
 * push/pop pairs stay balanced.
 */
export function readGitignore(directoryPath, relativeDirectory) {
  const file = join(directoryPath, GITIGNORE_FILE_NAME);
  try {
    if (!statSync(file).isFile()) {
      return parseGitignore(relativeDirectory, '');
    }
  } catch {
    return parseGitignore(relativeDirectory, '');
  }
  return parseGitignore(relativeDirectory, readFileSync(file, 'utf8'));
}

/**
 * The `.gitignore` files that apply at one point of a walk — git's precedence in a stack.
 *
 * A walk pushes a directory's file when it enters and pops it when it leaves, so the stack is exactly the
 * set of files governing the path being visited. The deepest file with an opinion decides; within a file the
 * last matching pattern does.
 */
export class GitIgnoreRules {
  #stack = [];

  push(file) {
    this.#stack.push(file);
  }

  pop() {
    this.#stack.pop();
  }

  get depth() {
    return this.#stack.length;
  }

  decide(relativePath, isDirectory) {
    for (let index = this.#stack.length - 1; index >= 0; index--) {
      const decision = this.#stack[index].decide(relativePath, isDirectory);
      if (decision !== undefined) {
        return decision;
      }
    }
    return undefined;
  }

  isIgnored(relativePath, isDirectory) {
    return this.decide(relativePath, isDirectory) === true;
  }
}