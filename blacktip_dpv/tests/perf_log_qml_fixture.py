"""Execute production Results handlers in Node with VESC Tool fixtures."""

import base64
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def body_after(text, marker):
    opening = text.index("{", text.index(marker))
    depth = 1
    pos = opening + 1
    while depth:
        if text[pos] == "{":
            depth += 1
        elif text[pos] == "}":
            depth -= 1
        pos += 1
    return text[opening + 1:pos - 1]


def run():
    node = shutil.which("node")
    if not node:
        return None
    qml = (ROOT / "ui.qml").read_text()
    names = ("RECEIVE", "VOLTAGE_CONSISTENT", "FAIL", "FINISH", "REQUEST", "TIMEOUT",
             "CSV_CELL", "CSV", "DOCUMENTS_PATH", "SAVE", "TOKEN_TEXT")
    markers = ("function logReceive(view)",
               "function logVoltageMinConsistent(count, sum, minimum)",
               "function logFail(message)",
               "function logFinish(status)", "function logRequest(op, row)",
               "onTriggered:", "function logCsvCell(value)",
               "function logCsv(snapshot)", "function logDocumentsPath()",
               "function logSaveCsv()", "function logTokenText(token)")
    scripts = [body_after(qml, marker) for marker in markers]
    encoded = [base64.b64encode(part.encode()).decode() for part in scripts]
    fixture = r'''
const vm=require('vm'), q={logComplete:{token:50,rows:Array.from({length:10},()=>[0,0,0,0,0,0,0,0]),
 diagnostics:Array.from({length:10},()=>[1,98765,0,0,0,0,0,0]),
 faultSamples:[2,9,1],diagnosticStatus:'available',fault:0,device:'device',
 downloaded:'old',firmware:'7.00',hardware:'MK5'},logPendingSnapshot:null,
 logRows:[],logDiagnostics:[],logFaultSamples:null,logToken:51,logSequence:8,
 logPending:2,logRow:255,logRetries:0,logExpectedCount:0,logExpectedRejected:0,
 logExpectedFault:0,logConnectedDevice:'device',firmwareVersion:'7.00',
 detectedHardwareModel:'MK5',logMessage:'',logExportMessage:'',
 VescIf:{connected:true,isPortConnected(){return this.connected},
 getConnectedUuid(){return 'device'},getConnectedPortName(){return ''}},
 mCommands:{sent:[],sendCustomAppData(b){this.sent.push(b)}},
 logTimeout:{stop(){},restart(){}},qsTr:s=>s,Platform:{StandardPaths:{
 DocumentsLocation:1,writableLocation(){return 'file:///tmp'}}},
 Utility:{arr2str:b=>Buffer.from(b).toString(),readAllFromFile:p=>q.files[p]},
 files:{},logWriter:{path:null,openLogFileFullPath(p){this.path=p;return true},
 writeToLogFile(s){q.files[this.path]=Buffer.from(s);return true},
 closeLogFile(){}}};
const ctx=vm.createContext(q);
vm.runInContext("String.prototype.arg=function(v){return this.replace('%1',v)}",ctx);
function src(s){return Buffer.from(s,'base64').toString()}
const receive=vm.runInContext('(function(view){'+src('RECEIVE')+'\n})',ctx);
q.logVoltageMinConsistent=vm.runInContext('(function(count,sum,minimum){'+src('VOLTAGE_CONSISTENT')+'\n})',ctx);
q.logFail=vm.runInContext('(function(message){'+src('FAIL')+'\n})',ctx);
q.logFinish=vm.runInContext('(function(status){'+src('FINISH')+'\n})',ctx);
q.logRequest=vm.runInContext('(function(op,row){'+src('REQUEST')+'\n})',ctx);
const timeout=vm.runInContext('(function(){'+src('TIMEOUT')+'\n})',ctx);
q.logTokenText=vm.runInContext('(function(token){'+src('TOKEN_TEXT')+'\n})',ctx);
q.logCsvCell=vm.runInContext('(function(value){'+src('CSV_CELL')+'\n})',ctx);
q.logCsv=vm.runInContext('(function(snapshot){'+src('CSV')+'\n})',ctx);
q.logDocumentsPath=vm.runInContext('(function(){'+src('DOCUMENTS_PATH')+'\n})',ctx);
q.logSaveCsv=vm.runInContext('(function(){'+src('SAVE')+'\n})',ctx);
function reply(op,row,len,status=0,seq=q.logSequence,token=q.logToken,fault=0){
 const b=new ArrayBuffer(len),v=new DataView(b);v.setUint8(1,1);v.setUint8(2,op);
 v.setUint16(3,seq);v.setUint32(5,token);v.setUint8(9,status);
 v.setUint8(10,row);v.setUint8(11,fault);return v}
const previous=q.logComplete;
// Delayed, malformed and foreign-token frames must not mutate the transaction.
receive.call(q,reply(2,255,20,0,q.logSequence-1));
receive.call(q,new DataView(new ArrayBuffer(8)));
receive.call(q,reply(2,255,20,0,q.logSequence,q.logToken+1));
if(q.logPending!==2)throw Error('stale/malformed frame mutated transaction');
const summary=reply(2,255,20);summary.setUint32(12,0);summary.setUint32(16,0);
receive.call(q,summary);
for(let row=0;row<10;row++){
 const v=reply(3,row,44);v.setUint32(12,0);
 for(let i=0;i<6;i++)v.setFloat32(16+i*4,0);
 v.setUint32(40,0);receive.call(q,v);
}
if(q.logPending!==5||!q.logPendingSnapshot||q.logPendingSnapshot.token!==q.logToken)
 throw Error('ten base rows were not staged for same-token diagnostics');
const sequence=q.logSequence;
timeout.call(q); // real retry path resends current extension transaction
const retry=new DataView(q.mCommands.sent[q.mCommands.sent.length-1]);
if(retry.getUint8(2)!==5||retry.getUint32(5)!==q.logToken)
 throw Error('extension retry changed opcode or snapshot token');
// v1 devices reject the additive extension: complete explicitly as unsupported.
receive.call(q,reply(5,255,12,1));
if(q.logComplete.diagnosticStatus!=='unsupported'||q.logComplete.diagnostics!==undefined)
 throw Error('unsupported diagnostics were fabricated or not labelled');
const csv=q.logCsv(q.logComplete), lines=csv.trimEnd().split('\n');
if(!csv.includes('diagnostic_status,unsupported\n')||lines.length!==29||
 csv.includes('98765')||csv.includes('nonzero_fault_samples,2')||
 !lines.slice(19).every(line=>line.split(',').length===17&&line.split(',').slice(9).every(x=>x==='')))
 throw Error('unified CSV invalid: '+JSON.stringify({length:lines.length,status:csv.includes('diagnostic_status,unsupported\n'),row:lines[19]}));
q.logSaveCsv();
const saved=Object.values(q.files)[0];
if(!saved||Buffer.from(saved).toString()!==csv||!q.logExportMessage.includes('Verified'))
 throw Error('CSV save/readback failed');
// A fully supported firmware completes all ten optional rows before commit.
const available={token:q.logToken,rows:q.logComplete.rows,fault:0};
q.logPendingSnapshot=available;q.logPending=4;q.logRow=0;q.logDiagnostics=[];
q.logFaultSamples=[0,0,0];q.logExpectedFault=0;q.logSequence++;
for(let row=0;row<10;row++){
 const v=reply(4,row,44);v.setUint32(12,0);
 receive.call(q,v);
 if(row<9&&q.logRow!==row+1)throw Error('diagnostic rows were not consumed in order');
}
if(q.logComplete!==available||available.diagnosticStatus!=='available'||
 available.diagnostics.length!==10)
 throw Error('valid diagnostic rows did not commit with the base snapshot');
// A diagnostic failure commits the already-complete base with explicit blank
// extension fields, rather than discarding base rows or carrying old details.
// Seed a prior diagnostic result again before the failed extension path.
q.logComplete={token:53,rows:q.logComplete.rows,
 diagnostics:Array.from({length:10},()=>[1,98765,0,0,0,0,0,0]),
 faultSamples:[2,9,1],diagnosticStatus:'available',fault:0,device:'device'};
const base={token:q.logToken,rows:q.logComplete.rows,fault:0,device:'device',
 downloaded:'now',firmware:'7.00',hardware:'MK5'};
q.logPendingSnapshot=base;q.logPending=4;q.logExpectedFault=0;
q.logFail('diagnostics failed');
if(q.logComplete!==base||base.diagnosticStatus!=='failed'||
 !q.logCsv(base).includes('diagnostic_status,failed\n')||
 q.logCsv(base).includes('98765')||q.logCsv(base).includes('nonzero_fault_samples,2')||
 q.logCsv(base).split('\n')[19].split(',').slice(9).some(x=>x!==''))
 throw Error('failed diagnostics did not retain base with blank labelled values');
q.logSaveCsv();
const failedExport=Buffer.from(Object.values(q.files)[Object.values(q.files).length-1]).toString();
if(!failedExport.includes('diagnostic_status,failed\n')||failedExport.includes('98765')||
 failedExport.includes('nonzero_fault_samples,2'))
 throw Error('failed-extension CSV exported diagnostics from the prior snapshot');
// A later failed transaction must retain the last committed snapshot.
q.logPending=2;q.logSequence++;receive.call(q,reply(2,255,12,0,q.logSequence-1));
if(q.logComplete.diagnosticStatus!=='failed')
 throw Error('incomplete follow-up replaced completed base results');
console.log(JSON.stringify({rows:q.logComplete.rows.length,preserved:true,diagnosticStatus:q.logComplete.diagnosticStatus}));
'''
    for name, value in zip(names, encoded):
        fixture = fixture.replace("src('" + name + "')", "src('" + value + "')")
    with tempfile.TemporaryDirectory() as temp:
        path = Path(temp) / "qml-fixture.js"
        path.write_text(fixture)
        result = subprocess.run([node, str(path)], capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout.strip()
