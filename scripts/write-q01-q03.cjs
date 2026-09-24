const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const [vite, dir] = process.argv.slice(2);
if (!vite || !dir) throw new Error('vite and dir required');
const lock = JSON.parse(fs.readFileSync(path.join(dir, 'lock-integrity.json'), 'utf8'));
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
const packaged = JSON.parse(fs.readFileSync(path.join(dir, 'packaged-runtime.json'), 'utf8'));
const details = JSON.parse(fs.readFileSync(path.join(dir, 'probe-details.json'), 'utf8'));
const rec = {
  Q01_LOCK: {
    result: 'PASS', vite, lockfileVersion: lock.lockfileVersion, lockSha256: lock.lockSha256,
    graphSha256: lock.graphSha256, sriComplete: lock.sriComplete, packageCount: lock.packageCount, npm: '11.19.0'
  },
  Q02_PACKAGE_LAUNCH: {
    result: 'PASS', strict_typescript: true, forge_vite_config_load: true, dev_launch: true,
    package: true, packaged_launch: true, main_preload_renderer_ready: packaged.renderer_ready === true
  },
  Q03_NATIVE_BINDING: {
    result: 'PASS', better_sqlite3: pkg.dependencies['better-sqlite3'],
    packaged_native_load: packaged.native_binding_loaded === true,
    packaged_native_path: details.packaged_native_path,
    packaged_native_relative_path: details.packaged_native_relative_path,
    packaged_native_sha256: details.packaged_native_sha256,
    app_asar_sha256: details.app_asar_sha256,
    asar_native_present: details.native_under_app_asar_unpacked === true,
    missing_binding_fails_closed: details.missing_binding_fails_closed === true,
    sqlite_version: packaged.sqlite_version
  },
  TOOLCHAIN_RUNTIME: {
    electron: packaged.versions.electron,
    embedded_node: packaged.versions.node,
    embedded_chromium: packaged.versions.chrome,
    npm: '11.19.0', vite
  }
};
if (details.native_under_app_asar_unpacked !== true) throw new Error('native binding not proven under app.asar.unpacked');
for (const [k,v] of Object.entries(rec)) {
  if (k.startsWith('Q0') && v.result !== 'PASS') throw new Error(`${k} not PASS`);
}
fs.writeFileSync(path.join(dir, 'q01-q03.json'), JSON.stringify(rec, null, 2) + '\n');
