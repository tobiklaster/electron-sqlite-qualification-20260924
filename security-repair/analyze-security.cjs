const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const [resultsDir] = process.argv.slice(2);
if (!resultsDir) throw new Error('resultsDir required');

const sha = b => crypto.createHash('sha256').update(b).digest('hex');
const readJson = p => JSON.parse(fs.readFileSync(p, 'utf8'));

const lockBytes = fs.readFileSync('package-lock.json');
const lock = JSON.parse(lockBytes.toString('utf8'));
if (lock.lockfileVersion !== 3) throw new Error('lockfileVersion must be 3');

const root = lock.packages?.[''];
if (!root) throw new Error('lock root missing');

const expected = {
  dependencies: {
    react: '19.3.0',
    'react-dom': '19.3.0',
    'better-sqlite3': '13.0.3'
  },
  devDependencies: {
    electron: '44.4.4',
    '@electron-forge/cli': '7.11.2',
    '@electron-forge/plugin-vite': '7.11.2',
    vite: '8.3.1',
    typescript: '7.0.2'
  }
};
for (const [group, deps] of Object.entries(expected)) {
  for (const [name, version] of Object.entries(deps)) {
    if (root[group]?.[name] !== version) {
      throw new Error(`root ${group}.${name} != ${version}`);
    }
  }
}

const graph = [];
const sriMissing = [];
const rebuildEntries = [];
const tarEntries = [];
for (const [pkgPath, meta] of Object.entries(lock.packages || {})) {
  if (!pkgPath || meta.link) continue;
  const rec = {
    path: pkgPath,
    version: meta.version || null,
    resolved: meta.resolved || null,
    integrity: meta.integrity || null
  };
  graph.push(rec);
  if (pkgPath.endsWith('/node_modules/@electron/rebuild') || pkgPath === 'node_modules/@electron/rebuild') {
    rebuildEntries.push(rec);
  }
  if (pkgPath.endsWith('/node_modules/tar') || pkgPath === 'node_modules/tar') {
    tarEntries.push(rec);
  }
  if (typeof meta.resolved === 'string' && /^https:\/\/registry\.npmjs\.(org|com)\//.test(meta.resolved) && !meta.integrity) {
    sriMissing.push(pkgPath);
  }
}
graph.sort((a,b)=>a.path.localeCompare(b.path));
rebuildEntries.sort((a,b)=>a.path.localeCompare(b.path));
tarEntries.sort((a,b)=>a.path.localeCompare(b.path));
const graphBytes = Buffer.from(JSON.stringify(graph));

const npmLs = readJson(path.join(resultsDir, 'npm-ls.json'));
const npmLsStatus = readJson(path.join(resultsDir, 'npm-ls-status.json'));
const audit = readJson(path.join(resultsDir, 'npm-audit.json'));
const host = readJson(path.join(resultsDir, 'host-identity.json'));
const tarRegistry = readJson(path.join(resultsDir, 'tar-registry-metadata.json'));

const vulnerabilities = audit.vulnerabilities || {};
const advisoryInventory = Object.entries(vulnerabilities).map(([name,v]) => ({
  name,
  severity: v.severity || null,
  isDirect: Boolean(v.isDirect),
  via: Array.isArray(v.via) ? v.via.map(x => typeof x === 'string' ? x : {
    source: x.source ?? null,
    name: x.name ?? null,
    dependency: x.dependency ?? null,
    title: x.title ?? null,
    url: x.url ?? null,
    severity: x.severity ?? null,
    range: x.range ?? null
  }) : [],
  effects: v.effects || [],
  range: v.range || null,
  nodes: v.nodes || [],
  fixAvailable: v.fixAvailable ?? null
})).sort((a,b)=>a.name.localeCompare(b.name));

const highCritical = advisoryInventory.filter(v => ['high','critical'].includes(String(v.severity).toLowerCase()));
const tarAdvisories = advisoryInventory.filter(v => v.name === 'tar' || v.via.some(x => typeof x === 'object' && (x.name === 'tar' || x.dependency === 'tar')));
const rebuildVersions = [...new Set(rebuildEntries.map(x => x.version))].sort();
const tarVersions = [...new Set(tarEntries.map(x => x.version))].sort();

const checks = {
  lockfile_v3: lock.lockfileVersion === 3,
  rebuild_present: rebuildEntries.length > 0,
  rebuild_exact_4_2_0: rebuildEntries.length > 0 && rebuildEntries.every(x => x.version === '4.2.0'),
  npm_ls_clean: npmLsStatus.exit_code === 0 && (!npmLs.problems || npmLs.problems.length === 0),
  tar_6_2_1_absent: !tarVersions.includes('6.2.1'),
  no_high_or_critical: highCritical.length === 0,
  no_tar_advisory: tarAdvisories.length === 0,
  sri_complete_for_registry_packages: sriMissing.length === 0,
  tar_registry_metadata_complete: tarVersions.every(v => tarRegistry[v]?.version === v)
};

const result = Object.values(checks).every(Boolean) ? 'PASS' : 'HOLD';
const inventoryBytes = Buffer.from(JSON.stringify(advisoryInventory));
const out = {
  schema: 'ENGOS_PUBLIC_SYNTHETIC_TOOLCHAIN_SECURITY_PREFLIGHT_V1',
  result,
  checks,
  host,
  root_toolchain: expected,
  forced_override: {'@electron/rebuild':'4.2.0'},
  lock: {
    lockfileVersion: lock.lockfileVersion,
    packageCount: graph.length,
    raw_sha256: sha(lockBytes),
    normalized_graph_sha256: sha(graphBytes),
    sri_complete: sriMissing.length === 0,
    sri_missing_paths: sriMissing
  },
  npm_ls: {
    exit_code: npmLsStatus.exit_code,
    problems: npmLs.problems || [],
    rebuild_versions: rebuildVersions,
    rebuild_entries: rebuildEntries,
    tar_versions: tarVersions,
    tar_entries: tarEntries
  },
  audit: {
    raw_sha256: sha(fs.readFileSync(path.join(resultsDir, 'npm-audit.json'))),
    metadata: audit.metadata || null,
    advisory_inventory_sha256: sha(inventoryBytes),
    advisory_inventory: advisoryInventory,
    high_or_critical: highCritical,
    tar_advisories: tarAdvisories
  },
  tar_registry_metadata: tarRegistry,
  semantic_ceiling: 'QUALIFICATION_EVIDENCE_ONLY__NO_BASELINE_ADOPTION'
};

fs.writeFileSync(path.join(resultsDir, 'security-preflight.json'), JSON.stringify(out, null, 2) + '\n');
fs.writeFileSync(path.join(resultsDir, 'normalized-dependency-graph.json'), JSON.stringify(graph, null, 2) + '\n');
fs.writeFileSync(path.join(resultsDir, 'normalized-advisory-inventory.json'), JSON.stringify(advisoryInventory, null, 2) + '\n');
console.log(JSON.stringify({
  result,
  rebuildVersions,
  tarVersions,
  lockSha256: out.lock.raw_sha256,
  graphSha256: out.lock.normalized_graph_sha256,
  auditSha256: out.audit.raw_sha256,
  advisoryInventorySha256: out.audit.advisory_inventory_sha256,
  highCritical: highCritical.length,
  tarAdvisories: tarAdvisories.length,
  sriMissing: sriMissing.length
}));
process.exit(result === 'PASS' ? 0 : 42);
