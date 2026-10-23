#!/usr/bin/env bun
// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//
// `fsmeta` — the Bun command line, with the same commands, the same output and the same exit codes as the
// Java port's FsMetaCli. A pipeline therefore does not care which one answers, which is the point of two
// ports sharing one format.
//
//   bun fs-meta/js/fsmeta-cli.mjs scan [--root DIR] [--dir DIR] ...
//
// Exit codes: 0 when the command's question was answered, 1 when the subject failed, 2 for a usage error.

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

import {
  DIRECTORY_NAME, JSON_FILE, META_FILE, TXT_FILE, WRITER, changeLine, configHashMode, decodeEntries,
  describeValidation, diffPairs, formatEntry, loadTrio, loadTrioIfPresent, parseConfig, publish, repairPairing,
  repairedFiles, scanOptions, scanTree, validate,
} from './fsmeta.mjs';
import { HASH_MODES } from './layout.mjs';

const USAGE = [
  'usage: fsmeta <command> [options]',
  '',
  '  scan   [--root DIR] [--dir DIR] [--ignore NAME]... [--normalize none|lf|text]',
  '         [--writer NAME] [--no-gitignore]',
  '  verify [--dir DIR]',
  '  names  [--dir DIR]',
  '  query  NAME [--dir DIR]',
  '  dump   [--dir DIR]',
  '  diff   DIR_A DIR_B',
  '  repair [--dir DIR] [--dry-run]',
  '',
  '--dir defaults to <root>/.fs-meta, and --root to the working directory.',
  'scan honours .gitignore files in the tree unless --no-gitignore is given.',
  'Exit codes: 0 answered, 1 the subject failed, 2 usage.',
];

/** Parses `--key value`, `--key=value` and the boolean flags this CLI knows. */
function parseOptions(args) {
  const options = new Map();
  const positional = [];
  const booleans = new Set(['dry-run', 'help', 'no-gitignore']);
  for (let index = 0; index < args.length; index++) {
    const arg = args[index];
    if (!arg.startsWith('--')) {
      positional.push(arg);
      continue;
    }
    const equals = arg.indexOf('=');
    const key = equals >= 0 ? arg.slice(2, equals) : arg.slice(2);
    if (booleans.has(key)) {
      options.set(key, 'true');
      continue;
    }
    let value = equals >= 0 ? arg.slice(equals + 1) : null;
    if (value === null) {
      if (index + 1 >= args.length) {
        return { error: `'--${key}' needs a value` };
      }
      value = args[++index];
    }
    options.set(key, value);
  }
  return { options, positional };
}

/**
 * Runs one command.
 *
 * @param {string[]} args the arguments after the command name
 * @param {{out?: {write: Function}, err?: {write: Function}}} [streams] where output goes; defaults to stdio
 * @returns {number} the exit code
 */
export function run(args, streams = {}) {
  const out = streams.out ?? process.stdout;
  const err = streams.err ?? process.stderr;
  const line = (text) => out.write(`${text}\n`);
  const problem = (text) => err.write(`${text}\n`);
  const usage = () => USAGE.forEach(problem);

  if (args.length === 0 || args[0] === '--help' || args[0] === '-h') {
    usage();
    return args.length === 0 ? 2 : 0;
  }
  const command = args[0];
  const parsed = parseOptions(args.slice(1));
  if (parsed.error) {
    problem(`fsmeta: ${parsed.error}`);
    usage();
    return 2;
  }
  const { options, positional } = parsed;
  const trioDirectory = () => options.get('dir')
    ?? join(options.get('root') ?? process.cwd(), DIRECTORY_NAME);

  const requireTrio = () => {
    const directory = trioDirectory();
    const load = loadTrioIfPresent(directory);
    if (load === null) {
      problem(`fsmeta: no complete fs-meta trio in ${directory} (run: fsmeta scan)`);
      return { directory, verdict: 'unsupported-format', config: null, pair: null, ok: false, describe: () => 'no trio' };
    }
    if (!load.ok) {
      problem(`fsmeta: ${load.describe()}`);
    }
    return load;
  };

  try {
    switch (command) {
      case 'scan': {
        const root = options.get('root') ?? process.cwd();
        const directory = options.get('dir') ?? join(root, DIRECTORY_NAME);
        const normalize = options.get('normalize');
        if (normalize !== undefined && !HASH_MODES.includes(normalize)) {
          problem(`fsmeta: --normalize must be one of none, lf, text (got '${normalize}')`);
          return 2;
        }
        const ignored = options.get('ignore') === undefined ? undefined : [options.get('ignore')];
        const scan = scanOptions({
          ...(normalize === undefined ? {} : { hashMode: normalize }),
          ...(ignored === undefined ? {} : { ignored: [...scanOptions().ignored, ...ignored] }),
          respectGitignore: options.get('no-gitignore') === undefined,
        });
        const files = scanTree(root, scan);
        const load = publish(directory, files, {
          mode: scan.hashMode,
          writer: options.get('writer') ?? WRITER,
        });
        if (!load.ok) {
          problem(`fsmeta: the trio just written does not validate: ${load.describe()}`);
          return 1;
        }
        line(`scanned ${files.length} file(s) from ${root} into ${directory} (generation ${load.config.generation})`);
        return 0;
      }

      case 'verify': {
        const directory = trioDirectory();
        const load = loadTrioIfPresent(directory);
        if (load === null) {
          problem(`fsmeta: no complete fs-meta trio in ${directory}`);
          return 1;
        }
        line(load.describe());
        return load.ok ? 0 : 1;
      }

      case 'names': {
        const load = requireTrio();
        if (!load.ok) {
          return 1;
        }
        load.pair.names.forEach(line);
        return 0;
      }

      case 'query': {
        if (positional.length === 0) {
          problem('fsmeta: query needs a NAME');
          return 2;
        }
        const name = positional[0];
        const load = requireTrio();
        if (!load.ok) {
          return 1;
        }
        const index = load.pair.find(name);
        if (index < 0) {
          problem(`fsmeta: '${name}' is not listed in generation ${load.config.generation} (it is new, deleted, or not scanned)`);
          return 1;
        }
        line(formatEntry(name, load.pair.entry(index)));
        return 0;
      }

      case 'dump': {
        const load = requireTrio();
        if (!load.ok) {
          return 1;
        }
        for (let index = 0; index < load.pair.size; index++) {
          line(formatEntry(load.pair.name(index), load.pair.entry(index)));
        }
        return 0;
      }

      case 'diff': {
        if (positional.length !== 2) {
          problem('fsmeta: diff needs two trio directories');
          return 2;
        }
        const before = loadTrio(positional[0]);
        const after = loadTrio(positional[1]);
        if (!before.ok || !after.ok) {
          problem(`fsmeta: ${before.describe()}`);
          problem(`fsmeta: ${after.describe()}`);
          return 1;
        }
        const changes = diffPairs(before.pair, after.pair);
        changes.forEach((change) => line(changeLine(change)));
        const counts = new Map();
        changes.forEach((change) => counts.set(change.kind, (counts.get(change.kind) ?? 0) + 1));
        const summary = ['added', 'removed', 'modified', 'touched', 'unknown']
          .filter((kind) => counts.has(kind))
          .map((kind) => `${counts.get(kind)} ${kind}`)
          .join(', ');
        line(summary === '' ? 'no changes' : summary);
        return 0;
      }

      case 'repair': {
        const directory = trioDirectory();
        const meta = readFileSync(join(directory, META_FILE));
        const txt = readFileSync(join(directory, TXT_FILE));
        let config;
        try {
          config = parseConfig(readFileSync(join(directory, JSON_FILE), 'utf8'));
        } catch (malformed) {
          problem(`fsmeta: files.json cannot be read, so the trio cannot be repaired: ${malformed.message}`);
          return 1;
        }
        const validation = validate(meta, txt, config);
        if (validation.ok) {
          line(`nothing to repair: ${describeValidation(validation)}`);
          return 0;
        }
        if (validation.verdict !== 'name-hash-mismatch') {
          problem(`fsmeta: only a broken pairing can be repaired by hash, and this trio failed with ${describeValidation(validation)}`);
          return 1;
        }
        const pairing = repairPairing(meta, txt);
        if (pairing === null) {
          problem('fsmeta: the pairing cannot be recovered: an entry has no distinct matching name');
          return 1;
        }
        const files = repairedFiles(decodeEntries(meta), pairing);
        if (options.get('dry-run') !== undefined) {
          pairing.forEach((one) => line(`entry ${one.entry} -> ${one.name}`));
          line(`dry run: ${files.length} entry/entries would be republished in name order`);
          return 0;
        }
        const repaired = publish(directory, files, {
          mode: configHashMode(config),
          writer: WRITER,
        });
        line(`repaired ${files.length} entry/entries: ${repaired.describe()}`);
        return repaired.ok ? 0 : 1;
      }

      default:
        problem(`fsmeta: unknown command '${command}'`);
        usage();
        return 2;
    }
  } catch (failure) {
    problem(`fsmeta: ${failure.message}`);
    return 1;
  }
}

const invokedDirectly = process.argv[1] !== undefined
  && import.meta.url === pathToFileURL(process.argv[1]).href;
if (invokedDirectly) {
  process.exit(run(process.argv.slice(2)));
}