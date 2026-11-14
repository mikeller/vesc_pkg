"""Execute production Results handlers in Node with VESC Tool fixtures."""

import base64
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def body_after(text, marker, start=0):
    opening = text.index('{', text.index(marker, start))
    depth = 1
    pos = opening + 1
    while depth:
        if text[pos] == '{':
            depth += 1
        elif text[pos] == '}':
            depth -= 1
        pos += 1
    return text[opening + 1:pos - 1]


def run():
    node = shutil.which('node')
    if not node:
        return None
    qml = (ROOT / 'ui.qml').read_text()
    receive = body_after(qml, 'function logReceive(view)')
    voltage_consistent = body_after(qml, 'function logVoltageMinConsistent(count, sum, minimum)')
    assert 'function logTokenText(token)' in qml
    token_text = body_after(qml, 'function logTokenText(token)')
    fail = body_after(qml, 'function logFail(message)')
    finish = body_after(qml, 'function logFinish()')
    request = body_after(qml, 'function logRequest(op, row)')
    download_diagnostics = body_after(qml, 'function logDownloadDiagnostics()')
    app_signal = body_after(qml, 'function onStateChanged(state)')
    timer_at = qml.index('id: logTimeout')
    timeout = body_after(qml, 'onTriggered:', timer_at)
    csv_cell = body_after(qml, 'function logCsvCell(value)')
    csv = body_after(qml, 'function logCsv(snapshot)')
    diagnostic_csv = body_after(qml, 'function logDiagnosticCsv(snapshot)')
    documents_path = body_after(qml, 'function logDocumentsPath()')
    save = body_after(qml, 'function logSaveCsv()')
    scripts = [receive, voltage_consistent, fail, finish, request, download_diagnostics,
               app_signal, timeout, token_text,
               csv_cell, csv, diagnostic_csv, documents_path, save]
    encoded = [base64.b64encode(part.encode()).decode() for part in scripts]
    fixture = r'''
const vm=require('vm');
const q={logComplete:{old:true},logRows:[],logToken:51,logSequence:8,
 logPending:2,logRow:255,logRetries:0,logExpectedCount:0,
 logExpectedRejected:0,logExpectedFault:0,logConnectedDevice:'device',
 firmwareVersion:'7.00',detectedHardwareModel:'MK5',logMessage:'',logStatus:'',
 VescIf:{connected:true,isPortConnected(){return this.connected},
   getConnectedUuid(){return 'device'},getConnectedPortName(){return ''}},
 mCommands:{sent:[],sendCustomAppData(b){this.sent.push(b)}},
 logTimeout:{stops:0,restarts:0,stop(){this.stops++},restart(){this.restarts++}},
  qsTr:s=>s,Qt:{ApplicationActive:4},
  Platform:{StandardPaths:{DocumentsLocation:1,writableLocation(){return this.path},path:{toString(){return 'file:///tmp'}}}},
  Utility:{arr2str:b=>Buffer.from(b).toString(),readAllFromFile:p=>q.files[p]},
  files:{},logWriter:{path:null,openLogFileFullPath(p){this.path=p;return true},
    writeToLogFile(s){q.files[this.path]=Buffer.from(s);return true},closeLogFile(){}}};
const ctx=vm.createContext(q);
vm.runInContext("String.prototype.arg=function(v){return this.replace('%1',v)}",ctx);
function source(s){return Buffer.from(s,'base64').toString()}
const tokenText=vm.runInContext('(function(token){'+source('TOKEN_TEXT')+'\n})',ctx);
q.logTokenText=tokenText;
for (const [value, expected] of [[1,'0x1'],[0x7fffffff,'0x7fffffff'],
    [0x80000000,'0x80000000'],[0xfffffffe,'0xfffffffe'],
    [0xffffffff,'0xffffffff'],[-1,'0xffffffff']]) {
 if(tokenText(value)!==expected)throw Error('snapshot token formatting: '+value);
}
if(tokenText(0xfffffffe)===tokenText(0xffffffff))throw Error('adjacent tokens collapsed');
const receive=vm.runInContext('(function(view){'+source('RECEIVE')+'\n})',ctx);
q.logVoltageMinConsistent=vm.runInContext('(function(count,sum,minimum){'+source('VOLTAGE_CONSISTENT')+'\n})',ctx);
q.logFail=vm.runInContext('(function(message){'+source('FAIL')+'\n})',ctx);
q.logFinish=vm.runInContext('(function(){'+source('FINISH')+'\n})',ctx);
q.logRequest=vm.runInContext('(function(op,row){'+source('REQUEST')+'\n})',ctx);
q.logDownloadDiagnostics=vm.runInContext('(function(){'+source('DOWNLOAD_DIAGNOSTICS')+'\n})',ctx);
const suspended=vm.runInContext('(function(state){'+source('SUSPEND')+'\n})',ctx);
const timeout=vm.runInContext('(function(){'+source('TIMEOUT')+'\n})',ctx);
const csvCell=vm.runInContext('(function(value){'+source('CSV_CELL')+'\n})',ctx);
const csv=vm.runInContext('(function(snapshot){'+source('CSV')+'\n})',ctx);
const diagnosticCsv=vm.runInContext('(function(snapshot){'+source('DIAGNOSTIC_CSV')+'\n})',ctx);
q.logCsv=csv;q.logCsvCell=csvCell;q.logDiagnosticCsv=diagnosticCsv;
const save=vm.runInContext('(function(){'+source('SAVE')+'\n})',ctx);
q.logSaveCsv=save;
q.logDocumentsPath=vm.runInContext('(function(){'+source('DOCUMENTS_PATH')+'\n})',ctx);
function reply(op,row,length,fault=0,sequence=q.logSequence,token=q.logToken,status=0){
 const b=new ArrayBuffer(length),v=new DataView(b);
 v.setUint8(1,1);v.setUint8(2,op);v.setUint16(3,sequence);
 v.setUint32(5,token);v.setUint8(9,status);v.setUint8(10,row);v.setUint8(11,fault);return v;
}
const summary=reply(2,255,20,1);new DataView(summary.buffer).setUint32(12,30);
receive.call(q,summary);
if(q.logPending!==3||q.logRow!==0||q.logExpectedCount!==30)
 throw Error('production summary handler failed to request row zero/read wire totals');
for(let row=0;row<10;row++){
 if(q.logRow!==row)throw Error('production request order mismatch at '+row);
 const v=reply(3,row,44,1);v.setUint32(12,3);
 for(let i=0;i<5;i++)v.setFloat32(16+i*4,i+1);
 v.setFloat32(36,6);v.setUint32(40,0);receive.call(q,v);
}
if(!q.logComplete||q.logComplete.rows.length!==10||q.logPending!==0)
 throw Error('production handler did not commit all ten legacy rows');
q.logDownloadDiagnostics();
if(q.logPending!==5)throw Error('optional diagnostics request did not use opcode 5');
const faultSummary=reply(5,255,24,1);faultSummary.setUint32(12,3);faultSummary.setUint32(16,7);faultSummary.setUint32(20,1);
receive.call(q,faultSummary);
if(q.logPending!==4||q.logRow!==0)throw Error('fault summary did not advance to diagnostic rows');
const firstDiagSequence=q.logSequence;
receive.call(q,reply(4,0,44,1,firstDiagSequence-1));
if(q.logPending!==4||q.logRow!==0)throw Error('stale diagnostic response advanced the extension transaction');
receive.call(q,reply(4,0,43,1));
if(q.logPending!==4||q.logRow!==0)throw Error('malformed diagnostic response advanced the extension transaction');
q.logRetries=0;timeout.call(q);
const diagnosticRetry=new DataView(q.mCommands.sent[q.mCommands.sent.length-1]);
if(q.logPending!==4||q.logRow!==0||diagnosticRetry.byteLength!==10||
 diagnosticRetry.getUint8(2)!==4||diagnosticRetry.getUint8(9)!==0||
 diagnosticRetry.getUint32(5)!==q.logToken)
 throw Error('production timeout did not retry the same diagnostic row/token');
receive.call(q,reply(4,0,44,1,firstDiagSequence,q.logToken));
if(q.logPending!==4||q.logRow!==0)throw Error('stale diagnostic response mutated retry state');
const voltageSumThree = Math.fround(Math.fround(Math.fround(29.8) +
 Math.fround(29.8)) + Math.fround(29.8));
for(let row=0;row<10;row++){
 if(q.logRow!==row)throw Error('production diagnostic request order mismatch at '+row);
 const v=reply(4,row,44,1);v.setUint32(12,3);
 v.setFloat32(16,300);v.setFloat32(20,600);v.setFloat32(24,900);
 v.setUint32(28,3);v.setFloat32(32,voltageSumThree);v.setFloat32(36,29.8);
 v.setUint32(40,0);receive.call(q,v);
}
if(!q.logComplete||q.logComplete.rows.length!==10||q.logComplete.diagnostics.length!==10||
 q.logComplete.diagnostics[0][1]!==300||q.logComplete.fault!==1||
 q.logComplete.faultSamples.join(',')!=='3,7,1'||q.logPending!==0)
 throw Error('production diagnostic transaction or Float32 telemetry decoding failed');
const actualEnhanced=diagnosticCsv(q.logComplete), enhancedLines=actualEnhanced.trimEnd().split('\n');
const enhancedHeader=enhancedLines[enhancedLines.indexOf('speed,command_valid_samples,mean_raw_controller_target_erpm,mean_signed_erpm,mean_signed_error_erpm,voltage_valid_samples,mean_bus_voltage_V,min_bus_voltage_V,diagnostic_failures')+1].split(',');
if(!actualEnhanced.includes('nonzero_fault_samples,3\n')||
 !actualEnhanced.includes('last_nonzero_fault_code,7\n')||
 !actualEnhanced.includes('fault_read_failures,1\n')||
 Number(enhancedHeader[6])>=Number(enhancedHeader[7])||
 Math.abs(Number(enhancedHeader[6])-29.8)>0.00001||
 Math.abs(Number(enhancedHeader[7])-29.8)>0.00001)
 throw Error('production enhanced export mismatch: '+JSON.stringify({text:actualEnhanced,header:enhancedHeader}));
q.Platform.StandardPaths.path={toString(){return 'file:///tmp'}};
q.logComplete=q.logComplete;q.logSaveCsv(true);
const enhancedPath=Object.keys(q.files).find(p=>p.includes('/blacktip-diagnostics-v2-'));
if(!enhancedPath||Buffer.from(q.files[enhancedPath]).toString()!==actualEnhanced||
 !q.logExportMessage.includes('Verified'))throw Error('enhanced save mismatch: '+JSON.stringify({enhancedPath,keys:Object.keys(q.files),message:q.logExportMessage,saved:enhancedPath&&Buffer.from(q.files[enhancedPath]).toString()===actualEnhanced}));
if(!csv(q.logComplete).includes('logging_fault,1\n'))
 throw Error('production base CSV omitted nonzero logging fault');
// Older v1 devices reject the additive fault-summary request. Fallback finishes
// an otherwise valid snapshot and keeps diagnostics absent rather than invented.
q.logComplete={token:51,rows:q.logComplete.rows,fault:0,device:'device'};
q.logPending=0;q.logToken=51;q.logSequence++;
q.logDownloadDiagnostics();
const firstExtensionSequence=q.logSequence;
q.logRetries=0;timeout.call(q);
const retryPacket=new DataView(q.mCommands.sent[q.mCommands.sent.length-1]);
if(q.logPending!==5||q.logRow!==255||retryPacket.getUint8(2)!==5||
 retryPacket.getUint8(1)!==1||retryPacket.getUint32(5)!==q.logToken||
 q.logSequence!==firstExtensionSequence+1)
 throw Error('production timeout did not retry the same v1 extension transaction');
receive.call(q,reply(5,255,12,0,firstExtensionSequence,q.logToken,1));
if(q.logPending!==5)throw Error('stale extension response completed the retried transaction');
receive.call(q,reply(5,255,12,0,q.logSequence,q.logToken,1));
if(q.logComplete.diagnostics!==undefined||q.logPending!==0)
 throw Error('v1 fallback did not finish without fabricating diagnostic data');
const exported={token:0xffffffff,downloaded:'2026-11-08T12:34:56.789Z',firmware:'7.00',
 hardware:'MK5',device:'device, "A"',fault:3,
 rows:Array.from({length:10},(_,i)=>[i+1,1.25+i,2.5,3.75,4.5,5.25,6.5,7])};
const text=csv(exported), parsed=text.trimEnd().split('\n');
if(parsed.length!==19||parsed[6]!=='logging_fault,3'||parsed[7]!==''||
 parsed[8]!=='speed,valid_samples,sum_abs_erpm,sum_input_current_A,sum_input_power_W,sum_abs_erpm_error,sum_abs_duty,peak_abs_phase_current_A,rejected_samples'||
 !parsed[5].includes('"device, ""A"""')||!parsed[9].includes('1.25')||!parsed[18].startsWith('9,'))
 throw Error('CSV metadata, quoting, numerical values, or ten row serialization is incorrect');
q.logDocumentsPath=vm.runInContext('(function(){'+source('DOCUMENTS_PATH')+'\n})',ctx);
q.logComplete=exported;q.logSaveCsv();
const path=Object.keys(q.files).find(p=>p.includes('/blacktip-results-'));
if(!path||!path.startsWith('/tmp/blacktip-results-')||!path.endsWith('.csv')||Buffer.from(q.files[path]).toString()!==text||!q.logExportMessage.includes('Verified'))
 throw Error('CSV production save/readback failed');
for (const [url, expected] of [
 ['file:///home/user/My%20Documents','/home/user/My Documents'],
 ['file:///home/user/100%25%20done','/home/user/100% done'],
 ['file://localhost/home/user/docs','/home/user/docs'],
 ['file://server/share/docs','//server/share/docs'],
 ['file:///C:/Users/name/Documents','C:/Users/name/Documents']]) {
 q.Platform.StandardPaths.path={toString(){return url}};
 if(q.logDocumentsPath()!==expected)throw Error('Documents URL conversion failed: '+url+' => '+q.logDocumentsPath());
}
for (const url of ['https://example.test/docs','relative/docs','file:///bad%ZZ','file:///docs?query=1','file:///docs#fragment']) {
 q.Platform.StandardPaths.path={toString(){return url}};
 if(q.logDocumentsPath()!=='')throw Error('unsafe Documents URL accepted: '+url);
}
q.Platform.StandardPaths.path={toString(){return 'file:///tmp'}};
const old=q.files[path];q.logWriter.writeToLogFile=()=>false;q.logSaveCsv();
if(q.files[path]!==old||!q.logExportMessage.includes('failed'))
 throw Error('CSV failed write did not preserve prior file/report failure');
q.logWriter.writeToLogFile=()=>true;q.Platform.StandardPaths.writableLocation=()=>'';
q.logSaveCsv();if(!q.logExportMessage.includes('Cannot determine'))throw Error('unsupported path not reported');
q.Platform.StandardPaths.writableLocation=()=>({toString(){return 'file:///tmp'}});
const previous=q.logComplete;
// Stale sequence, malformed short response and stale token are ignored.
q.logPending=2;q.logSequence++;
receive.call(q,reply(2,255,20,0,q.logSequence-1,q.logToken));
if(q.logPending!==2)throw Error('stale sequence mutated the transaction');
receive.call(q,new DataView(new ArrayBuffer(8)));
if(q.logPending!==2)throw Error('malformed packet mutated the transaction');
receive.call(q,reply(2,255,19));
if(q.logPending!==2)throw Error('malformed v1 response length mutated the transaction');
receive.call(q,reply(2,255,20,0,q.logSequence,q.logToken+1));
if(q.logPending!==2)throw Error('stale token mutated the transaction');
// A fault mismatch fails the transfer but preserves the last complete result.
q.logPending=3;q.logRow=0;q.logSequence++;
const bad=reply(3,0,44,1);bad.setUint32(12,1);
for(let i=0;i<5;i++)bad.setFloat32(16+i*4,i+1);
bad.setFloat32(36,6);bad.setUint32(40,0);receive.call(q,bad);
if(q.logComplete!==previous||q.logPending!==0)throw Error('fault mismatch replaced results');
// Disconnect, app suspension and exhausted retry use the actual failure paths.
q.logPending=1;q.VescIf.connected=false;receive.call(q,reply(1,255,12));
if(q.logComplete!==previous||q.logPending!==0)throw Error('disconnect lost complete result');
q.VescIf.connected=true;q.logPending=1;suspended.call(q,1);
if(q.logComplete!==previous||q.logPending!==0)throw Error('suspension lost complete result');
q.logPending=1;q.logRetries=2;timeout.call(q);
if(q.logComplete!==previous||q.logPending!==0)throw Error('timeout lost complete result');
// A QML recreation gets a fresh logComplete property, not the old instance's RAM.
const recreated=vm.createContext({logComplete:null});
if(recreated.logComplete!==null || q.logComplete!==previous)
 throw Error('fixture incorrectly assumes reconnect preserves results');
 console.log(JSON.stringify({rows:previous.rows.length,preserved:q.logComplete===previous,
  sent:q.mCommands.sent.length,timeoutFailures:q.logTimeout.stops}));
'''
    assert qml.count('.arg(logTokenText(logComplete.token))') == 2
    for name, value in zip(('RECEIVE', 'VOLTAGE_CONSISTENT', 'FAIL', 'FINISH', 'REQUEST', 'DOWNLOAD_DIAGNOSTICS',
                            'SUSPEND', 'TIMEOUT', 'TOKEN_TEXT', 'CSV_CELL',
                            'CSV', 'DIAGNOSTIC_CSV', 'DOCUMENTS_PATH', 'SAVE'), encoded):
        fixture = fixture.replace("source('" + name + "')",
                                  "source('" + value + "')")
    with tempfile.TemporaryDirectory() as temp:
        path = Path(temp) / 'qml-fixture.js'
        path.write_text(fixture)
        result = subprocess.run([node, str(path)], capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout.strip()
