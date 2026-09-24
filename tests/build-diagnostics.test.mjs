import test from 'node:test';
import assert from 'node:assert/strict';
import {applicationControlFailure} from '../windows/scripts/build-diagnostics.mjs';

const workspace='C:\\work\\DAVE';
const blocked={Message:"Application: UITests.exe\nCould not load 'C:\\work\\DAVE\\windows\\UITests\\DAVE.dll'. An Application Control policy has blocked this file. (0x800711C7)"};
test('reports the matching UI policy block with original evidence',()=>{
 const result=applicationControlFailure([blocked],workspace);
 assert.match(result,/Windows Application Control blocked/);
 assert.ok(result.includes(blocked.Message));
});
test('does not misdiagnose an unrelated CLR crash or another checkout',()=>{
 assert.equal(applicationControlFailure([{Message:'Application: UITests.exe\nUnhandled exception: NullReferenceException'}],workspace),null);
 assert.equal(applicationControlFailure([blocked],'C:\\work\\OTHER'),null);
 assert.equal(applicationControlFailure([blocked],'C:\\work\\DAV'),null);
 assert.equal(applicationControlFailure([{Message:blocked.Message.replace('UITests.exe','Other.exe')}],workspace),null);
});
