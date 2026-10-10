import fs from 'node:fs';
const root = new URL('../', import.meta.url);
const [next, channel = 'preview'] = process.argv.slice(2);
if (!next || !/^\d+\.\d+\.\d+$/.test(next) || !['stable', 'preview'].includes(channel)) {
  console.error('Usage: node scripts/set-version.mjs 0.13.1 preview|stable');
  process.exit(1);
}
const versionPath = new URL('version.json', root);
const current = JSON.parse(fs.readFileSync(versionPath, 'utf8'));
const build = current.build + (next === current.version ? 0 : 1);
fs.writeFileSync(versionPath, JSON.stringify({ ...current, version: next, build, releaseChannel: channel }, null, 2) + '\n');
for (const [file, replacements] of [
  ['project.yml', [[/MARKETING_VERSION: [\d.]+/g, `MARKETING_VERSION: ${next}`], [/CURRENT_PROJECT_VERSION: \d+/g, `CURRENT_PROJECT_VERSION: ${build}`]]],
  ['MinuteFlow.xcodeproj/project.pbxproj', [[/MARKETING_VERSION = [\d.]+;/g, `MARKETING_VERSION = ${next};`], [/CURRENT_PROJECT_VERSION = \d+;/g, `CURRENT_PROJECT_VERSION = ${build};`]]]
]) {
  const path = new URL(file, root);
  let content = fs.readFileSync(path, 'utf8');
  for (const [pattern, value] of replacements) content = content.replace(pattern, value);
  fs.writeFileSync(path, content);
}
console.log(`Both platforms now use ${next} (${build}), ${channel}`);
