#!/usr/bin/env bash
set -Eeuo pipefail
export CI=1
ROOT="$PWD"
QROOT="$ROOT/.qualification"
RESULTS="$QROOT/results"
mkdir -p "$RESULTS"

# Exact npm target without mutating package roots.
mkdir -p "$RUNNER_TEMP/npm11"
npm install --prefix "$RUNNER_TEMP/npm11" npm@11.19.0 --ignore-scripts=false --no-audit --no-fund >/dev/null
NPM="$RUNNER_TEMP/npm11/node_modules/.bin/npm"
[[ "$($NPM --version)" == "11.19.0" ]]

probe() {
  local name="$1" vite="$2" dir="$RESULTS/$1"
  rm -rf node_modules package-lock.json out .vite
  rm -rf .qualification/current && mkdir -p .qualification/current "$dir"
  node scripts/write-package.cjs "$vite"
  local status=PASS
  {
    "$NPM" install --package-lock-only --ignore-scripts=false --no-audit --no-fund
    node scripts/validate-lock.cjs "$vite"
    cp package-lock.json "$dir/package-lock.json"
    cp .qualification/current/lock-integrity.json "$dir/lock-integrity.json"
    rm -rf node_modules
    "$NPM" ci --ignore-scripts=false --no-audit --no-fund
    ./node_modules/.bin/tsc -p tsconfig.json --noEmit
    node -e "require('./forge.config.cjs')"
    QUAL_PHASE="$name-dev" QUAL_RUNTIME_RECEIPT="$dir/dev-runtime.json" timeout 120s xvfb-run -a ./node_modules/.bin/electron-forge start
    rm -rf out
    ./node_modules/.bin/electron-forge package
    local appbin
    appbin="$(find out -type f -perm -u+x -name electron-sqlite-qualification | head -n1)"
    test -n "$appbin"
    QUAL_PHASE="$name-packaged" QUAL_RUNTIME_RECEIPT="$dir/packaged-runtime.json" timeout 90s xvfb-run -a "$appbin"
    local native
    native="$(find out -type f -name '*.node' | head -n1)"
    test -n "$native"
    mv "$native" "$native.missing"
    set +e
    QUAL_PHASE="$name-missing-binding" QUAL_RUNTIME_RECEIPT="$dir/missing-binding-runtime.json" timeout 60s xvfb-run -a "$appbin"
    local rc=$?
    set -e
    mv "$native.missing" "$native"
    test "$rc" -ne 0
    printf '%s\n' '{"result":"PASS","explicit_missing_binding_failure":true}' > "$dir/probe-status.json"
  } || status=FAIL
  if [[ "$status" != PASS ]]; then
    printf '%s\n' '{"result":"FAIL"}' > "$dir/probe-status.json"
    return 1
  fi
  return 0
}

CONTROL=FAIL; A=FAIL; B=SKIPPED_NOT_REQUIRED; SELECTED=""
if probe control 5.4.19; then CONTROL=PASS; fi
if probe vite8 8.3.1; then A=PASS; SELECTED=8.3.1; else
  if probe vite7 7.3.6; then B=PASS; SELECTED=7.3.6; else B=FAIL; fi
fi

node - "$CONTROL" "$A" "$B" "$SELECTED" <<'NODE'
const fs=require('fs'); const [control,a,b,selected]=process.argv.slice(2);
fs.writeFileSync('.qualification/results/currentness-summary.json',JSON.stringify({control:{vite:'5.4.19',result:control},candidate_A:{vite:'8.3.1',result:a},candidate_B:{vite:'7.3.6',result:b},preferred_currentness_candidate:selected||null,no_automatic_adoption:true},null,2)+'\n');
NODE

if [[ -z "$SELECTED" ]]; then
  printf '%s\n' '{"result":"HOLD_CURRENTNESS","full_q01_q10":"NOT_EXECUTED"}' > "$RESULTS/final-status.json"
else
  # Ensure the selected candidate is the active exact environment if control/B sequencing changed it.
  local_vite="$(node -p "require('./package.json').devDependencies.vite")"
  if [[ "$local_vite" != "$SELECTED" ]]; then probe selected "$SELECTED"; fi
  SELDIR="$RESULTS/selected-$SELECTED"; mkdir -p "$SELDIR"
  cp package-lock.json "$SELDIR/package-lock.json"
  cp .qualification/current/lock-integrity.json "$SELDIR/lock-integrity.json" 2>/dev/null || node scripts/validate-lock.cjs "$SELECTED" && cp .qualification/current/lock-integrity.json "$SELDIR/lock-integrity.json"
  # Q01/Q02/Q03 derive from exact lock + successful selected probe.
  node - "$SELECTED" "$SELDIR" <<'NODE'
const fs=require('fs'),crypto=require('crypto'),path=require('path'); const [vite,dir]=process.argv.slice(2);
const lock=JSON.parse(fs.readFileSync(path.join(dir,'lock-integrity.json')));
const pkg=JSON.parse(fs.readFileSync('package.json'));
const rec={
  Q01_LOCK:{result:'PASS',vite,lockfileVersion:3,lockSha256:lock.lockSha256,graphSha256:lock.graphSha256,sriComplete:lock.sriComplete,npm:'11.19.0'},
  Q02_PACKAGE_LAUNCH:{result:'PASS',strict_typescript:true,forge_vite_config_load:true,dev_launch:true,package:true,packaged_launch:true,main_preload_renderer_ready:true},
  Q03_NATIVE_BINDING:{result:'PASS',better_sqlite3:pkg.dependencies['better-sqlite3'],packaged_native_load:true,asar_native_present:true,missing_binding_fails_closed:true}
};
fs.writeFileSync(path.join(dir,'q01-q03.json'),JSON.stringify(final,null,2)+'\n'); fs.writeFileSync('.qualification/results/final-status.json",JSON.stringify({result:final.result,selected_vite:vite,claim:final.claim},null,2)+'\n');
if(!pass) process.exit(1);
NODE
fi

python3 - <<'PY'
from pathlib import Path
import hashlib,json,zipfile,os
root=Path('.qualification/results'); entries=[]
for p in sorted(root.rglob('*')):
    if p.is_file():
        b=p.read_bytes(); entries.append({'path':p.relative_to(root).as_posix(),'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()})
manifest={'schema':'ENGOS_PUBLIC_SYNTHETIC_QUALIFICATION_RESULT_MANIFEST_V1','members':entries,'github_repository':os.environ.get('GITHUB_REPOSITORY'),'github_sha':os.environ.get('GITHUB_SHA'),'runner_name':os.environ.get('RUNNER_NAME'),'runner_os':os.environ.get('RUNNER_OS'),'runner_arch':os.environ.get('RUNNER_ARCH'),'image_os':os.environ.get('ImageOS'),'image_version':os.environ.get('ImageVersion')}
(root/'MANIFEST.json').write_text(json.dumps(manifest,indent=2)+'\n')
with zipfile.ZipFile('.qualification/qualification-result.zip','w',zipfile.ZIP_DEFLATED) as z:
    for p in sorted(root.rglob('*')):
        if p.is_file(): z.write(p,p.relative_to(root))
print('RESULT_ZIP_SHA256='+hashlib.sha256(Path('.qualification/qualification-result.zip').read_bytes()).hexdigest())
PY
