import assert from 'node:assert/strict';
import {readFile, stat, mkdtemp, rm} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
const pkg=JSON.parse(await readFile('package.json','utf8'));
const lock=JSON.parse(await readFile('package-lock.json','utf8'));
assert.equal(pkg.version,'1.0.0');assert.equal(lock.version,pkg.version);assert.equal(lock.packages[''].version,pkg.version);
assert.equal(pkg.dependencies['kokoro-js'],'1.2.1','Dependency version must not follow app version');
assert.match(await readFile('windows/LocalVoice/LocalVoice.csproj','utf8'),/<Version>1\.0\.0<\/Version>/);
const readme=await readFile('README.md','utf8');for(const text of ['1.0.0','Verify Accessibility','ResNet293','CUDA','not notarized','no published Homebrew'])assert(readme.includes(text),text);
const app=resolve('release/native/DAVE.app');
function run(bin,args){const r=spawnSync(bin,args,{encoding:'utf8',timeout:180000,maxBuffer:2e6});assert.equal(r.status,0,r.stderr||r.stdout||r.error?.message);return r.stdout;}
const version=run('/usr/libexec/PlistBuddy',['-c','Print :CFBundleShortVersionString',join(app,'Contents/Info.plist')]).trim();assert.equal(version,pkg.version);
run('codesign',['--verify','--deep','--strict',app]);
const diagnostic=JSON.parse(run(join(app,'Contents/MacOS/DAVE'),['--diagnose']));assert.equal(diagnostic.version,pkg.version);assert(diagnostic.native&&diagnostic.runtime&&diagnostic.backend);
const probe=JSON.parse(run(join(app,'Contents/MacOS/DAVE'),['--accessibility-probe']));assert.equal(typeof probe.trusted,'boolean');assert.equal(typeof probe.canPostEvents,'boolean');assert.equal(typeof probe.focusedApplicationError,'number');
run('/bin/bash',['-n','macos/scripts/install.sh']);
const archive=resolve(`release/DAVE-Native-${pkg.version}-${process.arch}.zip`);
const dmg=resolve(`release/DAVE-${pkg.version}-macos-${process.arch}.dmg`);
assert((await stat(archive)).size>1e6);assert((await stat(dmg)).size>1e6);
run('hdiutil',['verify',dmg]);
const temp=await mkdtemp(join(tmpdir(),'localvoice-release-check-'));
try {
 run('ditto',['-x','-k',archive,temp]);
 const unpacked=join(temp,'DAVE.app');run('codesign',['--verify','--deep','--strict',unpacked]);
 assert.equal(run('/usr/libexec/PlistBuddy',['-c','Print :CFBundleShortVersionString',join(unpacked,'Contents/Info.plist')]).trim(),pkg.version);
 assert.deepEqual(await readFile(join(unpacked,'Contents/MacOS/DAVE')),await readFile(join(app,'Contents/MacOS/DAVE')),'Archive must contain current executable');
} finally {await rm(temp,{recursive:true,force:true});}
console.log('RELEASE_100_OK');
