import assert from 'node:assert/strict';
import {access, readFile, readdir} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../',import.meta.url));
const exists=async file=>{try{await access(file);return true;}catch{return false;}};
const ignored=new Set(['.git','.cache','.unlazy','node_modules','release','test-results','bin','obj']);
async function walk(dir){const out=[];for(const entry of await readdir(dir,{withFileTypes:true})){if(ignored.has(entry.name))continue;const p=path.join(dir,entry.name);if(entry.isDirectory())out.push(...await walk(p));else if(entry.isFile())out.push(p);}return out;}
function obsoleteDependencies(pkg){return ['electron','electron-builder','playwright','marked'].filter(name=>pkg.dependencies?.[name]||pkg.devDependencies?.[name]);}
assert.deepEqual(obsoleteDependencies({dependencies:{electron:'1'}}),['electron'],'Positive control catches obsolete dependency');
assert.deepEqual(obsoleteDependencies({dependencies:{'kokoro-js':'1.2.1'}}),[]);
const pkg=JSON.parse(await readFile(path.join(root,'package.json'),'utf8'));
const lock=JSON.parse(await readFile(path.join(root,'package-lock.json'),'utf8'));
assert.deepEqual(obsoleteDependencies(pkg),[]);
assert.equal(pkg.main,undefined);assert.equal(pkg.build,undefined);
assert.deepEqual(lock.packages[''].dependencies,pkg.dependencies);assert.deepEqual(lock.packages[''].devDependencies,pkg.devDependencies);
for(const name of ['electron','electron-builder','playwright','marked'])assert(!Object.keys(lock.packages).some(p=>p.endsWith('node_modules/'+name)),`${name} remains locked`);
for(const folder of ['desktop','renderer','shared'])assert(!await exists(path.join(root,folder)),`${folder} remains`);
for(const command of Object.values(pkg.scripts))for(const match of command.matchAll(/\b(?:node|bash)\s+([\w./-]+\.(?:mjs|sh))/g))assert(await exists(path.join(root,match[1])),`Missing script: ${match[1]}`);
const readme=await readFile(path.join(root,'README.md'),'utf8');
for(const text of ['## Install on Mac','## Install on Windows','./install.ps1','bash macos/scripts/install.sh','Verify Accessibility','CUDA','not notarized'])assert(readme.includes(text),`README lacks ${text}`);
assert(!readme.includes('docs/WINDOWS.md'),'Installation must be in the main README');
const files=await walk(root);let links=0,imports=0;
async function checkRelative(base,target){const clean=decodeURIComponent(target.split('#')[0]);if(!clean)return true;return exists(path.resolve(path.dirname(base),clean));}
assert(await checkRelative(path.join(root,'README.md'),'package.json'));
assert(!await checkRelative(path.join(root,'README.md'),'__missing_cleanup_control__.md'),'Negative control catches broken links');
for(const file of files){
 if(file.endsWith('.md')){
  assert(!/NATIVE_\d|ELECTRON_|REVISION|_GATES/.test(path.basename(file)),`Historical documentation remains: ${file}`);
  const text=await readFile(file,'utf8');
  for(const m of text.matchAll(/\[[^\]]*\]\(([^)]+)\)/g)){
   const target=m[1].replace(/^<|>$/g,'');if(/^(?:[a-z]+:|#)/i.test(target))continue;
   assert(await checkRelative(file,target),`Broken documentation link in ${path.relative(root,file)}: ${target}`);links++;
  }
 }
 if(file.endsWith('.mjs')){
  const text=await readFile(file,'utf8');
  for(const m of text.matchAll(/(?:\bfrom\s+|\bimport\s*\(\s*)['"](\.[^'"]+)['"]/g)){
   assert(await checkRelative(file,m[1]),`Broken local import in ${path.relative(root,file)}: ${m[1]}`);imports++;
  }
 }
}
const windows=await readFile(path.join(root,'windows/scripts/build-check.mjs'),'utf8');
assert(windows.includes("path.join(root,'README.md')")&&windows.includes("path.join(root,'docs')"),'Windows bundle must carry main README and linked docs');
console.log(`Checked ${files.length} source files, ${links} documentation links, ${imports} local module imports.`);
console.log('REPOSITORY_CLEAN_OK');
