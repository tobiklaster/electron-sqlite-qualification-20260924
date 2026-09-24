const fs = require('fs');
const path = require('path');
const [selected, dir, testsetSha] = process.argv.slice(2);
if (!selected || !dir || !testsetSha) throw new Error('selected, dir, testsetSha required');
const q13 = JSON.parse(fs.readFileSync(path.join(dir, 'q01-q03.json'), 'utf8'));
const q410 = JSON.parse(fs.readFileSync(path.join(dir, 'q04-q10.json'), 'utf8'));
const all = {...q13, ...q410.q};
const ids = ['Q01_LOCK','Q02_PACKAGE_LAUNCH','Q03_NATIVE_BINDING','Q04_SQLITE_CORE','Q05_MIGRATION','Q06_BACKUP_RESTORE','Q07_FAULT_RECONCILIATION','Q08_PRIVACY_SECRET','Q09_UNKNOWN_NEWER','Q10_WORKER_BOUNDARY'];
const pass = ids.every(id => all[id]?.result === 'PASS');
const final = {
  result: pass ? 'PASS' : 'FAIL',
  selected_vite: selected,
  claim: pass ? 'ACTIVE_DEVELOPMENT_CONFIGURATION = UBUNTU_24_04_X64_EXT4__QUALIFIED' : null,
  q01_q10: Object.fromEntries(ids.map(id => [id, all[id]?.result ?? 'MISSING'])),
  testset_sha256: testsetSha,
  no_cross_platform_extrapolation: true,
  no_vite_adoption: true,
  build_authority: false,
  formal_effect_created: false
};
fs.writeFileSync('.qualification/results/final-status.json', JSON.stringify(final, null, 2) + '\n');
if (!pass) process.exit(1);
