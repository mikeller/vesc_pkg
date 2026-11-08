"""Execute the actual QML logReceive handler with a Node fixture context."""

import base64
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run():
    node = shutil.which('node')
    if not node:
        return None
    qml = (ROOT / 'ui.qml').read_text()
    marker = 'function logReceive(view) {'
    start = qml.index(marker) + len(marker)
    depth = 1
    end = start
    while depth:
        if qml[end] == '{':
            depth += 1
        elif qml[end] == '}':
            depth -= 1
        end += 1
    body = qml[start:end - 1]
    fixture = r'''
const vm = require('vm');
const q = { logComplete: {old:true}, logRows: [], logToken: 51,
  logSequence: 8, logPending: 2, logRow: 255, logRetries: 0,
  logExpectedCount: 0, logExpectedRejected: 0, logExpectedFault: 0,
  logConnectedDevice: 'device', firmwareVersion: '7.00',
  detectedHardwareModel: 'MK5', logMessage: '', logStatus: '',
  VescIf: {isPortConnected:()=>true, getConnectedUuid:()=> 'device', getConnectedPortName:()=>''},
  mCommands: {sendCustomAppData:()=>{}}, logTimeout: {stop:()=>{},restart:()=>{}},
  qsTr:s=>s, logFail:(s)=>{q.logPending=0;q.logRows=[];q.logMessage=s;},
  logRequest:(op,row)=>{q.logPending=op;q.logRow=row;q.logSequence++;} };
const ctx = vm.createContext(q);
const body = Buffer.from('BODY_B64','base64').toString();
const receive = vm.runInContext('(function(view) {' + body + '\n})', ctx);
function reply(op,row,length,fault=0) {
  const b=new ArrayBuffer(length), v=new DataView(b);
  v.setUint8(1,1); v.setUint8(2,op); v.setUint16(3,q.logSequence);
  v.setUint32(5,q.logToken); v.setUint8(9,0); v.setUint8(10,row); v.setUint8(11,fault);
  return v;
}
const summary=reply(2,255,20);
receive.call(q,summary);
if(q.logPending!==3 || q.logRow!==0) throw Error('summary state: '+q.logPending+'/'+q.logRow+'/'+q.logSequence+'/'+q.logMessage);
q.logExpectedCount=10; q.logExpectedRejected=0; q.logExpectedFault=0;
for(let row=0;row<10;row++) {
  if(q.logRow!==row) throw Error('out-of-order row request');
  const v=reply(3,row,44); v.setUint32(12,1);
  for(let i=0;i<5;i++) v.setFloat32(16+i*4,i+1);
  v.setFloat32(36,6); v.setUint32(40,0);
  receive.call(q,v);
}
if(!q.logComplete || q.logComplete.rows.length!==10 || q.logPending!==0)
  throw Error('ten production QML rows were not committed');
const previous=q.logComplete;
q.logPending=3; q.logRow=0; q.logSequence++;
const bad=reply(3,0,44,1); bad.setUint32(12,1);
for(let i=0;i<5;i++) bad.setFloat32(16+i*4,i+1);
bad.setFloat32(36,6); bad.setUint32(40,0);
receive.call(q,bad);
if(q.logComplete!==previous) throw Error('failed row replaced the complete snapshot');
console.log(JSON.stringify({rows:previous.rows.length, preserved:q.logComplete===previous,
  failureMessage:q.logMessage}));
'''.replace('BODY_B64', base64.b64encode(body.encode()).decode())
    with tempfile.TemporaryDirectory() as temp:
        path = Path(temp) / 'qml-fixture.js'
        path.write_text(fixture)
        result = subprocess.run([node, str(path)], capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout.strip()
