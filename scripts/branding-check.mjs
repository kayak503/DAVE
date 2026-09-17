import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
const read=file=>readFile(file,'utf8');
const pkg=JSON.parse(await read('package.json'));
const lock=JSON.parse(await read('package-lock.json'));
assert.equal(pkg.name,'dave-voice-engine');assert.equal(pkg.productName,'DAVE');assert.equal(lock.name,pkg.name);assert.equal(lock.packages[''].name,pkg.name);
for(const file of ['README.md','macos/Sources/Views.swift','windows/LocalVoice/MainForm.cs']){
 const text=await read(file);assert(text.includes('Dictation And Voice Engine'),file);assert(text.includes('Everything on your device.'),file);
}
const macBuild=await read('macos/scripts/build.mjs');assert(macBuild.includes('release/native/DAVE.app'));assert(macBuild.includes('<string>DAVE</string>'));assert(macBuild.includes('local.localvoice.mac'),'Keep existing permission identity');
assert((await read('macos/Sources/Preferences.swift')).includes('LocalVoiceNative/preferences.json'),'Keep existing preferences');
assert((await read('macos/backend/service.mjs')).includes('Library/Application Support/Hearth/models'),'Keep prior model discovery');
assert((await read('windows/LocalVoice/Domain.cs')).includes('SpecialFolder.LocalApplicationData),"Local Voice"'),'Keep Windows data');
assert((await read('windows/LocalVoice/LocalVoice.csproj')).includes('<AssemblyName>DAVE</AssemblyName>'));
assert((await read('windows/scripts/install.ps1')).includes('Get-Process -Name DAVE,LocalVoice'));
assert((await read('windows/scripts/build-check.mjs')).includes('DAVE-Windows-1.0.0-x64.zip'));
for(const file of ['macos/Sources/NativeApp.swift','macos/Sources/MacSystem.swift','macos/Sources/Views.swift','macos/Sources/AppModel.swift','windows/LocalVoice/MainForm.cs','windows/LocalVoice/Program.cs'])assert(!(await read(file)).includes('Local Voice'),`Old visible product name in ${file}`);
console.log('DAVE_BRANDING_OK');
