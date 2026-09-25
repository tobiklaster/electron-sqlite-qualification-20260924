const fs=require('fs');
const path=require('path');
const os=require('os');
const crypto=require('crypto');
const cp=require('child_process');

const [resultsDir]=process.argv.slice(2);
if(!resultsDir) throw new Error('resultsDir required');
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const resolution=JSON.parse(fs.readFileSync(path.join(resultsDir,'resolution-preflight.json'),'utf8'));
const work=fs.mkdtempSync(path.join(process.env.RUNNER_TEMP||os.tmpdir(),'forge7-extractor-probe-'));
const fixtures=path.join(work,'fixtures');
const positiveOut=path.join(work,'positive-out');
const traversalOut=path.join(work,'traversal-out');
const symlinkOut=path.join(work,'symlink-out');
const traversalEscape=path.join(work,'escape.txt');
const symlinkEscapeRoot=path.join(work,'outside-symlink-target');
fs.mkdirSync(fixtures,{recursive:true});
fs.mkdirSync(symlinkEscapeRoot,{recursive:true});

const py=String.raw`
import zipfile, pathlib, stat, sys
root=pathlib.Path(sys.argv[1])
with zipfile.ZipFile(root/'positive.zip','w',zipfile.ZIP_DEFLATED) as z:
    z.writestr('a.txt', b'alpha\n')
    z.writestr('dir/b.bin', bytes([0,1,2,3,255]))
with zipfile.ZipFile(root/'traversal.zip','w',zipfile.ZIP_DEFLATED) as z:
    z.writestr('../escape.txt', b'escape')
with zipfile.ZipFile(root/'symlink.zip','w',zipfile.ZIP_DEFLATED) as z:
    i=zipfile.ZipInfo('link')
    i.create_system=3
    i.external_attr=(stat.S_IFLNK | 0o777) << 16
    z.writestr(i, '../outside-symlink-target')
    z.writestr('link/pwned.txt', b'pwned')
`;
const pyRun=cp.spawnSync('python3',['-c',py,fixtures],{encoding:'utf8'});
if(pyRun.status!==0) throw new Error('fixture generation failed: '+(pyRun.stderr||pyRun.stdout));

const packagerRoot=path.dirname(resolution.installed_packager.package_json);
const unzipPath=path.join(packagerRoot,'dist','unzip.js');
const evidence={
  schema:'ENGOS_PUBLIC_SYNTHETIC_FORGE7_PACKAGER18_EXTRACTOR_COMPATIBILITY_PROBE_V1',
  host:{node:process.version,require_module:Boolean(process.features?.require_module)},
  packager:{version:resolution.installed_packager.version,package_json:resolution.installed_packager.package_json,unzip_helper:unzipPath},
  alias:resolution.packager_extract_zip,
  positive:null,
  negatives:{traversal:null,symlink:null},
  result:'HOLD'
};

function tree(root){
  if(!fs.existsSync(root)) return [];
  const out=[];
  const walk=(d)=>{
    for(const e of fs.readdirSync(d,{withFileTypes:true})){
      const p=path.join(d,e.name);
      if(e.isDirectory()) walk(p);
      else if(e.isFile()){
        const b=fs.readFileSync(p);
        out.push({path:path.relative(root,p).split(path.sep).join('/'),bytes:b.length,sha256:sha(b)});
      } else if(e.isSymbolicLink()) {
        out.push({path:path.relative(root,p).split(path.sep).join('/'),symlink_target:fs.readlinkSync(p)});
      }
    }
  };
  walk(root); return out.sort((a,b)=>a.path.localeCompare(b.path));
}

async function invoke(zip,target){
  fs.mkdirSync(target,{recursive:true});
  const mod=require(unzipPath);
  if(typeof mod.extractElectronZip!=='function') throw new Error('Packager compiled unzip helper does not export extractElectronZip');
  await mod.extractElectronZip(zip,target);
}

(async()=>{
  try{
    await invoke(path.join(fixtures,'positive.zip'),positiveOut);
    const t=tree(positiveOut);
    const expect={
      'a.txt':sha(Buffer.from('alpha\n')),
      'dir/b.bin':sha(Buffer.from([0,1,2,3,255]))
    };
    const ok=t.length===2 && t.every(x=>expect[x.path]===x.sha256);
    evidence.positive={result:ok?'PASS':'HOLD',tree:t,expected_sha256:expect};
    if(!ok) throw new Error('positive extraction byte/hash mismatch');
  }catch(e){
    evidence.positive={result:'HOLD',error:{name:e.name,message:e.message,code:e.code||null,stack:e.stack||null}};
    fs.writeFileSync(path.join(resultsDir,'extractor-compatibility.json'),JSON.stringify(evidence,null,2)+'\n');
    process.exit(42);
  }

  let traversalError=null;
  try{ await invoke(path.join(fixtures,'traversal.zip'),traversalOut); }
  catch(e){ traversalError={name:e.name,message:e.message,code:e.code||null}; }
  const traversalEscaped=fs.existsSync(traversalEscape);
  evidence.negatives.traversal={
    result:traversalEscaped?'HOLD':'PASS',
    rejected:Boolean(traversalError),
    error:traversalError,
    escaped_path:traversalEscape,
    escaped_path_exists:traversalEscaped,
    target_tree:tree(traversalOut)
  };

  let symlinkError=null;
  try{ await invoke(path.join(fixtures,'symlink.zip'),symlinkOut); }
  catch(e){ symlinkError={name:e.name,message:e.message,code:e.code||null}; }
  const escapedPwn=path.join(symlinkEscapeRoot,'pwned.txt');
  const symlinkEscaped=fs.existsSync(escapedPwn);
  evidence.negatives.symlink={
    result:symlinkEscaped?'HOLD':'PASS',
    rejected:Boolean(symlinkError),
    error:symlinkError,
    escaped_path:escapedPwn,
    escaped_path_exists:symlinkEscaped,
    target_tree:tree(symlinkOut),
    outside_tree:tree(symlinkEscapeRoot)
  };

  evidence.result=
    evidence.host.require_module===true &&
    evidence.packager.version==='18.4.4' &&
    evidence.alias?.underlying_name==='@electron-internal/extract-zip' &&
    evidence.alias?.underlying_version==='1.0.5' &&
    evidence.positive.result==='PASS' &&
    evidence.negatives.traversal.result==='PASS' &&
    evidence.negatives.symlink.result==='PASS'
      ? 'PASS' : 'HOLD';

  fs.writeFileSync(path.join(resultsDir,'extractor-compatibility.json'),JSON.stringify(evidence,null,2)+'\n');
  process.exit(evidence.result==='PASS'?0:42);
})().catch(e=>{
  evidence.fatal={name:e.name,message:e.message,code:e.code||null,stack:e.stack||null};
  fs.writeFileSync(path.join(resultsDir,'extractor-compatibility.json'),JSON.stringify(evidence,null,2)+'\n');
  process.exit(42);
});
