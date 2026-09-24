#!/usr/bin/env bash
set -Eeuo pipefail
mkdir -p .qualification/results
. /etc/os-release
ARCH="$(uname -m)"
ROOT_FS="$(findmnt -n -o FSTYPE -T /)"
WORK_FS="$(findmnt -n -o FSTYPE -T "$GITHUB_WORKSPACE")"
TEMP_FS="$(findmnt -n -o FSTYPE -T "$RUNNER_TEMP")"
RUNNER_VER="${ImageVersion:-unknown}"
python3 - <<PY
import json,os,platform
out={
 'result':'PASS',
 'os_pretty_name':${PRETTY_NAME@Q},
 'os_version_id':${VERSION_ID@Q},
 'kernel':platform.release(),
 'architecture':${ARCH@Q},
 'root_filesystem':${ROOT_FS@Q},
 'workspace_filesystem':${WORK_FS@Q},
 'runner_temp_filesystem':${TEMP_FS@Q},
 'runner_label':'ubuntu-24.04',
 'ImageOS':os.environ.get('ImageOS'),
 'ImageVersion':os.environ.get('ImageVersion'),
 'RUNNER_NAME':os.environ.get('RUNNER_NAME'),
 'RUNNER_OS':os.environ.get('RUNNER_OS'),
 'RUNNER_ARCH':os.environ.get('RUNNER_ARCH')
}
if not (out['os_version_id'].startswith('24.04') and out['architecture']=='x86_64' and out['workspace_filesystem']=='ext4'):
 out['result']='HOLD_NOT_EQUIVALENT'
open('.qualification/results/RUNNER_PREFLIGHT.json','w').write(json.dumps(out,indent=2)+'\n')
if out['result']!='PASS': raise SystemExit(42)
PY
