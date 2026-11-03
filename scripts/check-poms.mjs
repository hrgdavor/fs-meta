#!/usr/bin/env bun
/**
 * pom.xml and pom-release.xml are copies, not parent and child: pom.xml packages a jar, and Maven 3.9.9
 * refuses a jar-packaged POM as a parent ("Invalid packaging for parent POM ... must be 'pom' but is
 * 'jar'"). Maven has no POM include, so the release file duplicates the whole POM. This check keeps the two
 * in step: comments and whitespace are ignored, the release-only publisher plugin is removed, and the
 * remainder must be identical. It also asserts the coordinates, where the publisher lives, the guard
 * values, and that the release does not depend on a SNAPSHOT (Central rejects it).
 *
 * Run: bun scripts/check-poms.mjs
 */
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const read = (name) => readFileSync(resolve(root, name), 'utf8');

const stripComments = (xml) => xml.replace(/<!--[\s\S]*?-->/g, '');
const normalize = (xml) => stripComments(xml).replace(/\s+/g, ' ').trim();
const first = (xml, tag) => xml.match(new RegExp(`<${tag}>([^<]+)</${tag}>`))?.[1] ?? null;
const removePlugin = (xml, artifactId) =>
  stripComments(xml).replace(/<plugin>[\s\S]*?<\/plugin>/g, (block) =>
    block.includes(artifactId) ? '' : block,
  );

let checks = 0;
let failures = 0;
function check(name, ok, detail = '') {
  checks += 1;
  if (ok) {
    console.log(`ok ${name}`);
  } else {
    failures += 1;
    console.error(`FAIL ${name}${detail ? ` — ${detail}` : ''}`);
  }
}

const pom = read('pom.xml');
const release = read('pom-release.xml');
const publisher = 'central-publishing-maven-plugin';

for (const tag of ['groupId', 'artifactId', 'version', 'packaging']) {
  const a = first(pom, tag);
  const b = first(release, tag);
  check(`${tag} matches (${a})`, a === b, `pom.xml=${a} pom-release.xml=${b}`);
}

check('pom.xml has no Central publisher', !pom.includes(publisher));
check('pom-release.xml carries the Central publisher', release.includes(publisher));

const pomBuild = pom.indexOf('<build>');
const pomProfiles = pom.indexOf('<profiles>');
const releaseBuild = release.indexOf('<build>');
const releaseProfiles = release.indexOf('<profiles>');
const releasePublisher = release.indexOf(publisher);
check(
  'the publisher is in the release POM\'s top-level <build>, not a profile',
  releaseBuild !== -1 && releasePublisher > releaseBuild && releasePublisher < releaseProfiles,
  `build=${releaseBuild} publisher=${releasePublisher} profiles=${releaseProfiles}`,
);
check('pom.xml\'s <build> does not contain the publisher', !(pomBuild !== -1 && pom.slice(pomBuild, pomProfiles).includes(publisher)));

const normalGuard = first(pom, 'maven.deploy.skip');
const releaseGuard = first(release, 'maven.deploy.skip');
check('pom.xml keeps maven-deploy-plugin off (maven.deploy.skip=true)', normalGuard === 'true', normalGuard);
check('pom-release.xml keeps maven-deploy-plugin off too (maven.deploy.skip=true)', releaseGuard === 'true', releaseGuard);

for (const [name, xml] of [['pom.xml', pom], ['pom-release.xml', release]]) {
  const visible = stripComments(xml);
  check(`${name} has no SNAPSHOT dependency or version`, !visible.includes('SNAPSHOT'), 'Central rejects it');
  for (const tag of ['url', 'licenses', 'developers', 'scm', 'distributionManagement']) {
    check(`${name} carries <${tag}>`, visible.includes(`<${tag}>`), 'required by Central');
  }
}

const normalizedPom = normalize(pom);
const normalizedRelease = normalize(removePlugin(release, publisher));
check(
  'the two POMs are identical apart from comments and the publisher plugin',
  normalizedPom === normalizedRelease,
  'copy pom.xml again and add only the publisher plugin and the release comment',
);

const packageVersion = JSON.parse(read('package.json')).version;
const zonVersion = read('build.zig.zon').match(/\.version\s*=\s*"([^"]+)"/)?.[1] ?? null;
check('pom.xml version matches package.json', first(pom, 'version') === packageVersion, `pom=${first(pom, 'version')} package=${packageVersion}`);
check('pom.xml version matches build.zig.zon', first(pom, 'version') === zonVersion, `pom=${first(pom, 'version')} zon=${zonVersion}`);

console.log(`${checks - failures}/${checks} checks passed`);
if (failures > 0) process.exit(1);
