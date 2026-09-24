import {mkdir,cp,readdir,readFile,writeFile,rm,stat} from 'node:fs/promises';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {root,cache,pins,run,download,unzip,dotnet,exists} from './toolchain.mjs';
import {diagnoseUIFailure} from './build-diagnostics.mjs';
const output=path.join(root,process.argv.includes('--parity')?'release/windows-parity/DAVE':'release/windows/DAVE');
const sdk=await dotnet();
const bundledNpm=path.join(cache,'node-windows/node-v22.16.0-win-x64/node_modules/npm/bin/npm-cli.js');
const npmArgs=['ci','--omit=dev','--ignore-scripts','--os=win32','--cpu=x64','--no-audit','--no-fund'];
const hasBundledNpm=process.platform==='win32'&&await exists(bundledNpm);
if(process.argv.includes('--check-tools')){
 console.log(`Node: ${process.execPath}\nSDK: ${sdk}`);run(sdk,['--list-sdks']);
 if(hasBundledNpm)run(process.execPath,[bundledNpm,'--version']);else run(process.platform==='win32'?'npm.cmd':'npm',['--version'],{shell:process.platform==='win32'});
 console.log('WINDOWS_BUILD_TOOLS_OK');process.exit(0);
}
if(process.platform==='win32'){
 const startedAt=new Date();
 const report=path.join(root,'test-results/windows-ui/result.txt');await mkdir(path.dirname(report),{recursive:true});await writeFile(report,'WINDOWS_UI_RUNNING: prior screenshots are not evidence for this build.');
 try{run(sdk,['run','--project','windows/UITests/UITests.csproj','-c','Release'],{env:{...process.env,DOTNET_CLI_HOME:cache,NUGET_PACKAGES:path.join(cache,'nuget')}});if(!(await readFile(report,'utf8')).startsWith('WINDOWS_UI_OK'))throw Error('UI process exited without completing its checks.');}
 catch(error){const diagnosis=diagnoseUIFailure(startedAt,root);const message=diagnosis??error.message;await writeFile(report,'WINDOWS_UI_FAILED: '+message+' See the process output; earlier screenshots may be stale.');console.error('\n'+message+'\nValidation stopped; no new release was packaged.');process.exit(1);}
}
run(sdk,['run','--project','windows/Tests/DomainTests.csproj'],{env:{...process.env,DOTNET_CLI_TELEMETRY_OPTOUT:'1',DOTNET_SKIP_FIRST_TIME_EXPERIENCE:'1',DOTNET_CLI_HOME:cache,NUGET_PACKAGES:path.join(cache,'nuget')}});
// Keep the last package intact when a validation check or local signing policy blocks the build.
await rm(output,{recursive:true,force:true});await mkdir(output,{recursive:true});
run(sdk,['publish','windows/LocalVoice/LocalVoice.csproj','-c','Release','-r','win-x64','--self-contained','true','-p:EnableWindowsTargeting=true','-p:Version=1.0.0','-o',output],{env:{...process.env,DOTNET_CLI_TELEMETRY_OPTOUT:'1',DOTNET_SKIP_FIRST_TIME_EXPERIENCE:'1',DOTNET_CLI_HOME:cache,NUGET_PACKAGES:path.join(cache,'nuget')}});
const backend=path.join(output,'backend'),runtime=path.join(output,'runtime');await mkdir(runtime,{recursive:true});
await cp(path.join(root,'macos/backend'),backend,{recursive:true});await cp(path.join(root,'core'),path.join(backend,'core'),{recursive:true});
await cp(path.join(root,'package.json'),path.join(backend,'package.json'));await cp(path.join(root,'package-lock.json'),path.join(backend,'package-lock.json'));
// Lockfile integrity verifies every package. Explicit target selects Windows native optional packages even during macOS cross-compilation.
if(hasBundledNpm)run(process.execPath,[bundledNpm,...npmArgs],{cwd:backend,env:{...process.env,npm_config_cache:path.join(cache,'npm')}});
else run(process.platform==='win32'?'npm.cmd':'npm',npmArgs,{cwd:backend,shell:process.platform==='win32',env:{...process.env,npm_config_cache:path.join(cache,'npm')}});
const nodeDir=path.join(cache,'node-windows');await unzip(await download(pins.node),nodeDir);await cp(path.join(nodeDir,'node-v22.16.0-win-x64/node.exe'),path.join(runtime,'node.exe'));
await cp(path.join(nodeDir,'node-v22.16.0-win-x64/LICENSE'),path.join(runtime,'LICENSE-node.txt'));
async function walk(dir){let out=[];for(const e of await readdir(dir,{withFileTypes:true})){const p=path.join(dir,e.name);if(e.isDirectory())out.push(...await walk(p));else out.push(p);}return out;}
for(const [variant,pin] of [['cuda',pins.whisperGPU],['cpu',pins.whisperCPU]]){const extracted=path.join(cache,'whisper-'+variant);await unzip(await download(pin),extracted);const files=await walk(extracted);const binary=files.find(f=>path.basename(f)==='whisper-cli.exe');if(!binary)throw Error(`Missing whisper-cli.exe in ${variant}`);await cp(path.dirname(binary),path.join(runtime,variant),{recursive:true});}
await cp(path.join(root,'windows/scripts/install.ps1'),path.join(output,'install.ps1'));
await cp(path.join(root,'README.md'),path.join(output,'README.md'));
await cp(path.join(root,'docs'),path.join(output,'docs'),{recursive:true});
const crt=path.join(cache,'vcrt');await unzip(await download(pins.vcrt),crt);
for(const dir of [output,runtime,path.join(runtime,'cpu'),path.join(runtime,'cuda'),path.join(backend,'node_modules/sherpa-onnx-win-x64'),path.join(backend,'node_modules/onnxruntime-node/bin/napi-v3/win32/x64')])for(const filename of (await readdir(crt)).filter(f=>/^(?:msvcp|vcruntime|vcomp|concrt).*\.dll$/i.test(f)))await cp(path.join(crt,filename),path.join(dir,filename));
for(const file of ['install.ps1','DAVE.exe','DAVE.dll','coreclr.dll','hostfxr.dll','runtime/node.exe','runtime/cuda/whisper-cli.exe','runtime/cpu/whisper-cli.exe','runtime/cuda/ggml-cuda.dll','runtime/cuda/cublas64_12.dll','runtime/cuda/cudart64_12.dll','runtime/cuda/msvcp140.dll','runtime/cpu/vcomp140.dll','backend/node_modules/onnxruntime-node/bin/napi-v3/win32/x64/onnxruntime_binding.node','backend/node_modules/sherpa-onnx-win-x64/sherpa-onnx.node']){if(!await exists(path.join(output,file)))throw Error(`Incomplete Windows package: ${file}`);}
// ONNX ships several platforms in one npm tarball; retain only the Windows x64 provider.
const ortBin=path.join(backend,'node_modules/onnxruntime-node/bin/napi-v3');
for(const entry of await readdir(ortBin))if(entry!=='win32')await rm(path.join(ortBin,entry),{recursive:true,force:true});
for(const entry of await readdir(path.join(ortBin,'win32')))if(entry!=='x64')await rm(path.join(ortBin,'win32',entry),{recursive:true,force:true});
const nativeFiles=(await walk(output)).filter(f=>/\.(exe|dll|node)$/i.test(f));for(const f of nativeFiles){if((await readFile(f)).subarray(0,2).toString()!=='MZ')throw Error(`Non-Windows native binary in package: ${f}`);}
await cp(path.join(root,'macos/metal/LICENSE-whisper.txt'),path.join(runtime,'LICENSE-whisper.txt'));
await cp(path.join(root,'windows/licenses/SoundTouch-LGPL-2.1.txt'),path.join(output,'LICENSE-SoundTouch.txt'));
await cp(await download(pins.soundTouchSource),path.join(output,'SoundTouch-2.3.2-source.zip'));
await writeFile(path.join(output,'SoundTouch-NOTICE.txt'),'SoundTouch.Net 2.3.2, Copyright Olli Parviainen and Olaf Woudenberg. Distributed unmodified under LGPL 2.1. Corresponding source and build files are included in SoundTouch-2.3.2-source.zip (commit 98e5b8fd2f8efed0ddf7c8f66b435bfb231659dc). The managed SoundTouch.Net.dll remains a separate, replaceable library. See LICENSE-SoundTouch.txt.\n');
await writeFile(path.join(runtime,'THIRD-PARTY-NOTICES.txt'),'Node.js: LICENSE-node.txt. whisper.cpp: LICENSE-whisper.txt. NVIDIA CUDA 12.4 runtime: https://docs.nvidia.com/cuda/archive/12.4.0/eula/index.html. Microsoft VCLibs runtime: https://visualstudio.microsoft.com/license-terms/. npm dependency licenses are retained in backend/node_modules.\n');
await writeFile(path.join(output,'BUILD-INFO.json'),JSON.stringify({version:'1.0.0',platform:'win-x64',gpu:'NVIDIA CUDA 12.4',runtimeValidation:'Requires Windows hardware; cross-compilation does not verify runtime behavior.',pins},null,2));
const zip=path.join(root,'release/DAVE-Windows-1.0.0-x64.zip');await rm(zip,{force:true});
if(process.platform==='win32')run('tar.exe',['-a','-cf',zip,'-C',path.dirname(output),path.basename(output)]);else run('ditto',['-c','-k','--keepParent',output,zip]);
await writeFile(zip+'.sha256',createHash('sha256').update(await readFile(zip)).digest('hex')+'  '+path.basename(zip)+'\n');
console.log(`WINDOWS_BUILD_OK ${zip} (${(await stat(zip)).size} bytes). Package built; microphone and GPU validation are separate.`);
