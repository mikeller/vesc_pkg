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
    token_text = body_after(qml, 'function logTokenText(token)')
    fail = body_after(qml, 'function logFail(message)')
    request = body_after(qml, 'function logRequest(op, row)')
    app_signal = body_after(qml, 'function onStateChanged(state)')
    timer_at = qml.index('id: logTimeout')
    timeout = body_after(qml, 'onTriggered:', timer_at)
    scripts = [receive, fail, request, app_signal, timeout, token_text]
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
 qsTr:s=>s,Qt:{ApplicationActive:4}};
const ctx=vm.createContext(q);
function source(s){return Buffer.from(s,'base64').toString()}
const tokenText=vm.runInContext('(function(token){'+source('TOKEN_TEXT')+'\n})',ctx);
for (const [value, expected] of [[1,'0x1'],[0x7fffffff,'0x7fffffff'],
    [0x80000000,'0x80000000'],[0xfffffffe,'0xfffffffe'],
    [0xffffffff,'0xffffffff'],[-1,'0xffffffff']]) {
 if(tokenText(value)!==expected)throw Error('snapshot token formatting: '+value);
}
if(tokenText(0xfffffffe)===tokenText(0xffffffff))throw Error('adjacent tokens collapsed');
const receive=vm.runInContext('(function(view){'+source('RECEIVE')+'\n})',ctx);
q.logFail=vm.runInContext('(function(message){'+source('FAIL')+'\n})',ctx);
q.logRequest=vm.runInContext('(function(op,row){'+source('REQUEST')+'\n})',ctx);
const suspended=vm.runInContext('(function(state){'+source('SUSPEND')+'\n})',ctx);
const timeout=vm.runInContext('(function(){'+source('TIMEOUT')+'\n})',ctx);
function reply(op,row,length,fault=0,sequence=q.logSequence,token=q.logToken){
 const b=new ArrayBuffer(length),v=new DataView(b);
 v.setUint8(1,1);v.setUint8(2,op);v.setUint16(3,sequence);
 v.setUint32(5,token);v.setUint8(9,0);v.setUint8(10,row);v.setUint8(11,fault);return v;
}
const summary=reply(2,255,20);new DataView(summary.buffer).setUint32(12,10);
receive.call(q,summary);
if(q.logPending!==3||q.logRow!==0||q.logExpectedCount!==10)
 throw Error('production summary handler failed to request row zero/read wire totals');
for(let row=0;row<10;row++){
 if(q.logRow!==row)throw Error('production request order mismatch at '+row);
 const v=reply(3,row,44);v.setUint32(12,1);
 for(let i=0;i<5;i++)v.setFloat32(16+i*4,i+1);
 v.setFloat32(36,6);v.setUint32(40,0);receive.call(q,v);
}
if(!q.logComplete||q.logComplete.rows.length!==10||q.logPending!==0)
 throw Error('production handler did not commit all ten rows');
const previous=q.logComplete;
// Stale sequence, malformed short response and stale token are ignored.
q.logPending=2;q.logSequence++;
receive.call(q,reply(2,255,20,0,q.logSequence-1,q.logToken));
if(q.logPending!==2)throw Error('stale sequence mutated the transaction');
receive.call(q,new DataView(new ArrayBuffer(8)));
if(q.logPending!==2)throw Error('malformed packet mutated the transaction');
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
    for name, value in zip(('RECEIVE', 'FAIL', 'REQUEST', 'SUSPEND', 'TIMEOUT', 'TOKEN_TEXT'), encoded):
        fixture = fixture.replace(name, value)
    with tempfile.TemporaryDirectory() as temp:
        path = Path(temp) / 'qml-fixture.js'
        path.write_text(fixture)
        result = subprocess.run([node, str(path)], capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout.strip()
