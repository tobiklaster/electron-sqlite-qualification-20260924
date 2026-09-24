#!/usr/bin/env bash
set -Eeuo pipefail
export CI=1
ROOT="$PWD"
QROOT="$ROOT/.qualification"
RESULTS="$QROOT/results"
mkdir -p "$RESULTS"

NPM_PREFIX="$RUNNER_TEMP/npm11"
rm -rf "$NPM_PREFIX"
mkdir -p "$NPM_PREFIX"
(
  cd "$RUNNER_TEMP"
  command npm install --prefix "$NPM_PREFIX" npm@11.19.0 --ignore-scripts=false --no-audit --no-fund >/dev/null
)
export PATH="$NPM_PREFIX/node_modules/.bin:$PATH"
NPM="$(command -v npm)"
[[ "$("$NPM" --version)" == "11.19.0" ]]

prepare_suid_sandbox() {
  local f="$1"
  [[ -f "$f" ]] || { echo "missing chrome-sandbox: $f" >&2; return 1; }
  sudo chown root:root "$f"
  sudo chmod 4755 "$f"
  [[ "$(stat -c '%u:%g:%a' "$f")" == "0:0:4755" ]]
}

prepare_lock() {
  local vite="$1" dir="$2"
  "$NPM" install --package-lock-only --ignore-scripts=false --no-audit --no-fund
  node scripts/pin-install-scripts.cjs
  "$NPM" install --package-lock-only --ignore-scripts=false --no-audit --no-fund
  node scripts/validate-lock.cjs "$vite"
  cp package-lock.json "$dir/package-lock.json"
  cp .qualification/current/lock-integrity.json "$dir/lock-integrity.json"
}

probe_inner() {
  local name="$1" vite="$2" dir="$3"
  rm -rf node_modules package-lock.json out .vite
  rm -rf .qualification/current
  mkdir -p .qualification/current "$dir"
  node scripts/write-package.cjs "$vite" || return 1
  prepare_lock "$vite" "$dir" || return 1
  rm -rf node_modules
  "$NPM" ci --ignore-scripts=false --no-audit --no-fund || return 1
  [[ "$("$NPM" --version)" == "11.19.0" ]] || return 1
  ./node_modules/.bin/install-electron --no || return 1
  [[ -x "node_modules/electron/dist/electron" ]] || return 1
  [[ -f "node_modules/electron/dist/chrome-sandbox" ]] || return 1
  ./node_modules/.bin/tsc -p tsconfig.json --noEmit || return 1
  node -e "require('./forge.config.cjs')" || return 1

  prepare_suid_sandbox "node_modules/electron/dist/chrome-sandbox" || return 1
  QUAL_PHASE="$name-dev" QUAL_RUNTIME_RECEIPT="$dir/dev-runtime.json" timeout 120s xvfb-run -a ./node_modules/.bin/electron-forge start || return 1
  node -e "const fs=require('fs'); const r=JSON.parse(fs.readFileSync(process.argv[1],'utf8')); if(r.result!=='PASS'||!r.native_binding_loaded||!r.renderer_ready) process.exit(1)" "$dir/dev-runtime.json" || return 1

  rm -rf out
  ./node_modules/.bin/electron-forge package || return 1
  local appdir appbin packaged_sandbox native native_sha rc
  appdir="$(find out -mindepth 1 -maxdepth 1 -type d -name '*linux-x64' | head -n1)"
  [[ -n "$appdir" ]] || return 1
  appbin="$appdir/electron-sqlite-qualification"
  [[ -x "$appbin" ]] || return 1
  packaged_sandbox="$appdir/chrome-sandbox"
  prepare_suid_sandbox "$packaged_sandbox" || return 1

  native="$(find "$appdir" -type f -name '*.node' | head -n1)"
  [[ -n "$native" && -f "$native" ]] || return 1
  native_sha="$(sha256sum "$native" | awk '{print $1}')"

  QUAL_PHASE="$name-packaged" QUAL_RUNTIME_RECEIPT="$dir/packaged-runtime.json" timeout 90s xvfb-run -a "$appbin" || return 1
  node -e "const fs=require('fs'); const r=JSON.parse(fs.readFileSync(process.argv[1],'utf8')); if(r.result!=='PASS'||!r.native_binding_loaded||!r.renderer_ready||!r.sqlite_version) process.exit(1)" "$dir/packaged-runtime.json" || return 1

  mv "$native" "$native.missing"
  set +e
  QUAL_PHASE="$name-missing-binding" QUAL_RUNTIME_RECEIPT="$dir/missing-binding-runtime.json" timeout 60s xvfb-run -a "$appbin"
  rc=$?
  set -e
  mv "$native.missing" "$native"
  [[ "$rc" -ne 0 ]] || return 1

  node - "$dir" "$native" "$native_sha" <<'NODE'
const fs=require('fs'); const path=require('path');
const [dir,native,nativeSha]=process.argv.slice(2);
fs.writeFileSync(path.join(dir,'probe-details.json'),JSON.stringify({
  result:'PASS', packaged_native_path:native, packaged_native_sha256:nativeSha,
  missing_binding_fails_closed:true, sandbox_mode:'root:root:4755'
},null,2)+'\n');
fs.writeFileSync(path.join(dir,'probe-status.json'),JSON.stringify({result:'PASS',explicit_missing_binding_failure:true},null,2)+'\n');
NODE
  return 0
}

probe() {
  local name="$1" vite="$2" dir="$RESULTS/$1"
  if probe_inner "$name" "$vite" "$dir"; then return 0; fi
  mkdir -p "$dir"
  printf '%s\n' '{"result":"FAIL"}' > "$dir/probe-status.json"
  return 1
}

CONTROL=FAIL
A=FAIL
B=SKIPPED_NOT_REQUIRED
SELECTED=""
if probe control 5.4.19; then CONTROL=PASS; fi
if probe vite8 8.3.1; then
  A=PASS
  SELECTED=8.3.1
else
  if probe vite7 7.3.6; then B=PASS; SELECTED=7.3.6; else B=FAIL; fi
fi

node - "$CONTROL" "$A" "$B" "$SELECTED" <<'NODE'
const fs=require('fs');
const [control,a,b,selected]=process.argv.slice(2);
fs.writeFileSync('.qualification/results/currentness-summary.json',JSON.stringify({
  control:{vite:'5.4.19',result:control}, candidate_A:{vite:'8.3.1',result:a},
  candidate_B:{vite:'7.3.6',result:b}, preferred_currentness_candidate:selected||null,
  no_automatic_adoption:true
},null,2)+'\n');
NODE

if [[ -z "$SELECTED" ]]; then
  printf '%s\n' '{"result":"HOLD_CURRENTNESS","full_q01_q10":"NOT_EXECUTED","no_automatic_adoption":true}' > "$RESULTS/final-status.json"
else
  local_vite="$(node -p "require('./package.json').devDependencies.vite")"
  if [[ "$local_vite" != "$SELECTED" ]]; then probe selected "$SELECTED"; fi
  if [[ "$SELECTED" == "8.3.1" ]]; then SOURCE_DIR="$RESULTS/vite8";
  elif [[ "$SELECTED" == "7.3.6" ]]; then SOURCE_DIR="$RESULTS/vite7";
  else SOURCE_DIR="$RESULTS/selected"; fi
  SELDIR="$RESULTS/selected-$SELECTED"
  rm -rf "$SELDIR"
  mkdir -p "$SELDIR"
  cp "$SOURCE_DIR/package-lock.json" "$SELDIR/package-lock.json"
  cp "$SOURCE_DIR/lock-integrity.json" "$SELDIR/lock-integrity.json"
  cp "$SOURCE_DIR/dev-runtime.json" "$SELDIR/dev-runtime.json"
  cp "$SOURCE_DIR/packaged-runtime.json" "$SELDIR/packaged-runtime.json"
  cp "$SOURCE_DIR/probe-details.json" "$SELDIR/probe-details.json"

  node scripts/write-q01-q03.cjs "$SELECTED" "$SELDIR"
  QUAL_FULL_OUT="$SELDIR" timeout 180s xvfb-run -a ./node_modules/.bin/electron scripts/full-qualification.cjs

  TESTSET_SHA="$(python3 - <<'PY'
from pathlib import Path
import hashlib
files=['PUBLICATION_SCOPE.json','forge.config.cjs','tsconfig.json','types.d.ts','vite.main.config.mjs','vite.preload.config.mjs','vite.renderer.config.mjs','src/main.ts','src/preload.ts','src/renderer.ts','scripts/write-package.cjs','scripts/pin-install-scripts.cjs','scripts/validate-lock.cjs','scripts/preflight.sh','scripts/qualify.sh','scripts/write-q01-q03.cjs','scripts/full-qualification.cjs','scripts/fault-child.cjs','scripts/finalize-results.cjs']
h=hashlib.sha256()
for name in files:
    b=Path(name).read_bytes(); h.update(name.encode()+b'\0'+b+b'\0')
print(h.hexdigest())
PY
)"
  node scripts/finalize-results.cjs "$SELECTED" "$SELDIR" "$TESTSET_SHA"
fi

python3 - <<'PY'
from pathlib import Path
import hashlib,json,zipfile,os
root=Path('.qualification/results'); entries=[]
for p in sorted(root.rglob('*')):
    if p.is_file():
        b=p.read_bytes(); entries.append({'path':p.relative_to(root).as_posix(),'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()})
manifest={'schema':'ENGOS_PUBLIC_SYNTHETIC_QUALIFICATION_RESULT_MANIFEST_V2','members':entries,'github_repository':os.environ.get('GITHUB_REPOSITORY'),'github_sha':os.environ.get('GITHUB_SHA'),'runner_name':os.environ.get('RUNNER_NAME'),'runner_os':os.environ.get('RUNNER_OS'),'runner_arch':os.environ.get('RUNNER_ARCH'),'image_os':os.environ.get('ImageOS'),'image_version':os.environ.get('ImageVersion'),'formal_effect_created':False}
(root/'MANIFEST.json').write_text(json.dumps(manifest,indent=2)+'\n')
with zipfile.ZipFile('.qualification/qualification-result.zip','w',zipfile.ZIP_DEFLATED) as z:
    for p in sorted(root.rglob('*')):
        if p.is_file(): z.write(p,p.relative_to(root))
print('RESULT_ZIP_SHA256='+hashlib.sha256(Path('.qualification/qualification-result.zip').read_bytes()).hexdigest())
PY
