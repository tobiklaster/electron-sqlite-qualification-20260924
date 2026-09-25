#!/usr/bin/env bash
set -Eeuo pipefail
export CI=1

ROOT="$PWD"
RESULTS="$ROOT/.qualification/security-repair"
WORK="$RUNNER_TEMP/bs01-toolchain-security-repair"
NPM_PREFIX="$RUNNER_TEMP/npm11-security-repair"
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
manifest={
  'schema':'ENGOS_PUBLIC_SYNTHETIC_TOOLCHAIN_SECURITY_REPAIR_RESULT_MANIFEST_R3_V1',
  'github_repository':os.environ.get('GITHUB_REPOSITORY'),
  'github_sha':os.environ.get('GITHUB_SHA'),
  'runner_name':os.environ.get('RUNNER_NAME'),
  'runner_os':os.environ.get('RUNNER_OS'),
  'runner_arch':os.environ.get('RUNNER_ARCH'),
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

resolution_hold() {
  local stage="$1" rc="$2"
  node - "$RESULTS/final-status.json" "$stage" "$rc" <<'NODE'
const fs=require('fs');
fs.writeFileSync(process.argv[2],JSON.stringify({
  result:'HOLD_FRESH_RESOLUTION_OR_INSTALL',
  failure_stage:process.argv[3],
  exit_code:Number(process.argv[4]),
  q01_q03:'NOT_EXECUTED',
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
const fs=require('fs'), path=require('path');
const out=process.argv[2];
fs.writeFileSync(path.join(out,'host-identity.json'),JSON.stringify({
  node:process.version,
  npm:null,
  platform:process.platform,
  arch:process.arch,
  versions:process.versions
},null,2)+'\n');
NODE
node - "$RESULTS/host-identity.json" "$("$NPM" --version)" <<'NODE'
const fs=require('fs');
const p=process.argv[2], npm=process.argv[3];
const o=JSON.parse(fs.readFileSync(p,'utf8')); o.npm=npm;
fs.writeFileSync(p,JSON.stringify(o,null,2)+'\n');
NODE

cd "$WORK"

# Completely fresh lock materialization.
set +e
"$NPM" install --package-lock-only --ignore-scripts=false --no-audit --no-fund > "$RESULTS/fresh-lock-pass1.log" 2>&1
LOCK1_RC=$?
set -e
[[ "$LOCK1_RC" -eq 0 ]] || resolution_hold "fresh_lock_pass1" "$LOCK1_RC"
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
[[ "$LOCK2_RC" -eq 0 ]] || resolution_hold "fresh_lock_pass2" "$LOCK2_RC"
cp package.json "$RESULTS/exact-package.json"
cp package-lock.json "$RESULTS/fresh-package-lock.json"

# Clean install from the exact fresh lock.
rm -rf node_modules
set +e
"$NPM" ci --ignore-scripts=false --no-audit --no-fund > "$RESULTS/npm-ci.log" 2>&1
NPM_CI_RC=$?
set -e
[[ "$NPM_CI_RC" -eq 0 ]] || resolution_hold "npm_ci" "$NPM_CI_RC"

# Electron binary is materialized explicitly; Forge then uses the resolved rebuild provider.
./node_modules/.bin/install-electron --no
[[ -x node_modules/electron/dist/electron ]]
[[ -f node_modules/electron/dist/chrome-sandbox ]]

set +e
"$NPM" ls --all > "$RESULTS/npm-ls-full.txt" 2>&1
NPM_LS_FULL_RC=$?
"$NPM" ls --all --json > "$RESULTS/npm-ls-full.json" 2> "$RESULTS/npm-ls-full-json.stderr.txt"
NPM_LS_FULL_JSON_RC=$?
"$NPM" ls @electron/rebuild @electron/packager extract-zip @electron-internal/extract-zip tmp external-editor --all > "$RESULTS/npm-ls-focused.txt" 2>&1
NPM_LS_FOCUSED_RC=$?
"$NPM" ls @electron/rebuild @electron/packager extract-zip @electron-internal/extract-zip tmp external-editor --all --json > "$RESULTS/npm-ls-focused.json" 2> "$RESULTS/npm-ls-focused-json.stderr.txt"
NPM_LS_FOCUSED_JSON_RC=$?
set -e
node - "$RESULTS/npm-ls-full-status.json" "$NPM_LS_FULL_RC" "$NPM_LS_FULL_JSON_RC" <<'NODE'
const fs=require('fs');fs.writeFileSync(process.argv[2],JSON.stringify({exit_code:Number(process.argv[3]),json_exit_code:Number(process.argv[4])},null,2)+'\n');
NODE
node - "$RESULTS/npm-ls-focused-status.json" "$NPM_LS_FOCUSED_RC" "$NPM_LS_FOCUSED_JSON_RC" <<'NODE'
const fs=require('fs');fs.writeFileSync(process.argv[2],JSON.stringify({exit_code:Number(process.argv[3]),json_exit_code:Number(process.argv[4])},null,2)+'\n');
NODE

node - "$RESULTS/compatibility-preflight.json" <<'NODE'
const fs=require('fs'),path=require('path');const {createRequire}=require('module');
const lock=JSON.parse(fs.readFileSync('package-lock.json','utf8'));
function dirs(name){const suffix='node_modules/'+name;return Object.keys(lock.packages||{}).filter(p=>p===suffix||p.endsWith('/'+suffix)).sort((a,b)=>a.length-b.length||a.localeCompare(b));}
function at(rel){const p=path.join(process.cwd(),rel,'package.json');return {path:p,json:JSON.parse(fs.readFileSync(p,'utf8'))};}
function fromEntry(entry,name){let d=path.dirname(entry);while(true){const p=path.join(d,'package.json');if(fs.existsSync(p)){try{const j=JSON.parse(fs.readFileSync(p,'utf8'));if(j.name===name)return {path:p,json:j};}catch{}}const u=path.dirname(d);if(u===d)break;d=u;}throw new Error('package root not found '+name);}
const packager=at(dirs('@electron/packager')[0]),core=at(dirs('@electron-forge/core')[0]),ext=at(dirs('external-editor')[0]);
const packagerReq=createRequire(packager.path),coreReq=createRequire(core.path),extReq=createRequire(ext.path);
const semver=packagerReq('semver');
const corePackagerEntry=coreReq.resolve('@electron/packager');
const corePackager=fromEntry(corePackagerEntry,'@electron/packager');
const tmpPkg=fromEntry(extReq.resolve('tmp'),'tmp');
let replacementExtractor=null;
if(packager.json.dependencies?.['@electron-internal/extract-zip']){
  const x=fromEntry(packagerReq.resolve('@electron-internal/extract-zip'),'@electron-internal/extract-zip');
  replacementExtractor={name:'@electron-internal/extract-zip',version:x.json.version,package_json:x.path,
    dependency_path:'@electron/packager@'+packager.json.version+' -> @electron-internal/extract-zip@'+x.json.version};
}
const engine=packager.json.engines?.node||null;
const out={host_node:process.version,packager_engine:{requirement:engine,satisfied:Boolean(engine&&semver.satisfies(process.version,engine))},
  installed_packager:{version:packager.json.version,package_json:packager.path,direct_dependencies:packager.json.dependencies||{}},
  forge_core:{version:core.json.version,package_json:core.path},
  forge_packager:{version:corePackager.json.version,package_json:corePackager.path,resolved_entry:corePackagerEntry},
  external_editor:{version:ext.json.version,package_json:ext.path},
  external_editor_tmp:{version:tmpPkg.json.version,package_json:tmpPkg.path,dependency_path:'external-editor@'+ext.json.version+' -> tmp@'+tmpPkg.json.version},
  replacement_extractor:replacementExtractor};
fs.writeFileSync(process.argv[2],JSON.stringify(out,null,2)+'\n');
NODE

set +e
"$NPM" audit --json > "$RESULTS/npm-audit.json"
AUDIT_RC=$?
set -e
node - "$RESULTS/npm-audit-status.json" "$AUDIT_RC" <<'NODE'
const fs=require('fs');
fs.writeFileSync(process.argv[2],JSON.stringify({exit_code:Number(process.argv[3])},null,2)+'\n');
NODE

# Execution-time registry metadata for every exact tar version in the fresh lock.
node - "$RESULTS/tar-versions.txt" <<'NODE'
const fs=require('fs');
const lock=JSON.parse(fs.readFileSync('package-lock.json','utf8'));
const v=[...new Set(Object.entries(lock.packages||{})
  .filter(([p,m]) => p==='node_modules/tar' || p.endsWith('/node_modules/tar'))
  .map(([p,m]) => m.version))].sort();
fs.writeFileSync(process.argv[2],v.join('\n')+(v.length?'\n':''));
NODE

node - "$RESULTS/tar-versions.txt" "$RESULTS/tar-registry-metadata.json" "$NPM" <<'NODE'
const fs=require('fs'), cp=require('child_process');
const [listPath,outPath,npm]=process.argv.slice(2);
const versions=fs.readFileSync(listPath,'utf8').split(/\r?\n/).filter(Boolean);
const out={};
for(const v of versions){
  const r=cp.spawnSync(npm,['view',`tar@${v}`,'version','deprecated','dist.integrity','dist.tarball','--json'],{encoding:'utf8'});
  if(r.status!==0) {
    out[v]={error:r.stderr||r.stdout||`npm view exit ${r.status}`};
    continue;
  }
  let x; try{x=JSON.parse(r.stdout)}catch{x={raw:r.stdout.trim()}}
  out[v]=x;
}
fs.writeFileSync(outPath,JSON.stringify(out,null,2)+'\n');
NODE

SECURITY_RC=0
node "$ROOT/security-repair/analyze-security.cjs" "$RESULTS" || SECURITY_RC=$?

finalize_artifact() {
  cp "$ROOT/.qualification/results/RUNNER_PREFLIGHT.json" "$RESULTS/RUNNER_PREFLIGHT.json" 2>/dev/null || true
  python3 - "$RESULTS" <<'PY'
from pathlib import Path
import hashlib,json,sys,zipfile,os
root=Path(sys.argv[1])
members=[]
for p in sorted(root.rglob('*')):
    if p.is_file() and p.name != 'MANIFEST.json':
        b=p.read_bytes()
        members.append({'path':p.relative_to(root).as_posix(),'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()})
manifest={
  'schema':'ENGOS_PUBLIC_SYNTHETIC_TOOLCHAIN_SECURITY_REPAIR_RESULT_MANIFEST_R3_V1',
  'github_repository':os.environ.get('GITHUB_REPOSITORY'),
  'github_sha':os.environ.get('GITHUB_SHA'),
  'runner_name':os.environ.get('RUNNER_NAME'),
  'runner_os':os.environ.get('RUNNER_OS'),
  'runner_arch':os.environ.get('RUNNER_ARCH'),
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

if [[ "$SECURITY_RC" -ne 0 ]]; then
  node - "$RESULTS/final-status.json" <<'NODE'
const fs=require('fs');
fs.writeFileSync(process.argv[2],JSON.stringify({
  result:'HOLD_SECURITY_PREFLIGHT',
  q01_q03:'NOT_EXECUTED',
  q04_q10:'NOT_EXECUTED_OPTIONAL',
  baseline_adoption:false,
  formal_effect:false
},null,2)+'\n');
NODE
  finalize_artifact
  exit 0
fi

prepare_suid_sandbox() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  sudo chown root:root "$f"
  sudo chmod 4755 "$f"
  [[ "$(stat -c '%u:%g:%a' "$f")" == "0:0:4755" ]]
}

QUAL_STAGE="not_started"
run_q01_q03() {
  QUAL_STAGE="rebuild_resolution"
  local rebuild
  rebuild="$(node -p "require('@electron/rebuild/package.json').version")" || return 1
  [[ "$rebuild" == "4.2.0" ]] || return 1
  node -e "const c=require('$RESULTS/compatibility-preflight.json');if(c.forge_packager?.version!=='20.3.0'||c.packager_engine?.satisfied!==true||c.external_editor_tmp?.version!=='0.2.7')process.exit(1)" || return 1

  QUAL_STAGE="electron_rebuild_functional"
  set +e
  ./node_modules/.bin/electron-rebuild -f -w better-sqlite3 -v 44.4.4 > "$RESULTS/electron-rebuild-functional.log" 2>&1
  local rebuild_rc=$?
  set -e
  [[ "$rebuild_rc" -eq 0 ]] || return 1
  node - "$RESULTS/direct-rebuild-evidence.json" "$RESULTS/electron-rebuild-functional.log" <<'NODE'
const fs=require('fs'),path=require('path'),crypto=require('crypto');const [outPath,logPath]=process.argv.slice(2);
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
function walk(d,a=[]){for(const e of fs.readdirSync(d,{withFileTypes:true})){const p=path.join(d,e.name);if(e.isDirectory())walk(p,a);else if(e.isFile()&&e.name.endsWith('.node'))a.push(p);}return a;}
const root=path.join(process.cwd(),'node_modules','better-sqlite3');const native=walk(root).sort().map(p=>({path:path.relative(process.cwd(),p),sha256:sha(fs.readFileSync(p)),bytes:fs.statSync(p).size}));
if(!native.length)process.exit(42);fs.writeFileSync(outPath,JSON.stringify({result:'PASS',electron_rebuild:'4.2.0',target_electron:'44.4.4',native_files:native,log_sha256:sha(fs.readFileSync(logPath))},null,2)+'\n');
NODE

  prepare_suid_sandbox "node_modules/electron/dist/chrome-sandbox" || return 1
  QUAL_STAGE="forge_config_load"
  node -e "require('./forge.config.cjs')" || return 1
  ./node_modules/.bin/tsc -p tsconfig.json --noEmit || return 1

  QUAL_STAGE="forge_start"
  rm -rf .vite
  set +e
  QUAL_PHASE="security-repair-r3-dev" QUAL_RUNTIME_RECEIPT="$RESULTS/dev-runtime.json" timeout 120s xvfb-run -a ./node_modules/.bin/electron-forge start > "$RESULTS/forge-start.log" 2>&1
  local start_rc=$?
  set -e
  [[ "$start_rc" -eq 0 ]] || return 1
  node - "$RESULTS/dev-runtime.json" <<'NODE'
const fs=require('fs');const r=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));if(r.result!=='PASS'||r.native_binding_loaded!==true||r.renderer_ready!==true||r.sqlite_version!=='3.53.4')process.exit(1);
if(r.versions?.electron!=='44.4.4'||r.versions?.node!=='24.21.0'||r.versions?.chrome!=='152.0.7977.130')process.exit(1);
NODE

  QUAL_STAGE="forge_package"
  rm -rf out .vite
  set +e
  ./node_modules/.bin/electron-forge package > "$RESULTS/forge-package.log" 2>&1
  local forge_rc=$?
  set -e
  [[ "$forge_rc" -eq 0 ]] || return 1

  local appdir appbin asar asar_sha
  QUAL_STAGE="package_output"
  appdir="$(find out -mindepth 1 -maxdepth 1 -type d -name '*linux-x64' | head -n1)"
  [[ -n "$appdir" ]] || return 1
  appbin="$appdir/electron-sqlite-security-repair-qualification"
  [[ -x "$appbin" ]] || return 1
  prepare_suid_sandbox "$appdir/chrome-sandbox" || return 1

  QUAL_STAGE="native_include"
  asar="$appdir/resources/app.asar"
  [[ -f "$asar" ]] || return 1
  asar_sha="$(sha256sum "$asar" | awk '{print $1}')"
  local native_root="$appdir/resources/app.asar.unpacked/node_modules/better-sqlite3"
  [[ -d "$native_root" ]] || return 1
  local -a native_candidates=()
  mapfile -t native_candidates < <(find "$native_root" -type f -name '*.node' | sort)
  [[ "${#native_candidates[@]}" -gt 0 ]] || return 1
  printf '%s\n' "${native_candidates[@]#"$appdir/"}" > "$RESULTS/packaged-native-candidates.txt"

  QUAL_STAGE="packaged_launch"
  QUAL_PHASE="security-repair-r3-packaged" QUAL_RUNTIME_RECEIPT="$RESULTS/packaged-runtime.json" timeout 90s xvfb-run -a "$appbin" > "$RESULTS/packaged-launch.log" 2>&1 || return 1
  node - "$RESULTS/packaged-runtime.json" <<'NODE'
const fs=require('fs');const r=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));if(r.result!=='PASS'||r.native_binding_loaded!==true||r.renderer_ready!==true||r.sqlite_version!=='3.53.4')process.exit(1);
if(r.versions?.electron!=='44.4.4'||r.versions?.node!=='24.21.0'||r.versions?.chrome!=='152.0.7977.130')process.exit(1);
NODE

  QUAL_STAGE="missing_binding_negative"
  local native="" native_sha="" missing_rc=0 idx=0
  for cand in "${native_candidates[@]}"; do
    idx=$((idx+1))
    local cand_sha
    cand_sha="$(sha256sum "$cand" | awk '{print $1}')"
    mv "$cand" "$cand.missing"
    set +e
    QUAL_PHASE="security-repair-r3-missing-binding-$idx" QUAL_RUNTIME_RECEIPT="$RESULTS/missing-binding-runtime-$idx.json" timeout 60s xvfb-run -a "$appbin" > "$RESULTS/missing-binding-$idx.log" 2>&1
    local rc=$?
    set -e
    mv "$cand.missing" "$cand"
    if [[ "$rc" -ne 0 ]] && grep -Eqi 'better[_-]?sqlite|Could not locate the bindings|bindings file|\.node' "$RESULTS/missing-binding-$idx.log"; then
      native="$cand";native_sha="$cand_sha";missing_rc="$rc"
      cp "$RESULTS/missing-binding-$idx.log" "$RESULTS/missing-binding-active.log"
      [[ -f "$RESULTS/missing-binding-runtime-$idx.json" ]] && cp "$RESULTS/missing-binding-runtime-$idx.json" "$RESULTS/missing-binding-active-runtime.json" || true
      break
    fi
  done
  [[ -n "$native" && "$missing_rc" -ne 0 ]] || return 1
  node - "$RESULTS/active-native-negative.json" "$appdir" "$native" "$native_sha" "$missing_rc" "$RESULTS/missing-binding-active.log" <<'NODE'
const fs=require('fs'),path=require('path'),crypto=require('crypto');const [out,appdir,native,nativeSha,rc,log]=process.argv.slice(2);const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
fs.writeFileSync(out,JSON.stringify({result:'PASS',exact_active_native_relative_path:path.relative(appdir,native),exact_active_native_sha256:nativeSha,missing_binding_exit_code:Number(rc),
missing_binding_fails_closed:Number(rc)!==0,failure_log_sha256:sha(fs.readFileSync(log))},null,2)+'\n');
NODE

  local lock_sha graph_sha audit_sha advisory_sha package_log_sha
  lock_sha="$(node -p "require('$RESULTS/security-preflight.json').lock.raw_sha256")"
  graph_sha="$(node -p "require('$RESULTS/security-preflight.json').lock.normalized_graph_sha256")"
  audit_sha="$(node -p "require('$RESULTS/security-preflight.json').audit.raw_sha256")"
  advisory_sha="$(node -p "require('$RESULTS/security-preflight.json').audit.advisory_inventory_sha256")"
  package_log_sha="$(sha256sum "$RESULTS/forge-package.log" | awk '{print $1}')"

  local start_log_sha rebuild_log_sha
  start_log_sha="$(sha256sum "$RESULTS/forge-start.log" | awk '{print $1}')"
  rebuild_log_sha="$(sha256sum "$RESULTS/electron-rebuild-functional.log" | awk '{print $1}')"
  node - "$RESULTS/q01-q03.json" "$lock_sha" "$graph_sha" "$audit_sha" "$advisory_sha" "$asar_sha" "$package_log_sha" "$start_log_sha" "$rebuild_log_sha" <<'NODE'
const fs=require('fs'),path=require('path');const [p,lockSha,graphSha,auditSha,advSha,asarSha,packageLogSha,startLogSha,rebuildLogSha]=process.argv.slice(2);const dir=path.dirname(p);
const runtime=JSON.parse(fs.readFileSync(path.join(dir,'packaged-runtime.json'),'utf8')),dev=JSON.parse(fs.readFileSync(path.join(dir,'dev-runtime.json'),'utf8'));
const compat=JSON.parse(fs.readFileSync(path.join(dir,'compatibility-preflight.json'),'utf8')),direct=JSON.parse(fs.readFileSync(path.join(dir,'direct-rebuild-evidence.json'),'utf8'));
const neg=JSON.parse(fs.readFileSync(path.join(dir,'active-native-negative.json'),'utf8'));
const out={result:'PASS',
Q01_LOCK_INTEGRITY:{result:'PASS',lockfileVersion:3,lock_sha256:lockSha,normalized_graph_sha256:graphSha,npm:'11.19.0',sri_complete:true,electron_rebuild:'4.2.0',
electron_packager:'20.3.0',external_editor_tmp:'0.2.7',replacement_extractor:compat.replacement_extractor,npm_audit_json_sha256:auditSha,advisory_inventory_sha256:advSha,high:0,critical:0,npm_ls_clean:true},
Q02_PACKAGE_LAUNCH:{result:'PASS',forge:'7.11.2',forge_vite_plugin:'7.11.2',vite:'8.3.1',electron_packager:'20.3.0',packager_engine:compat.packager_engine,
forge_resolved_packager:compat.forge_packager,forge_config_load:true,forge_start:true,forge_start_log_sha256:startLogSha,vite_build_via_forge_start_and_package:true,forge_package:true,
forge_package_log_sha256:packageLogSha,packaged_launch:true,dev_runtime_versions:dev.versions,runtime_versions:runtime.versions,sqlite_version:runtime.sqlite_version},
Q03_NATIVE_BINDING:{result:'PASS',better_sqlite3:'13.0.3',native_rebuild_provider:'@electron/rebuild@4.2.0',direct_electron_rebuild_functional:true,direct_rebuild_log_sha256:rebuildLogSha,
direct_rebuild_evidence:direct,forge_native_dependency_preparation:true,packaged_native_relative_path:neg.exact_active_native_relative_path,packaged_native_sha256:neg.exact_active_native_sha256,
app_asar_sha256:asarSha,packaged_native_load:true,missing_binding_test_target:neg.exact_active_native_relative_path,missing_binding_exit_code:neg.missing_binding_exit_code,
missing_binding_fails_closed:neg.missing_binding_fails_closed}};
fs.writeFileSync(p,JSON.stringify(out,null,2)+'\n');
NODE
  QUAL_STAGE="pass"
  return 0
}

QUAL_RC=0
run_q01_q03 || QUAL_RC=$?

if [[ "$QUAL_RC" -eq 0 ]]; then
  node - "$RESULTS/final-status.json" <<'NODE'
const fs=require('fs'),path=require('path');
const dir=path.dirname(process.argv[2]);
const sec=JSON.parse(fs.readFileSync(path.join(dir,'security-preflight.json'),'utf8'));
const q=JSON.parse(fs.readFileSync(path.join(dir,'q01-q03.json'),'utf8'));
fs.writeFileSync(process.argv[2],JSON.stringify({
  result:'TOOLCHAIN_SECURITY_REPAIR_R3_PASS',
  security_preflight:sec.result,
  Q01:q.Q01_LOCK_INTEGRITY.result,
  Q02:q.Q02_PACKAGE_LAUNCH.result,
  Q03:q.Q03_NATIVE_BINDING.result,
  Q04_Q10:'NOT_EXECUTED_OPTIONAL__RUN9_SYNTHETIC_EVIDENCE_PRESERVED_WITH_EXISTING_SEMANTIC_CEILING',
  proposed_toolchain:{
    electron:'44.4.4',
    forge:'7.11.2',
    forge_vite_plugin:'7.11.2',
    vite:'8.3.1',
    typescript:'7.0.2',
    react:'19.3.0',
    react_dom:'19.3.0',
    better_sqlite3:'13.0.3',
    electron_rebuild:'4.2.0',
    electron_packager:'20.3.0',
    external_editor_tmp:'0.2.7',
    replacement_extractor:sec.compatibility.replacement_extractor,
    sqlite:'3.53.4',
    tar_versions:sec.npm_ls.tar_versions
  },
  lock_sha256:sec.lock.raw_sha256,
  graph_sha256:sec.lock.normalized_graph_sha256,
  npm_audit_json_sha256:sec.audit.raw_sha256,
  advisory_inventory_sha256:sec.audit.advisory_inventory_sha256,
  baseline_adoption:false,
  product_repository_write:false,
  bs01_build:false,
  qg_effect:false,
  formal_effect:false
},null,2)+'\n');
NODE
else
  node - "$RESULTS/final-status.json" "$QUAL_STAGE" <<'NODE'
const fs=require('fs');
fs.writeFileSync(process.argv[2],JSON.stringify({
  result:'HOLD_Q01_Q03_REQUALIFICATION',
  failure_stage:process.argv[3],
  baseline_adoption:false,
  product_repository_write:false,
  bs01_build:false,
  qg_effect:false,
  formal_effect:false
},null,2)+'\n');
NODE
fi

finalize_artifact
exit 0
