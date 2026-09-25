#!/usr/bin/env bash
set -Eeuo pipefail
export CI=1

ROOT="$PWD"
RESULTS="$ROOT/.qualification/security-repair"
WORK="$RUNNER_TEMP/bs01-forge7-declared-range-secure-recovery"
NPM_PREFIX="$RUNNER_TEMP/npm11-forge7-recovery"
rm -rf "$RESULTS" "$WORK" "$NPM_PREFIX"
mkdir -p "$RESULTS" "$WORK" "$NPM_PREFIX"

finalize_artifact() {
  cp "$ROOT/.qualification/results/RUNNER_PREFLIGHT.json" "$RESULTS/RUNNER_PREFLIGHT.json" 2>/dev/null || true
  python3 - "$RESULTS" <<'PY'
from pathlib import Path
import hashlib,json,sys,zipfile,os
root=Path(sys.argv[1])
members=[]
for p in sorted(root.rglob('*')):
    if p.is_file() and p.name not in ('MANIFEST.json','toolchain-security-repair-result.zip'):
        b=p.read_bytes()
        members.append({'path':p.relative_to(root).as_posix(),'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()})
semantic=None
fp=root/'final-status.json'
if fp.exists():
    try: semantic=json.loads(fp.read_text()).get('SEMANTIC_QUALIFICATION_RESULT')
    except Exception: semantic='UNREADABLE_FINAL_STATUS'
manifest={
  'schema':'ENGOS_PUBLIC_SYNTHETIC_FORGE7_DECLARED_RANGE_SECURE_RECOVERY_RESULT_MANIFEST_V1',
  'github_repository':os.environ.get('GITHUB_REPOSITORY'),
  'github_sha':os.environ.get('GITHUB_SHA'),
  'runner_name':os.environ.get('RUNNER_NAME'),
  'runner_os':os.environ.get('RUNNER_OS'),
  'runner_arch':os.environ.get('RUNNER_ARCH'),
  'SEMANTIC_QUALIFICATION_RESULT':semantic,
  'GITHUB_JOB_CONCLUSION_IS_QUALIFICATION_STATE':False,
  'members':members,
  'semantic_ceiling':'QUALIFICATION_EVIDENCE_ONLY__NO_BASELINE_ADOPTION',
  'product_repository_write':False,
  'bs01_build':False,
  'qg_effect':False,
  'formal_effect':False
}
(root/'MANIFEST.json').write_text(json.dumps(manifest,indent=2)+'\n')
zip_path=root/'toolchain-security-repair-result.zip'
with zipfile.ZipFile(zip_path,'w',zipfile.ZIP_DEFLATED) as z:
    for p in sorted(root.rglob('*')):
        if p.is_file() and p != zip_path:
            z.write(p,p.relative_to(root))
print('SECURITY_REPAIR_RESULT_ZIP_SHA256='+hashlib.sha256(zip_path.read_bytes()).hexdigest())
PY
}

emit_q01_q03_status() {
  node - "$RESULTS/q01-q03.json" <<'NODE'
const fs=require('fs'),path=require('path');
const outPath=process.argv[2],dir=path.dirname(outPath);
const read=(name)=>{const p=path.join(dir,name);if(!fs.existsSync(p))return null;try{return JSON.parse(fs.readFileSync(p,'utf8'))}catch{return null}};
const exists=(name)=>fs.existsSync(path.join(dir,name));
const sec=read('security-preflight.json');
const extractor=read('extractor-compatibility.json');
const direct=read('direct-rebuild-evidence.json');
const dev=read('dev-runtime.json');
const packaged=read('packaged-runtime.json');
const neg=read('active-native-negative.json');
const restored=read('post-restore-runtime.json');

const q01=(sec?.result==='PASS'&&extractor?.result==='PASS')?'PASS':'HOLD';
const q02=(q01==='PASS'&&dev?.result==='PASS'&&packaged?.result==='PASS'&&exists('forge-package.log'))?'PASS':'HOLD';
const restoreIdentityPass=
  restored?.result==='PASS' &&
  restored?.native_binding_loaded===true &&
  restored?.sqlite_version==='3.53.4' &&
  restored?.versions?.electron==='44.4.4' &&
  restored?.versions?.node==='24.21.0' &&
  restored?.versions?.chrome==='152.0.7977.130';
const q03=(q02==='PASS'&&direct?.result==='PASS'&&neg?.result==='PASS'&&restoreIdentityPass)?'PASS':'HOLD';
const aggregate=(q01==='PASS'&&q02==='PASS'&&q03==='PASS')?'PASS':'HOLD';

fs.writeFileSync(outPath,JSON.stringify({
  result:aggregate,
  Q01_LOCK_INTEGRITY:{result:q01},
  Q02_PACKAGE_LAUNCH:{result:q02},
  Q03_NATIVE_BINDING:{result:q03},
  independent_gate_statuses:true,
  semantic_pass_requires_all_three_pass:true
},null,2)+'\n');
NODE
}

semantic_hold() {
  local semantic="$1" stage="$2" rc="${3:-42}"
  emit_q01_q03_status
  node - "$RESULTS/final-status.json" "$RESULTS/q01-q03.json" "$semantic" "$stage" "$rc" <<'NODE'
const fs=require('fs');
const [outPath,qPath,semantic,stage,rc]=process.argv.slice(2);
const q=JSON.parse(fs.readFileSync(qPath,'utf8'));
fs.writeFileSync(outPath,JSON.stringify({
  SEMANTIC_QUALIFICATION_RESULT:semantic,
  result:semantic,
  failure_stage:stage,
  exit_code:Number(rc),
  Q01:q.Q01_LOCK_INTEGRITY.result,
  Q02:q.Q02_PACKAGE_LAUNCH.result,
  Q03:q.Q03_NATIVE_BINDING.result,
  github_job_conclusion_authoritative:false,
  baseline_adoption:false,
  product_repository_write:false,
  bs01_build:false,
  qg_effect:false,
  formal_effect:false
},null,2)+'\n');
NODE
  finalize_artifact
  exit 0
}

cp "$ROOT/security-repair/package-template.json" "$WORK/package.json"
cp "$ROOT/index.html" "$ROOT/types.d.ts" "$ROOT/tsconfig.json" "$ROOT/forge.config.cjs" "$WORK/"
cp "$ROOT/vite.main.config.mjs" "$ROOT/vite.preload.config.mjs" "$ROOT/vite.renderer.config.mjs" "$WORK/"
mkdir -p "$WORK/src"
cp "$ROOT/src/main.ts" "$ROOT/src/preload.ts" "$ROOT/src/renderer.ts" "$WORK/src/"

(
  cd "$RUNNER_TEMP"
  command npm install --prefix "$NPM_PREFIX" npm@11.19.0 --ignore-scripts=false --no-audit --no-fund >/dev/null
)
export PATH="$NPM_PREFIX/node_modules/.bin:$PATH"
NPM="$(command -v npm)"
[[ "$("$NPM" --version)" == "11.19.0" ]]

node - "$RESULTS" <<'NODE'
const fs=require('fs'),path=require('path');
fs.writeFileSync(path.join(process.argv[2],'host-identity.json'),JSON.stringify({
  node:process.version,npm:null,platform:process.platform,arch:process.arch,
  require_module:Boolean(process.features?.require_module),versions:process.versions
},null,2)+'\n');
NODE
node - "$RESULTS/host-identity.json" "$("$NPM" --version)" <<'NODE'
const fs=require('fs');const p=process.argv[2],npm=process.argv[3];
const o=JSON.parse(fs.readFileSync(p,'utf8'));o.npm=npm;fs.writeFileSync(p,JSON.stringify(o,null,2)+'\n');
NODE

cd "$WORK"

set +e
"$NPM" install --package-lock-only --ignore-scripts=false --no-audit --no-fund > "$RESULTS/fresh-lock-pass1.log" 2>&1
LOCK1_RC=$?
set -e
[[ "$LOCK1_RC" -eq 0 ]] || semantic_hold "HOLD_FRESH_RESOLUTION_OR_INSTALL" "fresh_lock_pass1" "$LOCK1_RC"

node - <<'NODE'
const fs=require('fs');
const p=JSON.parse(fs.readFileSync('package.json','utf8'));
p.allowScripts={'better-sqlite3@13.0.3':true};
fs.writeFileSync('package.json',JSON.stringify(p,null,2)+'\n');
NODE
rm -f package-lock.json

set +e
"$NPM" install --package-lock-only --ignore-scripts=false --no-audit --no-fund > "$RESULTS/fresh-lock-pass2.log" 2>&1
LOCK2_RC=$?
set -e
[[ "$LOCK2_RC" -eq 0 ]] || semantic_hold "HOLD_FRESH_RESOLUTION_OR_INSTALL" "fresh_lock_pass2" "$LOCK2_RC"

cp package.json "$RESULTS/exact-package.json"
cp package-lock.json "$RESULTS/fresh-package-lock.json"

rm -rf node_modules
set +e
"$NPM" ci --ignore-scripts=false --no-audit --no-fund > "$RESULTS/npm-ci.log" 2>&1
NPM_CI_RC=$?
set -e
[[ "$NPM_CI_RC" -eq 0 ]] || semantic_hold "HOLD_FRESH_RESOLUTION_OR_INSTALL" "npm_ci" "$NPM_CI_RC"

./node_modules/.bin/install-electron --no
[[ -x node_modules/electron/dist/electron ]]
[[ -f node_modules/electron/dist/chrome-sandbox ]]

set +e
"$NPM" ls --all > "$RESULTS/npm-ls-full.txt" 2>&1
NPM_LS_FULL_RC=$?
"$NPM" ls --all --json > "$RESULTS/npm-ls-full.json" 2> "$RESULTS/npm-ls-full-json.stderr.txt"
NPM_LS_FULL_JSON_RC=$?
"$NPM" ls @electron-forge/core @electron/rebuild @electron/packager extract-zip @electron-internal/extract-zip tmp external-editor tar --all > "$RESULTS/npm-ls-focused.txt" 2>&1
NPM_LS_FOCUSED_RC=$?
"$NPM" ls @electron-forge/core @electron/rebuild @electron/packager extract-zip @electron-internal/extract-zip tmp external-editor tar --all --json > "$RESULTS/npm-ls-focused.json" 2> "$RESULTS/npm-ls-focused-json.stderr.txt"
NPM_LS_FOCUSED_JSON_RC=$?
"$NPM" explain extract-zip > "$RESULTS/npm-explain-extract-zip.txt" 2>&1
NPM_EXPLAIN_EXTRACT_RC=$?
"$NPM" explain @electron-internal/extract-zip > "$RESULTS/npm-explain-internal-extract-zip.txt" 2>&1
NPM_EXPLAIN_INTERNAL_RC=$?
set -e

node - "$RESULTS/npm-ls-full-status.json" "$NPM_LS_FULL_RC" "$NPM_LS_FULL_JSON_RC" <<'NODE'
const fs=require('fs');fs.writeFileSync(process.argv[2],JSON.stringify({exit_code:Number(process.argv[3]),json_exit_code:Number(process.argv[4])},null,2)+'\n');
NODE
node - "$RESULTS/npm-ls-focused-status.json" "$NPM_LS_FOCUSED_RC" "$NPM_LS_FOCUSED_JSON_RC" "$NPM_EXPLAIN_EXTRACT_RC" "$NPM_EXPLAIN_INTERNAL_RC" <<'NODE'
const fs=require('fs');fs.writeFileSync(process.argv[2],JSON.stringify({
  exit_code:Number(process.argv[3]),json_exit_code:Number(process.argv[4]),
  explain_extract_zip_exit_code:Number(process.argv[5]),explain_internal_extract_zip_exit_code:Number(process.argv[6])
},null,2)+'\n');
NODE

node - "$RESULTS/resolution-preflight.json" <<'NODE'
const fs=require('fs'),path=require('path');const {createRequire}=require('module');
const lock=JSON.parse(fs.readFileSync('package-lock.json','utf8'));
function dirs(name){const suffix='node_modules/'+name;return Object.keys(lock.packages||{}).filter(p=>p===suffix||p.endsWith('/'+suffix)).sort((a,b)=>a.length-b.length||a.localeCompare(b));}
function at(rel){const p=path.join(process.cwd(),rel,'package.json');return {path:p,json:JSON.parse(fs.readFileSync(p,'utf8'))};}
function fromEntry(entry){let d=path.dirname(entry);while(true){const p=path.join(d,'package.json');if(fs.existsSync(p)){try{return {path:p,json:JSON.parse(fs.readFileSync(p,'utf8'))};}catch{}}const u=path.dirname(d);if(u===d)break;d=u;}throw new Error('package root not found for '+entry);}
const packager=at(dirs('@electron/packager')[0]),core=at(dirs('@electron-forge/core')[0]),ext=at(dirs('external-editor')[0]);
const packagerReq=createRequire(packager.path),coreReq=createRequire(core.path),extReq=createRequire(ext.path);
const semver=packagerReq('semver');
const corePackagerEntry=coreReq.resolve('@electron/packager');
const corePackager=fromEntry(corePackagerEntry);
const tmpPkg=fromEntry(extReq.resolve('tmp'));
const aliasEntry=packagerReq.resolve('extract-zip');
const aliasPkg=fromEntry(aliasEntry);
const packagerEngine=packager.json.engines?.node||null,aliasEngine=aliasPkg.json.engines?.node||null;
const out={
  host:{node:process.version,require_module:Boolean(process.features?.require_module)},
  forge_core:{version:core.json.version,package_json:core.path,declared_packager_range:core.json.dependencies?.['@electron/packager']||null},
  installed_packager:{version:packager.json.version,package_json:packager.path,engine:packagerEngine,engine_satisfied:Boolean(packagerEngine&&semver.satisfies(process.version,packagerEngine)),
    declared_extract_zip_range:packager.json.dependencies?.['extract-zip']||null},
  forge_packager:{version:corePackager.json.version,package_json:corePackager.path,resolved_entry:corePackagerEntry},
  packager_extract_zip:{specifier:'extract-zip',resolved_entry:aliasEntry,package_json:aliasPkg.path,underlying_name:aliasPkg.json.name,
    underlying_version:aliasPkg.json.version,engine:aliasEngine,engine_satisfied:Boolean(aliasEngine&&semver.satisfies(process.version,aliasEngine))},
  external_editor:{version:ext.json.version,package_json:ext.path},
  external_editor_tmp:{version:tmpPkg.json.version,package_json:tmpPkg.path,dependency_path:'external-editor@'+ext.json.version+' -> tmp@'+tmpPkg.json.version}
};
fs.writeFileSync(process.argv[2],JSON.stringify(out,null,2)+'\n');
NODE

set +e
"$NPM" audit --json > "$RESULTS/npm-audit.json"
AUDIT_RC=$?
set -e
node - "$RESULTS/npm-audit-status.json" "$AUDIT_RC" <<'NODE'
const fs=require('fs');fs.writeFileSync(process.argv[2],JSON.stringify({exit_code:Number(process.argv[3])},null,2)+'\n');
NODE

node - "$RESULTS/tar-versions.txt" <<'NODE'
const fs=require('fs');const lock=JSON.parse(fs.readFileSync('package-lock.json','utf8'));
const v=[...new Set(Object.entries(lock.packages||{}).filter(([p,m])=>p==='node_modules/tar'||p.endsWith('/node_modules/tar')).map(([p,m])=>m.version))].sort();
fs.writeFileSync(process.argv[2],v.join('\n')+(v.length?'\n':''));
NODE
node - "$RESULTS/tar-versions.txt" "$RESULTS/tar-registry-metadata.json" "$NPM" <<'NODE'
const fs=require('fs'),cp=require('child_process');const [listPath,outPath,npm]=process.argv.slice(2);
const versions=fs.readFileSync(listPath,'utf8').split(/\r?\n/).filter(Boolean),out={};
for(const v of versions){const r=cp.spawnSync(npm,['view',`tar@${v}`,'version','deprecated','dist.integrity','dist.tarball','--json'],{encoding:'utf8'});
  if(r.status!==0){out[v]={error:r.stderr||r.stdout||`npm view exit ${r.status}`};continue;}
  try{out[v]=JSON.parse(r.stdout)}catch{out[v]={raw:r.stdout.trim()}}}
fs.writeFileSync(outPath,JSON.stringify(out,null,2)+'\n');
NODE

SECURITY_RC=0
node "$ROOT/security-repair/forge7-recovery-analyze.cjs" "$RESULTS" || SECURITY_RC=$?
[[ "$SECURITY_RC" -eq 0 ]] || semantic_hold "HOLD_SECURITY_PREFLIGHT" "security_preflight" "$SECURITY_RC"

EXTRACTOR_RC=0
node "$ROOT/security-repair/forge7-extractor-probe.cjs" "$RESULTS" || EXTRACTOR_RC=$?
[[ "$EXTRACTOR_RC" -eq 0 ]] || semantic_hold "HOLD_EXTRACTOR_COMPATIBILITY" "packager18_scoped_alias_runtime_probe" "$EXTRACTOR_RC"

prepare_suid_sandbox() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  sudo chown root:root "$f"
  sudo chmod 4755 "$f"
  [[ "$(stat -c '%u:%g:%a' "$f")" == "0:0:4755" ]]
}

QUAL_STAGE="rebuild_resolution"
rebuild="$(node - <<'NODE'
const fs=require('fs'),path=require('path');let d=path.dirname(require.resolve('@electron/rebuild'));
while(true){const p=path.join(d,'package.json');if(fs.existsSync(p)){const j=JSON.parse(fs.readFileSync(p,'utf8'));if(j.name==='@electron/rebuild'){process.stdout.write(j.version);process.exit(0);}}
const up=path.dirname(d);if(up===d)break;d=up;}process.exit(42);
NODE
)" || semantic_hold "HOLD_Q01_Q03_REQUALIFICATION" "$QUAL_STAGE" 42
[[ "$rebuild" == "4.2.0" ]] || semantic_hold "HOLD_Q01_Q03_REQUALIFICATION" "$QUAL_STAGE" 42

QUAL_STAGE="electron_rebuild_functional"
set +e
./node_modules/.bin/electron-rebuild -f -w better-sqlite3 -v 44.4.4 > "$RESULTS/electron-rebuild-functional.log" 2>&1
REBUILD_RC=$?
set -e
[[ "$REBUILD_RC" -eq 0 ]] || semantic_hold "HOLD_Q01_Q03_REQUALIFICATION" "$QUAL_STAGE" "$REBUILD_RC"
node - "$RESULTS/direct-rebuild-evidence.json" "$RESULTS/electron-rebuild-functional.log" <<'NODE'
const fs=require('fs'),path=require('path'),crypto=require('crypto');const [outPath,logPath]=process.argv.slice(2);
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
function walk(d,a=[]){for(const e of fs.readdirSync(d,{withFileTypes:true})){const p=path.join(d,e.name);if(e.isDirectory())walk(p,a);else if(e.isFile()&&e.name.endsWith('.node'))a.push(p);}return a;}
const root=path.join(process.cwd(),'node_modules','better-sqlite3'),native=walk(root).sort().map(p=>({path:path.relative(process.cwd(),p),sha256:sha(fs.readFileSync(p)),bytes:fs.statSync(p).size}));
if(!native.length)process.exit(42);fs.writeFileSync(outPath,JSON.stringify({result:'PASS',electron_rebuild:'4.2.0',target_electron:'44.4.4',native_files:native,log_sha256:sha(fs.readFileSync(logPath))},null,2)+'\n');
NODE

prepare_suid_sandbox "node_modules/electron/dist/chrome-sandbox" || semantic_hold "HOLD_Q01_Q03_REQUALIFICATION" "dev_chrome_sandbox" 42

QUAL_STAGE="forge_config_load"
node -e "require('./forge.config.cjs')" || semantic_hold "HOLD_Q01_Q03_REQUALIFICATION" "$QUAL_STAGE" 42
./node_modules/.bin/tsc -p tsconfig.json --noEmit || semantic_hold "HOLD_Q01_Q03_REQUALIFICATION" "typescript_noemit" 42

QUAL_STAGE="forge_start"
rm -rf .vite
set +e
QUAL_PHASE="forge7-recovery-dev" QUAL_RUNTIME_RECEIPT="$RESULTS/dev-runtime.json" timeout 120s xvfb-run -a ./node_modules/.bin/electron-forge start > "$RESULTS/forge-start.log" 2>&1
START_RC=$?
set -e
[[ "$START_RC" -eq 0 ]] || semantic_hold "HOLD_Q01_Q03_REQUALIFICATION" "$QUAL_STAGE" "$START_RC"
node - "$RESULTS/dev-runtime.json" <<'NODE'
const fs=require('fs');const r=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(r.result!=='PASS'||r.native_binding_loaded!==true||r.renderer_ready!==true||r.sqlite_version!=='3.53.4')process.exit(1);
if(r.versions?.electron!=='44.4.4'||r.versions?.node!=='24.21.0'||r.versions?.chrome!=='152.0.7977.130')process.exit(1);
NODE

QUAL_STAGE="forge_package"
rm -rf out .vite
set +e
./node_modules/.bin/electron-forge package > "$RESULTS/forge-package.log" 2>&1
FORGE_RC=$?
set -e
[[ "$FORGE_RC" -eq 0 ]] || semantic_hold "HOLD_Q01_Q03_REQUALIFICATION" "$QUAL_STAGE" "$FORGE_RC"

QUAL_STAGE="package_output"
appdir="$(find out -mindepth 1 -maxdepth 1 -type d -name '*linux-x64' | head -n1)"
[[ -n "$appdir" ]] || semantic_hold "HOLD_Q01_Q03_REQUALIFICATION" "$QUAL_STAGE" 42
appbin="$appdir/electron-sqlite-security-repair-qualification"
[[ -x "$appbin" ]] || semantic_hold "HOLD_Q01_Q03_REQUALIFICATION" "$QUAL_STAGE" 42
prepare_suid_sandbox "$appdir/chrome-sandbox" || semantic_hold "HOLD_Q01_Q03_REQUALIFICATION" "packaged_chrome_sandbox" 42

QUAL_STAGE="native_include"
asar="$appdir/resources/app.asar"
[[ -f "$asar" ]] || semantic_hold "HOLD_Q01_Q03_REQUALIFICATION" "$QUAL_STAGE" 42
asar_sha="$(sha256sum "$asar" | awk '{print $1}')"
native_root="$appdir/resources/app.asar.unpacked/node_modules/better-sqlite3"
[[ -d "$native_root" ]] || semantic_hold "HOLD_Q01_Q03_REQUALIFICATION" "$QUAL_STAGE" 42
mapfile -t native_candidates < <(find "$native_root" -type f -name '*.node' | sort)
[[ "${#native_candidates[@]}" -gt 0 ]] || semantic_hold "HOLD_Q01_Q03_REQUALIFICATION" "$QUAL_STAGE" 42
printf '%s\n' "${native_candidates[@]#"$appdir/"}" > "$RESULTS/packaged-native-candidates.txt"

QUAL_STAGE="packaged_launch"
set +e
QUAL_PHASE="forge7-recovery-packaged" QUAL_RUNTIME_RECEIPT="$RESULTS/packaged-runtime.json" timeout 90s xvfb-run -a "$appbin" > "$RESULTS/packaged-launch.log" 2>&1
PACKAGED_RC=$?
set -e
[[ "$PACKAGED_RC" -eq 0 ]] || semantic_hold "HOLD_Q01_Q03_REQUALIFICATION" "$QUAL_STAGE" "$PACKAGED_RC"
node - "$RESULTS/packaged-runtime.json" <<'NODE'
const fs=require('fs');const r=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(r.result!=='PASS'||r.native_binding_loaded!==true||r.renderer_ready!==true||r.sqlite_version!=='3.53.4')process.exit(1);
if(r.versions?.electron!=='44.4.4'||r.versions?.node!=='24.21.0'||r.versions?.chrome!=='152.0.7977.130')process.exit(1);
NODE

QUAL_STAGE="missing_binding_negative"
native_rel="resources/app.asar.unpacked/node_modules/better-sqlite3/prebuilds/linux-x64.node"
native="$appdir/$native_rel"
negative_phase="forge7-recovery-missing-binding-linux-x64"
negative_log="$RESULTS/missing-binding-active.log"
negative_receipt="$RESULTS/missing-binding-active-runtime.json"
attempt_evidence="$RESULTS/missing-binding-attempt.json"
post_restore_log="$RESULTS/post-restore-launch.log"
post_restore_receipt="$RESULTS/post-restore-runtime.json"

[[ -f "$native" ]] || semantic_hold "HOLD_Q01_Q03_REQUALIFICATION" "active_linux_x64_path_drift" 42
native_sha="$(sha256sum "$native" | awk '{print $1}')"

set +e
node - "$RESULTS/active-native-pre-removal.json" "$appdir" "$native" "$native_sha" "$RESULTS/packaged-runtime.json" <<'NODE'
const fs=require('fs'),path=require('path');
const [out,appdir,native,nativeSha,packagedReceipt]=process.argv.slice(2);
const pre=JSON.parse(fs.readFileSync(packagedReceipt,'utf8'));
const ok=
  fs.existsSync(native) &&
  pre.result==='PASS' &&
  pre.native_binding_loaded===true &&
  pre.sqlite_version==='3.53.4' &&
  pre.versions?.electron==='44.4.4' &&
  pre.versions?.node==='24.21.0' &&
  pre.versions?.chrome==='152.0.7977.130';
fs.writeFileSync(out,JSON.stringify({
  result:ok?'PASS':'HOLD',
  exact_active_native_relative_path:path.relative(appdir,native),
  exact_active_native_absolute_path:native,
  exact_active_native_sha256:nativeSha,
  file_exists_before_removal:fs.existsSync(native),
  normal_packaged_launch_precondition:pre
},null,2)+'\n');
process.exit(ok?0:42);
NODE
PRE_REMOVAL_RC=$?
set -e
if [[ "$PRE_REMOVAL_RC" -ne 0 ]]; then
  semantic_hold "HOLD_Q01_Q03_REQUALIFICATION" "active_linux_x64_pre_removal_precondition" "$PRE_REMOVAL_RC"
fi

set +e
mv "$native" "$native.missing"
REMOVE_RC=$?
set -e
REMOVE_TARGET_ABSENT=false
REMOVE_BACKUP_PRESENT=false
if [[ ! -e "$native" ]]; then REMOVE_TARGET_ABSENT=true; fi
if [[ -f "$native.missing" ]]; then REMOVE_BACKUP_PRESENT=true; fi

node - "$RESULTS/active-native-removal.json" "$appdir" "$native" "$native_sha" "$REMOVE_RC" "$REMOVE_TARGET_ABSENT" "$REMOVE_BACKUP_PRESENT" <<'NODE'
const fs=require('fs'),path=require('path');
const [out,appdir,native,nativeSha,rc,targetAbsent,backupPresent]=process.argv.slice(2);
fs.writeFileSync(out,JSON.stringify({
  exact_active_native_relative_path:path.relative(appdir,native),
  exact_active_native_absolute_path:native,
  exact_active_native_pre_removal_sha256:nativeSha,
  removal_raw_exit_code:Number(rc),
  target_absent_after_removal:targetAbsent==='true',
  backup_present_after_removal:backupPresent==='true',
  removal_result:Number(rc)===0&&targetAbsent==='true'&&backupPresent==='true'?'PASS':'HOLD'
},null,2)+'\n');
NODE

if [[ "$REMOVE_RC" -ne 0 || "$REMOVE_TARGET_ABSENT" != "true" || "$REMOVE_BACKUP_PRESENT" != "true" ]]; then
  REMOVE_HOLD_RC="$REMOVE_RC"
  if [[ "$REMOVE_HOLD_RC" -eq 0 ]]; then REMOVE_HOLD_RC=42; fi
  if [[ -f "$native.missing" && ! -e "$native" ]]; then
    set +e
    mv "$native.missing" "$native"
    REMOVE_FAILURE_RESTORE_RC=$?
    set -e
    node - "$RESULTS/active-native-removal-failure-restore.json" "$REMOVE_FAILURE_RESTORE_RC" "$native" "$native_sha" <<'NODE'
const fs=require('fs'),crypto=require('crypto');
const [out,rc,native,expectedSha]=process.argv.slice(2);
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const exists=fs.existsSync(native);
const actualSha=exists?sha(fs.readFileSync(native)):null;
fs.writeFileSync(out,JSON.stringify({
  restore_raw_exit_code:Number(rc),
  restored_file_exists:exists,
  restored_sha256:actualSha,
  restored_sha256_matches_pre_removal:actualSha===expectedSha
},null,2)+'\n');
NODE
  fi
  semantic_hold "HOLD_Q01_Q03_REQUALIFICATION" "active_linux_x64_removal" "$REMOVE_HOLD_RC"
fi

set +e
QUAL_PHASE="$negative_phase" QUAL_RUNTIME_RECEIPT="$negative_receipt" timeout 60s xvfb-run -a "$appbin" > "$negative_log" 2>&1
missing_rc=$?
set -e
missing_timed_out=false
[[ "$missing_rc" -eq 124 ]] && missing_timed_out=true

# Persist attempt evidence while the exact target is still absent.
node - "$attempt_evidence" "$appdir" "$native" "$native_sha" "$missing_rc" "$missing_timed_out" "$negative_phase" "$negative_log" "$negative_receipt" <<'NODE'
const fs=require('fs'),path=require('path'),crypto=require('crypto');
const [out,appdir,native,nativeSha,rc,timedOut,phase,log,receiptPath]=process.argv.slice(2);
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const receiptExists=fs.existsSync(receiptPath);
const receiptBytes=receiptExists?fs.readFileSync(receiptPath):null;
let receipt=null;
if(receiptBytes){try{receipt=JSON.parse(receiptBytes.toString('utf8'))}catch{}}
fs.writeFileSync(out,JSON.stringify({
  candidate_relative_path:path.relative(appdir,native),
  candidate_absolute_path:native,
  candidate_pre_removal_sha256:nativeSha,
  exact_target_removed:!fs.existsSync(native),
  raw_exit_code:Number(rc),
  timed_out:timedOut==='true',
  stdout_stderr_log_path:log,
  stdout_stderr_log_sha256:sha(fs.readFileSync(log)),
  runtime_receipt_path:receiptPath,
  runtime_receipt_exists:receiptExists,
  runtime_receipt_sha256:receiptBytes?sha(receiptBytes):null,
  runtime_receipt:receipt,
  expected_phase:phase
},null,2)+'\n');
NODE

set +e
mv "$native.missing" "$native"
restore_rc=$?
set -e
restored_sha=""
if [[ "$restore_rc" -eq 0 && -f "$native" ]]; then
  restored_sha="$(sha256sum "$native" | awk '{print $1}')"
fi

set +e
QUAL_PHASE="forge7-recovery-post-restore" QUAL_RUNTIME_RECEIPT="$post_restore_receipt" timeout 60s xvfb-run -a "$appbin" > "$post_restore_log" 2>&1
post_restore_rc=$?
set -e

set +e
node - "$RESULTS/active-native-negative.json" "$attempt_evidence" "$RESULTS/active-native-pre-removal.json" "$restored_sha" "$restore_rc" "$post_restore_rc" "$post_restore_log" "$post_restore_receipt" <<'NODE'
const fs=require('fs'),crypto=require('crypto');
const [out,attemptPath,prePath,restoredSha,restoreRc,postRc,postLog,postReceiptPath]=process.argv.slice(2);
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const attempt=JSON.parse(fs.readFileSync(attemptPath,'utf8'));
const pre=JSON.parse(fs.readFileSync(prePath,'utf8'));
const receipt=attempt.runtime_receipt;
const error=String(receipt?.error||'');
const exactPathMention=
  error.includes(attempt.candidate_absolute_path) ||
  error.includes(attempt.candidate_relative_path);
const unambiguousNativeLoaderFailure=
  /linux-x64\.node|better-sqlite3/i.test(error) &&
  /dlopen|cannot open shared object file|bindings?|\.node/i.test(error);
const logText=fs.readFileSync(attempt.stdout_stderr_log_path,'utf8');
const diagnosticLogRegexMatch=/better[_-]?sqlite|Could not locate the bindings|bindings file|\.node/i.test(logText);

let post=null,postReceiptSha=null;
if(fs.existsSync(postReceiptPath)){
  const b=fs.readFileSync(postReceiptPath);
  postReceiptSha=sha(b);
  try{post=JSON.parse(b.toString('utf8'))}catch{}
}
const restoredBytesMatch=
  Number(restoreRc)===0 &&
  Boolean(restoredSha) &&
  restoredSha===attempt.candidate_pre_removal_sha256;
const negativeCausalPass=
  pre.result==='PASS' &&
  attempt.exact_target_removed===true &&
  attempt.raw_exit_code!==0 &&
  attempt.timed_out===false &&
  attempt.runtime_receipt_exists===true &&
  receipt?.result==='FAIL' &&
  receipt?.phase===attempt.expected_phase &&
  (exactPathMention||unambiguousNativeLoaderFailure);
const postRestorePass=
  Number(postRc)===0 &&
  post?.result==='PASS' &&
  post?.native_binding_loaded===true &&
  post?.sqlite_version==='3.53.4' &&
  post?.versions?.electron==='44.4.4' &&
  post?.versions?.node==='24.21.0' &&
  post?.versions?.chrome==='152.0.7977.130';

const result=(negativeCausalPass&&restoredBytesMatch&&postRestorePass)?'PASS':'HOLD';
fs.writeFileSync(out,JSON.stringify({
  result,
  exact_active_native_relative_path:attempt.candidate_relative_path,
  exact_active_native_sha256:attempt.candidate_pre_removal_sha256,
  missing_binding_exit_code:attempt.raw_exit_code,
  missing_binding_fails_closed:negativeCausalPass,
  timeout_state:attempt.timed_out,
  authoritative_runtime_receipt_sha256:attempt.runtime_receipt_sha256,
  authoritative_runtime_receipt_result:receipt?.result??null,
  authoritative_runtime_receipt_phase:receipt?.phase??null,
  authoritative_runtime_receipt_error:receipt?.error??null,
  exact_path_or_unambiguous_loader_failure:exactPathMention||unambiguousNativeLoaderFailure,
  diagnostic_stdout_stderr_regex_match:diagnosticLogRegexMatch,
  diagnostic_stdout_stderr_regex_is_mandatory:false,
  restored_bytes_sha256:restoredSha||null,
  restored_bytes_match_pre_removal_sha256:restoredBytesMatch,
  post_restore_exit_code:Number(postRc),
  post_restore_log_sha256:sha(fs.readFileSync(postLog)),
  post_restore_runtime_receipt_sha256:postReceiptSha,
  post_restore_runtime_receipt:post,
  post_restore_pass:postRestorePass,
  causal_evidence_complete:result==='PASS'
},null,2)+'\n');
process.exit(result==='PASS'?0:42);
NODE
NEGATIVE_RC=$?
set -e
if [[ "$NEGATIVE_RC" -ne 0 ]]; then
  semantic_hold "HOLD_Q01_Q03_REQUALIFICATION" "$QUAL_STAGE" "$NEGATIVE_RC"
fi

lock_sha="$(node -p "require('$RESULTS/security-preflight.json').lock.raw_sha256")"
graph_sha="$(node -p "require('$RESULTS/security-preflight.json').lock.normalized_graph_sha256")"
audit_sha="$(node -p "require('$RESULTS/security-preflight.json').audit.raw_sha256")"
advisory_sha="$(node -p "require('$RESULTS/security-preflight.json').audit.advisory_inventory_sha256")"
package_log_sha="$(sha256sum "$RESULTS/forge-package.log" | awk '{print $1}')"
start_log_sha="$(sha256sum "$RESULTS/forge-start.log" | awk '{print $1}')"
rebuild_log_sha="$(sha256sum "$RESULTS/electron-rebuild-functional.log" | awk '{print $1}')"
extractor_probe_sha="$(sha256sum "$RESULTS/extractor-compatibility.json" | awk '{print $1}')"

node - "$RESULTS/q01-q03.json" "$lock_sha" "$graph_sha" "$audit_sha" "$advisory_sha" "$asar_sha" "$package_log_sha" "$start_log_sha" "$rebuild_log_sha" "$extractor_probe_sha" <<'NODE'
const fs=require('fs'),path=require('path');
const [p,lockSha,graphSha,auditSha,advSha,asarSha,packageLogSha,startLogSha,rebuildLogSha,extractorProbeSha]=process.argv.slice(2);
const dir=path.dirname(p),runtime=JSON.parse(fs.readFileSync(path.join(dir,'packaged-runtime.json'),'utf8')),dev=JSON.parse(fs.readFileSync(path.join(dir,'dev-runtime.json'),'utf8'));
const resolution=JSON.parse(fs.readFileSync(path.join(dir,'resolution-preflight.json'),'utf8')),extractor=JSON.parse(fs.readFileSync(path.join(dir,'extractor-compatibility.json'),'utf8'));
const direct=JSON.parse(fs.readFileSync(path.join(dir,'direct-rebuild-evidence.json'),'utf8')),neg=JSON.parse(fs.readFileSync(path.join(dir,'active-native-negative.json'),'utf8'));
const out={result:'PASS',
Q01_LOCK_INTEGRITY:{result:'PASS',lockfileVersion:3,lock_sha256:lockSha,normalized_graph_sha256:graphSha,npm:'11.19.0',sri_complete:true,
electron_rebuild:'4.2.0',electron_packager:'18.4.4',external_editor_tmp:'0.2.7',scoped_extractor_alias:resolution.packager_extract_zip,
extractor_runtime_probe_sha256:extractorProbeSha,extractor_runtime_probe_result:extractor.result,npm_audit_json_sha256:auditSha,advisory_inventory_sha256:advSha,high:0,critical:0,npm_ls_clean:true},
Q02_PACKAGE_LAUNCH:{result:'PASS',forge:'7.11.2',forge_vite_plugin:'7.11.2',vite:'8.3.1',electron_packager:'18.4.4',forge_resolved_packager:resolution.forge_packager,
forge_config_load:true,forge_start:true,forge_start_log_sha256:startLogSha,vite_build_via_forge_start_and_package:true,forge_package:true,
forge_package_log_sha256:packageLogSha,packaged_launch:true,dev_runtime_versions:dev.versions,runtime_versions:runtime.versions,sqlite_version:runtime.sqlite_version},
Q03_NATIVE_BINDING:{result:'PASS',better_sqlite3:'13.0.3',native_rebuild_provider:'@electron/rebuild@4.2.0',direct_electron_rebuild_functional:true,direct_rebuild_log_sha256:rebuildLogSha,
direct_rebuild_evidence:direct,forge_native_dependency_preparation:true,packaged_native_relative_path:neg.exact_active_native_relative_path,packaged_native_sha256:neg.exact_active_native_sha256,
app_asar_sha256:asarSha,packaged_native_load:true,missing_binding_test_target:neg.exact_active_native_relative_path,missing_binding_exit_code:neg.missing_binding_exit_code,
missing_binding_fails_closed:neg.missing_binding_fails_closed}};
fs.writeFileSync(p,JSON.stringify(out,null,2)+'\n');
NODE

node - "$RESULTS/final-status.json" <<'NODE'
const fs=require('fs'),path=require('path');const dir=path.dirname(process.argv[2]);
const sec=JSON.parse(fs.readFileSync(path.join(dir,'security-preflight.json'),'utf8'));
const q=JSON.parse(fs.readFileSync(path.join(dir,'q01-q03.json'),'utf8'));
const extractor=JSON.parse(fs.readFileSync(path.join(dir,'extractor-compatibility.json'),'utf8'));
fs.writeFileSync(process.argv[2],JSON.stringify({
  SEMANTIC_QUALIFICATION_RESULT:'FORGE7_DECLARED_RANGE_SECURE_RECOVERY = PASS',
  result:'FORGE7_DECLARED_RANGE_SECURE_RECOVERY_PASS',
  security_preflight:sec.result,extractor_compatibility:extractor.result,
  Q01:q.Q01_LOCK_INTEGRITY.result,Q02:q.Q02_PACKAGE_LAUNCH.result,Q03:q.Q03_NATIVE_BINDING.result,
  proposed_toolchain:{electron:'44.4.4',forge:'7.11.2',forge_vite_plugin:'7.11.2',vite:'8.3.1',typescript:'7.0.2',
    react:'19.3.0',react_dom:'19.3.0',better_sqlite3:'13.0.3',electron_rebuild:'4.2.0',electron_packager:'18.4.4',
    external_editor_tmp:'0.2.7',scoped_extractor_alias:sec.resolution.packager_extract_zip,sqlite:'3.53.4',tar_versions:sec.npm_ls.tar_versions},
  lock_sha256:sec.lock.raw_sha256,graph_sha256:sec.lock.normalized_graph_sha256,
  npm_audit_json_sha256:sec.audit.raw_sha256,advisory_inventory_sha256:sec.audit.advisory_inventory_sha256,
  github_job_conclusion_authoritative:false,baseline_adoption:false,product_repository_write:false,bs01_build:false,qg_effect:false,formal_effect:false
},null,2)+'\n');
NODE

finalize_artifact
exit 0
