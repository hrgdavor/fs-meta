#!/usr/bin/env bun
// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
// Packaging guard for N7: no service or container template may select a privileged account.
//
//   bun test test/packaging.test.mjs
//
// `plans/non-root-daemon.md` § 4F asks for POSIX service examples with `User=fsmeta`, a Windows service example
// with a low-privilege virtual service account instead of LocalSystem, and a container with a non-root `USER`;
// § 4G asks for "a packaging check that no service template runs as root/LocalSystem". This file is that check.
// It reads `packaging/` as text — no Docker, no network, no build — so it runs on any host, and a failure names
// the template and the line of the offending setting.
//
// The account checks are deliberately *field-shaped* rather than word bans. Every template explains in prose why
// root/LocalSystem is wrong, and those comments must be allowed to stay. A positive setting such as `User=root`,
// a `root` string for a launchd `UserName`, or `obj= "LocalSystem"` fails; an explanatory comment does not.
//
// What this check is not: `src/security.zig` is the enforcement (uid 0 / elevated token / service SID refusal).
// These templates are examples an operator copies, and the test catches the regression before it ships.
import { describe, test } from 'bun:test';
import { ok } from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const PACKAGING = join(here, '..', 'packaging');

const TEMPLATES = {
  systemd: 'systemd/fsmeta.service',
  launchd: 'launchd/hr.hrg.fsmeta.plist',
  winsw: 'windows/fsmeta-service.xml',
  dockerfile: 'container/Dockerfile',
  compose: 'container/compose.yaml',
  readme: 'README.md',
};

/**
 * Fail with the template and line the operator would have to fix. `line` is null only when the problem is a
 * missing setting or a whole-file property, where there is no line to point at.
 */
function check(condition, rel, line, message) {
  ok(condition, line === null ? `packaging/${rel}: ${message}` : `packaging/${rel}:${line}: ${message}`);
}

function load(rel) {
  const abs = join(PACKAGING, ...rel.split('/'));
  try {
    return { rel, text: readFileSync(abs, 'utf8') };
  } catch (cause) {
    throw new Error(`packaging/${rel}: cannot read the template (${abs}): ${cause.message}`);
  }
}

function relPath(abs) {
  return relative(PACKAGING, abs).split(sep).join('/');
}

function lineOf(text, index) {
  return text.slice(0, index).split('\n').length;
}

/** Comment masking keeps every character (and therefore every line number) but blanks the comment bodies. */
function maskRanges(text, ranges) {
  const out = text.split('');
  for (const [start, end] of ranges) {
    for (let i = start; i < end; i += 1) {
      if (out[i] !== '\n' && out[i] !== '\r') out[i] = ' ';
    }
  }
  return out.join('');
}

function maskXmlComments(text) {
  const ranges = [];
  for (const match of text.matchAll(/<!--[\s\S]*?-->/g)) ranges.push([match.index, match.index + match[0].length]);
  return maskRanges(text, ranges);
}

/**
 * Full-line comments only: systemd, Dockerfile and compose explanations are written that way, and a value that
 * contains `#` (there is none today) must not be mangled into a false pass or a false failure.
 */
function maskLineComments(text) {
  const ranges = [];
  let offset = 0;
  for (const line of text.split('\n')) {
    if (line.trimStart().startsWith('#')) ranges.push([offset, offset + line.length]);
    offset += line.length + 1;
  }
  return maskRanges(text, ranges);
}

function maskedFor(rel, text) {
  if (/\.(xml|plist)$/i.test(rel)) return maskXmlComments(text);
  if (/\.md$/i.test(rel)) return text;
  return maskLineComments(text);
}

function commentLines(text, marker = '#') {
  return text
    .split('\n')
    .filter((line) => line.trimStart().startsWith(marker))
    .join('\n');
}

function oneLine(text) {
  return text.replace(/\s+/g, ' ').trim();
}

const FORBIDDEN_ACCOUNTS = new Set([
  'root',
  '0',
  '0:0',
  'root:root',
  'localsystem',
  'localservice',
  'networkservice',
  'system',
  'nt authority\\system',
  'nt authority\\localsystem',
  'nt authority\\networkservice',
]);

/** Return the account when `value` is a privileged one, so the caller can quote exactly what it found. */
function forbiddenAccount(value) {
  const cleaned = value
    .trim()
    .replace(/^["']/, '')
    .replace(/["']$/, '')
    .trim()
    .toLowerCase();
  return FORBIDDEN_ACCOUNTS.has(cleaned) ? cleaned : null;
}

// ---------------------------------------------------------------------------------------------------------------
// systemd
// ---------------------------------------------------------------------------------------------------------------

/** All assignments of a directive, in file order; systemd's last assignment wins for single-value keys. */
function systemdDirectives(text) {
  const masked = maskLineComments(text);
  const directives = new Map();
  masked.split('\n').forEach((line, index) => {
    const match = /^\s*([A-Za-z][A-Za-z0-9]*)\s*=\s*(.*?)\s*$/.exec(line);
    if (!match) return;
    if (!directives.has(match[1])) directives.set(match[1], []);
    directives.get(match[1]).push({ value: match[2], line: index + 1 });
  });
  return directives;
}

function lastDirective(directives, key) {
  const entries = directives.get(key);
  return entries && entries.length > 0 ? entries[entries.length - 1] : null;
}

describe('systemd unit', () => {
  test('runs as a dedicated non-root User= and Group=', () => {
    const { rel, text } = load(TEMPLATES.systemd);
    const directives = systemdDirectives(text);

    for (const key of ['User', 'Group']) {
      const entry = lastDirective(directives, key);
      check(entry !== null, rel, null, `missing ${key}= directive; a unit without one runs as root`);
      check(entry.value.length > 0, rel, entry.line, `${key}= is empty; name a dedicated unprivileged account`);
      check(
        forbiddenAccount(entry.value) === null,
        rel,
        entry.line,
        `${key}= must not be "${entry.value}"; this unit is the N7 non-root example (§ 4F)`,
      );
    }
  });

  test('keeps no-new-privileges, an owner-only umask and AF_UNIX only', () => {
    const { rel, text } = load(TEMPLATES.systemd);
    const directives = systemdDirectives(text);

    const noNewPrivileges = lastDirective(directives, 'NoNewPrivileges');
    check(noNewPrivileges !== null, rel, null, 'missing NoNewPrivileges=; set it to yes (or true)');
    check(
      /^(yes|true|1)$/i.test(noNewPrivileges.value),
      rel,
      noNewPrivileges.line,
      `NoNewPrivileges= must be yes/true (found "${noNewPrivileges.value}")`,
    );

    const umask = lastDirective(directives, 'UMask');
    check(umask !== null, rel, null, 'missing UMask=0077; the socket and .fs-meta files must stay owner-only');
    check(/^0?077$/.test(umask.value), rel, umask.line, `UMask= must be 0077 (found "${umask.value}")`);

    const families = lastDirective(directives, 'RestrictAddressFamilies');
    check(families !== null, rel, null, 'missing RestrictAddressFamilies=; the daemon listens on AF_UNIX');
    const listed = families.value.split(/[\s,]+/).filter(Boolean);
    check(
      listed.includes('AF_UNIX'),
      rel,
      families.line,
      `RestrictAddressFamilies= must include AF_UNIX (found "${families.value}")`,
    );
    // A superset is allowed only when the template documents why a hook needs the extra family; the daemon
    // itself never needs one. Prose is read from comments, which the masking above discarded.
    const documented = commentLines(text, '#');
    for (const extra of listed.filter((family) => family !== 'AF_UNIX')) {
      check(
        documented.includes(extra) && documented.includes('RestrictAddressFamilies'),
        rel,
        families.line,
        `RestrictAddressFamilies= adds ${extra} without a documented reason; add the hook requirement next to ` +
          'the directive, or restrict it to AF_UNIX (§ 4F)',
      );
    }

    for (const key of ['CapabilityBoundingSet', 'AmbientCapabilities']) {
      for (const entry of directives.get(key) ?? []) {
        // `~CAP_X` removes a capability; a bare CAP_X grants one. Only a grant is the regression.
        const granted = entry.value
          .split(/\s+/)
          .filter(Boolean)
          .some((token) => /CAP_/.test(token) && !token.startsWith('~'));
        check(
          !granted,
          rel,
          entry.line,
          `${key}= must not grant a capability (found "${entry.value}"); the daemon needs none`,
        );
      }
    }
  });
});

// ---------------------------------------------------------------------------------------------------------------
// launchd
// ---------------------------------------------------------------------------------------------------------------

function plistString(text, masked, key) {
  const match = new RegExp(`<key>\\s*${key}\\s*</key>\\s*<string>([^<]*)</string>`, 'i').exec(masked);
  return match ? { value: match[1].trim(), line: lineOf(text, match.index) } : null;
}

describe('launchd plist', () => {
  test('names a non-root UserName and GroupName', () => {
    const { rel, text } = load(TEMPLATES.launchd);
    const masked = maskXmlComments(text);

    for (const key of ['UserName', 'GroupName']) {
      const entry = plistString(text, masked, key);
      check(entry !== null, rel, null, `missing <key>${key}</key>; a LaunchDaemon without it runs as root`);
      check(entry.value.length > 0, rel, entry.line, `${key} is empty; name a dedicated unprivileged account`);
      check(
        forbiddenAccount(entry.value) === null,
        rel,
        entry.line,
        `${key} must not be "${entry.value}"; a LaunchDaemon must name a dedicated account (§ 4F)`,
      );
    }

    for (const match of masked.matchAll(/<string>\s*(root|0|root:root)\s*<\/string>/gi)) {
      check(
        false,
        rel,
        lineOf(text, match.index),
        `<string>${match[1]}</string> is a root account value; it must be a dedicated unprivileged account`,
      );
    }
  });
});

// ---------------------------------------------------------------------------------------------------------------
// Windows (WinSW XML)
// ---------------------------------------------------------------------------------------------------------------

const SC_OBJ = /\bobj\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"']+))/gi;

describe('Windows service config', () => {
  test('names a non-SYSTEM account and explains the wrapper requirement', () => {
    const { rel, text } = load(TEMPLATES.winsw);
    const masked = maskXmlComments(text);

    // This file intentionally has no <serviceaccount> block: the account is set by `sc.exe ... obj=` at install
    // time (the file says so), so the documented command is where the account is named. That command is inside a
    // comment, which is why it is read from the raw text while the element checks use the masked text.
    const named = [];
    for (const match of text.matchAll(SC_OBJ)) {
      const value = match[1] ?? match[2] ?? match[3];
      named.push(value);
      check(
        forbiddenAccount(value) === null,
        rel,
        lineOf(text, match.index),
        `sc.exe obj= must not be "${value}"; create the service with "NT SERVICE\\fsmeta" or a dedicated account`,
      );
    }

    for (const match of masked.matchAll(/<(serviceaccount|username|domain)>\s*([\s\S]*?)\s*<\/\1>/gi)) {
      if (match[1].toLowerCase() === 'serviceaccount' && /</.test(match[2])) continue; // child elements checked on their own
      const value = match[2].replace(/<[^>]*>/g, ' ').trim();
      check(
        forbiddenAccount(value) === null,
        rel,
        lineOf(text, match.index),
        `<${match[1]}> must not be "${value}"; the wrapper's installer defaults to LocalSystem (§ 4F)`,
      );
    }

    const virtualServiceAccount = /NT SERVICE\\[A-Za-z0-9_.-]+/i.test(text);
    const allowedNamed = named.some((value) => forbiddenAccount(value) === null);
    check(
      virtualServiceAccount || allowedNamed,
      rel,
      null,
      'no non-SYSTEM account is named; document the sc.exe install with obj= "NT SERVICE\\fsmeta" or a dedicated account',
    );

    check(
      /wrapper/i.test(text),
      rel,
      null,
      'the config must explain that a wrapper (WinSW or similar) is required to host fsmeta.exe as a service',
    );
    check(
      /(StartServiceCtrlDispatcher|native Windows service|error 1053|\b1053\b)/i.test(text),
      rel,
      null,
      'the config must explain that fsmeta.exe has no native service entry point (no StartServiceCtrlDispatcher, ' +
        'so sc.exe alone fails with 1053)',
    );
  });
});

// ---------------------------------------------------------------------------------------------------------------
// Dockerfile
// ---------------------------------------------------------------------------------------------------------------

function dockerArgDefaults(masked) {
  const args = new Map();
  for (const line of masked.split('\n')) {
    const match = /^\s*ARG\s+([A-Za-z_][A-Za-z0-9_]*)(?:=(\S*))?/i.exec(line);
    if (match && match[2] !== undefined) {
      args.set(match[1], match[2].replace(/^["']/, '').replace(/["']$/, ''));
    }
  }
  return args;
}

function resolveDockerVars(value, args) {
  return value.replace(
    /\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}|\$([A-Za-z_][A-Za-z0-9_]*)/g,
    (whole, braced, fallback, bare) => {
      const name = braced ?? bare;
      if (fallback !== undefined) return fallback;
      return args.has(name) ? args.get(name) : whole;
    },
  );
}

/** The USER of the final stage, with build-arg defaults substituted. */
function dockerFinalUser(text) {
  const masked = maskLineComments(text);
  const lines = masked.split('\n');
  const fromLines = [];
  lines.forEach((line, index) => {
    if (/^\s*FROM\s+/i.test(line)) fromLines.push(index);
  });
  const stageStart = fromLines.length > 0 ? fromLines[fromLines.length - 1] + 1 : 0;
  let user = null;
  for (let index = stageStart; index < lines.length; index += 1) {
    const match = /^\s*USER\s+(.+?)\s*$/i.exec(lines[index]);
    // Docker treats `#` as a comment start, so `USER root # note` still runs as root.
    if (match) user = { value: match[1].replace(/\s+#.*$/, '').trim(), line: index + 1 };
  }
  return user === null ? null : { ...user, resolved: resolveDockerVars(user.value, dockerArgDefaults(masked)) };
}

describe('Dockerfile', () => {
  test('ends with a non-root USER', () => {
    const { rel, text } = load(TEMPLATES.dockerfile);
    const user = dockerFinalUser(text);

    check(user !== null, rel, null, 'the final stage has no USER; the image would run as root');
    check(
      !user.resolved.includes('$'),
      rel,
      user.line,
      `USER ${user.value} cannot be resolved to a uid; give the ARG a numeric default (or write the uid literally)`,
    );

    const uid = user.resolved.split(':')[0];
    if (/^\d+$/.test(uid)) {
      check(uid !== '0', rel, user.line, `USER must not be root/0 (found "${user.resolved}")`);
    } else {
      check(forbiddenAccount(uid) === null, rel, user.line, `USER must not be "${uid}"`);
      check(
        /\b(useradd|adduser)\b/i.test(text),
        rel,
        user.line,
        `USER ${uid} is not a numeric uid and no useradd/adduser creates the account in this image`,
      );
    }
  });

  test('requires no privileged mode', () => {
    const { rel, text } = load(TEMPLATES.dockerfile);
    const masked = maskLineComments(text);
    const match = /--privileged/.exec(masked);
    check(
      match === null,
      rel,
      match === null ? null : lineOf(text, match.index),
      '--privileged must not appear in the image; the daemon needs no Linux capabilities (§ 4F)',
    );
  });
});

// ---------------------------------------------------------------------------------------------------------------
// compose
// ---------------------------------------------------------------------------------------------------------------

/** A YAML scalar without its quotes or a trailing comment. */
function yamlScalar(raw) {
  let value = raw.trim();
  if (!value || value.startsWith('#')) return '';
  if (value.startsWith('"') || value.startsWith("'")) {
    const end = value.indexOf(value[0], 1);
    if (end > 0) return value.slice(1, end);
  }
  const comment = value.search(/\s#/);
  if (comment >= 0) value = value.slice(0, comment);
  return value.trim();
}

function yamlSetting(masked, key) {
  let found = null;
  masked.split('\n').forEach((line, index) => {
    const match = /^(\s*)([A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(.*)$/.exec(line);
    if (match && match[2] === key) found = { value: yamlScalar(match[3]), line: index + 1, indent: match[1].length };
  });
  return found;
}

/** List values under `key`, from either a block (`- item`) or a flow (`[a, b]`) sequence. */
function yamlList(masked, key) {
  const lines = masked.split('\n');
  const items = [];
  for (let index = 0; index < lines.length; index += 1) {
    const match = /^(\s*)([A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(.*)$/.exec(lines[index]);
    if (!match || match[2] !== key) continue;
    const indent = match[1].length;
    const inline = yamlScalar(match[3]);
    if (inline) {
      if (/^\[.*\]$/.test(inline)) {
        for (const part of inline.slice(1, -1).split(',')) {
          const value = yamlScalar(part);
          if (value) items.push({ value, line: index + 1 });
        }
      } else {
        items.push({ value: inline, line: index + 1 });
      }
      continue;
    }
    for (let inner = index + 1; inner < lines.length; inner += 1) {
      if (!lines[inner].trim()) continue;
      const item = /^(\s*)-\s*(.*)$/.exec(lines[inner]);
      if (!item || item[1].length <= indent) break;
      items.push({ value: yamlScalar(item[2]), line: inner + 1 });
    }
  }
  return items;
}

function resolveComposeVars(value) {
  return value.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)(?::?-([^}]*))?\}/g, (whole, name, fallback) =>
    fallback !== undefined ? fallback : whole,
  );
}

describe('compose file', () => {
  test('drops capabilities, sets no-new-privileges and does not run as root', () => {
    const { rel, text } = load(TEMPLATES.compose);
    const masked = maskLineComments(text);

    const privileged = yamlSetting(masked, 'privileged');
    check(
      privileged === null || /^(false|no|off)$/i.test(privileged.value),
      rel,
      privileged === null ? null : privileged.line,
      `privileged: must be absent or false (found "${privileged && privileged.value}")`,
    );

    const capDrop = yamlList(masked, 'cap_drop');
    check(
      capDrop.some((item) => item.value.toUpperCase() === 'ALL'),
      rel,
      capDrop.length > 0 ? capDrop[0].line : null,
      'cap_drop must include ALL; the daemon needs no Linux capabilities (§ 4F)',
    );

    const capAdd = yamlList(masked, 'cap_add');
    check(
      capAdd.length === 0,
      rel,
      capAdd.length > 0 ? capAdd[0].line : null,
      `cap_add re-grants a capability ("${capAdd.length > 0 ? capAdd[0].value : ''}"); list none`,
    );

    const securityOpt = yamlList(masked, 'security_opt');
    check(
      securityOpt.some((item) => /^no-new-privileges(?::\s*(?:true|1)|=(?:true|1))?$/i.test(item.value)),
      rel,
      securityOpt.length > 0 ? securityOpt[0].line : null,
      'security_opt must contain no-new-privileges:true (or =true)',
    );

    const user = yamlSetting(masked, 'user');
    if (user !== null) {
      const resolved = resolveComposeVars(user.value);
      check(
        !resolved.includes('$'),
        rel,
        user.line,
        `user: "${user.value}" does not resolve; use a literal uid, or a numeric default such as ` +
          '${FSMETA_UID:-10001} so the account is checkable',
      );
      const uid = resolved.split(':')[0];
      check(
        /^\d+$/.test(uid) ? uid !== '0' : forbiddenAccount(uid) === null,
        rel,
        user.line,
        `user: must not be root/0 (found "${resolved}"); "0:0" and --privileged are not fixes for ownership (§ 4F)`,
      );
    }
  });
});

// ---------------------------------------------------------------------------------------------------------------
// Meta-check across every packaging file
// ---------------------------------------------------------------------------------------------------------------

/**
 * Field-shaped positive settings: an account assignment, never a bare word. Comments are masked before these
 * run, so the templates' explanations of the rule do not fail the check.
 */
const ACCOUNT_PATTERNS = [
  {
    what: 'a systemd User=/Group=',
    pattern: /^\s*(?:User|Group)\s*=\s*["']?(?:root|0|LocalSystem|LocalService|NetworkService|SYSTEM)["']?\s*$/gim,
  },
  { what: 'a container USER', pattern: /^\s*USER\s+["']?(?:root|0)(?:\s|:|["']|$)/gim },
  {
    what: 'a launchd account value',
    pattern: /<key>\s*(?:UserName|GroupName)\s*<\/key>\s*<string>\s*(?:root|0)\s*<\/string>/gi,
  },
  {
    what: 'a Windows <username>',
    pattern: /<username>\s*(?:NT AUTHORITY\\)?(?:LocalSystem|LocalService|NetworkService|SYSTEM)\s*<\/username>/gi,
  },
  {
    what: 'a Windows <serviceaccount>',
    pattern: /<serviceaccount>\s*(?:NT AUTHORITY\\)?(?:LocalSystem|LocalService|NetworkService|SYSTEM)\s*<\/serviceaccount>/gi,
  },
  { what: 'a compose user:', pattern: /^\s*user\s*:\s*["']?(?:root|0(?::0)?)["']?\s*$/gim },
];

/**
 * Markdown has no comment syntax, so prose may quote a forbidden setting while explaining the rule ("never set
 * `User=root`"). A doc is only *positive* when the setting is the line — a fenced example a reader would copy —
 * so these are anchored after the line's leading whitespace.
 */
const DOC_ACCOUNT_PATTERNS = [
  {
    what: 'a systemd User=/Group=',
    pattern: /^\s*(?:User|Group)\s*=\s*["']?(?:root|0|LocalSystem|LocalService|NetworkService|SYSTEM)["']?\s*$/gim,
  },
  { what: 'a container USER', pattern: /^\s*USER\s+["']?(?:root|0)(?:\s|:|["']|$)/gim },
  {
    what: 'a launchd account value',
    pattern: /^\s*<key>\s*(?:UserName|GroupName)\s*<\/key>\s*<string>\s*(?:root|0)\s*<\/string>/gim,
  },
  {
    what: 'a Windows <username>',
    pattern: /^\s*<username>\s*(?:NT AUTHORITY\\)?(?:LocalSystem|LocalService|NetworkService|SYSTEM)\s*<\/username>/gim,
  },
  {
    what: 'a Windows <serviceaccount>',
    pattern: /^\s*<serviceaccount>\s*(?:NT AUTHORITY\\)?(?:LocalSystem|LocalService|NetworkService|SYSTEM)\s*<\/serviceaccount>/gim,
  },
  { what: 'a compose user:', pattern: /^\s*user\s*:\s*["']?(?:root|0(?::0)?)["']?\s*$/gim },
];

function walk(dir) {
  const files = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const abs = join(dir, entry.name);
    if (entry.isDirectory()) files.push(...walk(abs));
    else if (entry.isFile()) files.push(abs);
  }
  return files;
}

describe('packaging meta-check', () => {
  test('no packaging file selects a privileged account', () => {
    const files = walk(PACKAGING);
    const rels = files.map(relPath);
    for (const rel of Object.values(TEMPLATES)) {
      check(rels.includes(rel), rel, null, 'the template is missing from packaging/; the N7 guard cannot read it');
    }

    for (const abs of files) {
      const rel = relPath(abs);
      const text = readFileSync(abs, 'utf8');
      const masked = maskedFor(rel, text);
      // Prose (Markdown) has no comments and no settings; it is checked only in the anchored, copyable shape.
      const isDoc = /\.md$/i.test(rel);
      const patterns = isDoc ? DOC_ACCOUNT_PATTERNS : ACCOUNT_PATTERNS;

      for (const { what, pattern } of patterns) {
        for (const match of masked.matchAll(pattern)) {
          check(
            false,
            rel,
            lineOf(text, match.index),
            `${what} selects a privileged account ("${oneLine(match[0])}"); packaging must name an unprivileged one`,
          );
        }
      }

      // `sc.exe obj=` is not a comment in effect: it configures the service account at install time, so it is
      // read from the raw text of the Windows config even though the command lives inside an explanatory comment.
      if (/\.xml$/i.test(rel)) {
        for (const match of text.matchAll(SC_OBJ)) {
          const value = match[1] ?? match[2] ?? match[3];
          check(
            forbiddenAccount(value) === null,
            rel,
            lineOf(text, match.index),
            `sc.exe obj= must not be "${value}"; install with "NT SERVICE\\fsmeta" or a dedicated account`,
          );
        }
      }
    }
  });
});
