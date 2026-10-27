// Where the binary under test lives.
//
// Default: the install `zig build` produces in `zig-out/`. `FSMETA_BIN` overrides it, which is what lets several
// agents (or a CI matrix) each drive their own build without fighting over `zig-out/` — a build in one process and a
// test running the binary in another cannot both own that path.
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));

export const binary =
  process.env.FSMETA_BIN ?? join(here, '..', 'zig-out', 'bin', process.platform === 'win32' ? 'fsmeta.exe' : 'fsmeta');
