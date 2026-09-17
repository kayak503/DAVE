import {spawnSync} from 'node:child_process';
import {mkdir,cp,readdir,writeFile,chmod,rm,readFile} from 'node:fs/promises';
import path from 'node:path';
const root=process.cwd();
const {version}=JSON.parse(await readFile("package.json", "utf8"));
const app=path.resolve('release/native/DAVE.app');
const contents=path.join(app,'Contents'), resources=path.join(contents,'Resources');
async function command(bin,args) {const r=spawnSync(bin,args,{stdio:'inherit'});if(r.status!==0)throw new Error(`${bin} failed (${r.status})`);}
await mkdir(path.join(contents,'MacOS'),{recursive:true});
await mkdir(resources,{recursive:true});
await mkdir('.cache/native-build/modules',{recursive:true});
const sources=(await readdir('macos/Sources')).filter(x=>x.endsWith('.swift')).map(x=>'macos/Sources/'+x);
await command('xcrun',['swiftc','-swift-version','5','-target',`${process.arch==='arm64'?'arm64':'x86_64'}-apple-macosx14.0`,'-module-cache-path','.cache/native-build/modules','-O',...sources,'-o',path.join(contents,'MacOS','DAVE'),'-framework','SwiftUI','-framework','AppKit','-framework','AVFoundation','-framework','ApplicationServices','-framework','Carbon']);
await writeFile(path.join(contents,'Info.plist'),`<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.localvoice.mac</string><key>CFBundleName</key><string>DAVE</string><key>CFBundleDisplayName</key><string>DAVE</string><key>CFBundleExecutable</key><string>DAVE</string><key>CFBundleGetInfoString</key><string>DAVE — Dictation And Voice Engine. Everything on your device.</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>${version}</string><key>CFBundleVersion</key><string>1</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>NSHighResolutionCapable</key><true/><key>NSMicrophoneUsageDescription</key><string>DAVE records your voice for private, on-device dictation. Audio is never sent to a server.</string><key>NSPrincipalClass</key><string>NSApplication</string><key>CFBundleIconFile</key><string>AppIcon</string></dict></plist>`);
await cp('build/icon.icns',path.join(resources,'AppIcon.icns'));
await mkdir(path.join(resources,'runtime'),{recursive:true});
if (process.arch === 'arm64') {
await command(process.execPath,['macos/scripts/build-metal.mjs']);
await cp('.cache/metal-build/build/bin/whisper-cli',path.join(resources,'runtime/whisper-cli'));
await cp('macos/metal/LICENSE-whisper.txt',path.join(resources,'runtime/LICENSE-whisper.txt'));
await command('codesign',['--force','--sign','-',path.join(resources,'runtime/whisper-cli')]);
} else { await rm(path.join(resources,'runtime/whisper-cli'),{force:true}); }
await cp(process.execPath,path.join(resources,'runtime/node'));await chmod(path.join(resources,'runtime/node'),0o755);
await rm(path.join(resources,'backend'),{recursive:true,force:true});
await mkdir(path.join(resources,'backend'),{recursive:true});
await cp('macos/backend',path.join(resources,'backend'),{recursive:true});
await cp('core',path.join(resources,'backend/core'),{recursive:true});
await writeFile(path.join(resources,'backend/package.json'),JSON.stringify({type:'module',private:true}));
const deps=spawnSync('npm',['ls','--omit=dev','--all','--parseable'],{encoding:'utf8'});
if(deps.status!==0)throw new Error(deps.stderr);
// Copy production dependency graph only. There is no Electron, browser, or developer tool in this bundle.
for(const source of deps.stdout.trim().split('\n')){
 if(source===root)continue;
 const relative=path.relative(path.join(root,'node_modules'),source);
 if(relative.startsWith('..'))throw new Error('Unexpected dependency location');
 const target=path.join(resources,'backend/node_modules',relative);
 await mkdir(path.dirname(target),{recursive:true});await cp(source,target,{recursive:true,dereference:true});
}
async function walk(dir){let files=[];for(const ent of await readdir(dir,{withFileTypes:true})){const p=path.join(dir,ent.name);if(ent.isDirectory())files.push(...await walk(p));else files.push(p);}return files;}
for(const file of await walk(resources))if(/\.(node|dylib)$/.test(file))await command('codesign',['--force','--sign','-',file]);
await command('codesign',['--force','--sign','-',path.join(resources,'runtime/node')]);
await command('codesign',['--force','--sign','-','--identifier','local.localvoice.mac',app]);
await command('codesign',['--verify','--deep','--strict',app]);
console.log('NATIVE_BUILD_OK '+app);
