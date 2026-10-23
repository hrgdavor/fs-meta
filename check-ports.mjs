#!/usr/bin/env bun
// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//
// Do the two ports really produce one format? The conformance vectors pin the bytes of a *given* triple and
// the walk's behaviour; this check closes the loop end to end — it scans the same real tree with both CLIs and
// compares what they wrote:
//
//   * `files.meta` and `files.txt` must be byte-identical;
//   * `names` (the CLI output, in format order) must be identical;
//   * the two `files.json` documents must carry the same keys and values, apart from the fields that are
//     *supposed* to differ between two publishes of the same tree: `generation`, `updated`, `writer`, `root`
//     (a path is a machine-specific fact — FORMAT.md § 7).
//
//   bun fs-meta/check-ports.mjs
//
// It needs the Java module built (`bun scripts/mvn-fast.js -pl :fs-meta package`) and a JDK 25, which it
// resolves the way every other tool here does. Scratch goes in a temp directory and is removed on exit.

import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { delimiter, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { resolveJdk25 } from '../scripts/lib/toolchain.js';
import { reportDuration, stopwatch } from '../scripts/lib/timing.js';

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, '..');
const elapsed = stopwatch();

let passed = 0;
let failed = 0;
const check = (name, condition, detail = '') => {
  if (condition) {
    passed++;
    console.log(`ok   ${name}`);
  } else {
    failed++;
    console.log(`FAIL ${name}${detail ? ` — ${detail}` : ''}`);
  }
};

/** The classpath the Java CLI needs: this module's jar plus the hash it depends on. */
function classpath() {
  const target = join(here, 'target');
  if (!existsSync(target)) {
    return { error: `no build output in ${target}: run \`bun scripts/mvn-fast.js -pl :fs-meta package\` first` };
  }
  const own = readdirSync(target).filter((name) => name.startsWith('fs-meta-') && name.endsWith('.jar'));
  if (own.length === 0) {
    return { error: `${target} holds no fs-meta jar: run \`bun scripts/mvn-fast.js -pl :fs-meta package\` first` };
  }

  // The hash comes from its own project, as the artifact `hr.hrg:wyhash` (DEC-050) — so the jar in the local
  // repository is what this module was built against. The version comes from the POM rather than from whatever
  // the directory happens to list first: `1.0.0` is still there, and running this check against a different
  // implementation than the one the module compiled against would quietly compare the wrong thing.
  // A restore from the build cache leaves a jar and no `target/classes`, which is the other reason to resolve
  // the hash as a jar rather than as a directory of classes.
  const pom = readFileSync(join(here, 'pom.xml'), 'utf8');
  const declared = /<wyhash\.version>([^<]+)<\/wyhash\.version>/.exec(pom)?.[1];
  if (declared === undefined) {
    return { error: `could not read <wyhash.version> from ${join(here, 'pom.xml')}` };
  }
  const m2 = join(process.env.USERPROFILE ?? process.env.HOME ?? '', '.m2', 'repository', 'hr', 'hrg', 'wyhash');
  const directory = join(m2, declared);
  const jars = existsSync(directory)
    ? readdirSync(directory).filter((name) => name.endsWith('.jar') && !name.includes('sources') && !name.includes('javadoc'))
    : [];
  if (jars.length > 0) {
    return { classpath: [join(target, own[0]), join(directory, jars[0])].join(delimiter) };
  }
  return {
    error: `${directory} holds no hr.hrg:wyhash jar (the version ${join(here, 'pom.xml')} declares): `
      + 'install it from its own checkout — `cd <wyhash checkout> && mvn -o install -Dgpg.skip=true` (DEC-050)',
  };
}

const resolved = classpath();
if (resolved.error) {
  console.error(`check-ports: ${resolved.error}`);
  process.exit(2);
}
const { java } = resolveJdk25();

// ------------------------------------------------------------------ a tree worth comparing

const workspace = mkdtempSync(join(tmpdir(), 'fsmeta-ports-'));
process.on('exit', () => rmSync(workspace, { recursive: true, force: true }));
const root = join(workspace, 'tree');
const bunTrio = join(workspace, 'bun-trio');
const javaTrio = join(workspace, 'java-trio');

const write = (relative, content) => {
  const path = join(root, relative);
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, content);
};
mkdirSync(root, { recursive: true });
write('.gitignore', '*.log\nnode_modules/\n!keep.log\n');
write('README.md', '# a tree for the port check\n');
write('src/main/App.java', 'class App {}\n');
write('src/main/notes.txt', 'line1\r\nline2\r\n');
write('docs/héllo — ünïcode.md', 'héllo\n');
write('assets/logo.bin', Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x00, 0x01, 0x02, 0x03]));
write('debug.log', 'ignored\n');
write('keep.log', 're-included\n');
write('node_modules/pkg/index.js', 'ignored\n');
write('build/out.txt', 'listed: the default ignore list is only .git and .fs-meta\n');

// ------------------------------------------------------------------ both ports scan it

const bunScan = spawnSync(process.execPath, [join(here, 'js', 'fsmeta-cli.mjs'), 'scan', '--root', root, '--dir', bunTrio],
  { encoding: 'utf8' });
check('the Bun port scans the tree', bunScan.status === 0, bunScan.stderr?.trim());

const javaScan = spawnSync(java, ['-cp', resolved.classpath, 'hr.hrg.fsmeta.FsMetaCli', 'scan', '--root', root, '--dir', javaTrio],
  { encoding: 'utf8' });
check('the Java port scans the tree', javaScan.status === 0, javaScan.stderr?.trim() || javaScan.stdout?.trim());

if (bunScan.status !== 0 || javaScan.status !== 0) {
  console.log(`\n${passed} passed, ${failed} failed — nothing to compare without two trios`);
  reportDuration(elapsed(), { what: 'port check', files: 0 });
  process.exit(1);
}

// ------------------------------------------------------------------ and the bytes agree

const same = (file) => {
  const fromBun = readFileSync(join(bunTrio, file));
  const fromJava = readFileSync(join(javaTrio, file));
  check(`${file} is byte-identical`, fromBun.equals(fromJava),
    `${fromBun.length} vs ${fromJava.length} bytes`);
  return fromBun;
};

const txt = same('files.txt');
same('files.meta');

const bunNames = spawnSync(process.execPath, [join(here, 'js', 'fsmeta-cli.mjs'), 'names', '--dir', bunTrio], { encoding: 'utf8' });
const javaNames = spawnSync(java, ['-cp', resolved.classpath, 'hr.hrg.fsmeta.FsMetaCli', 'names', '--dir', javaTrio],
  { encoding: 'utf8' });
check('names prints the same list from both ports', bunNames.stdout === javaNames.stdout,
  `bun: ${JSON.stringify(bunNames.stdout)} java: ${JSON.stringify(javaNames.stdout)}`);
check('the walk honoured .gitignore', !bunNames.stdout.includes('debug.log') && !bunNames.stdout.includes('node_modules/')
  && bunNames.stdout.includes('keep.log'), JSON.stringify(bunNames.stdout));
check('files.txt lists the 8 files the walk should have kept, LF-separated',
  txt.toString('utf8').split('\n').filter((line) => line !== '').length === 8,
  JSON.stringify(txt.toString('utf8')));

// The two documents, with the fields that are a writer's own state removed: the generation and the two
// instants belong to the publish (two publishes of one tree are two generations), `writer` names the port, and
// `root` is the path this checkout happens to sit at.
const document = (file) => {
  const parsed = JSON.parse(readFileSync(file, 'utf8'));
  for (const key of ['generation', 'created', 'updated', 'writer', 'root']) {
    delete parsed[key];
  }
  return JSON.stringify(parsed);
};
check('files.json carries the same document in both ports',
  document(join(bunTrio, 'files.json')) === document(join(javaTrio, 'files.json')),
  `bun: ${document(join(bunTrio, 'files.json'))}\n      java: ${document(join(javaTrio, 'files.json'))}`);

// A diff of the two trios must be empty: the same tree, described the same way.
const diff = spawnSync(process.execPath, [join(here, 'js', 'fsmeta-cli.mjs'), 'diff', bunTrio, javaTrio], { encoding: 'utf8' });
check('a diff of the two trios is empty', diff.status === 0 && diff.stdout.trim() === 'no changes',
  JSON.stringify(`${diff.stdout}${diff.stderr}`));

console.log('');
console.log(`${passed} passed, ${failed} failed`);
reportDuration(elapsed(), { what: 'port check', files: txt.toString('utf8').split('\n').filter((line) => line !== '').length });
process.exit(failed === 0 ? 0 : 1);