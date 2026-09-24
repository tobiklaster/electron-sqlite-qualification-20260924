const fs = require('fs');
const crypto = require('crypto');
const lock = JSON.parse(fs.readFileSync('package-lock.json', 'utf8'));
if (lock.lockfileVersion !== 3) throw new Error(`lockfileVersion=${lock.lockfileVersion}`);
const root = lock.packages?.[''];
if (!root) throw new Error('missing root package');
const expected = {
  dependencies: { react:'19.3.0','react-dom':'19.3.0','better-sqlite3':'13.0.3' },
  devDependencies: { electron:'44.4.4','@electron-forge/cli':'7.11.2','@electron-forge/plugin-vite':'7.11.2',vite:process.argv[2],typescript:'7.0.2','@playwright/test':'1.63.0' }
};
for (const [group, deps] of Object.entries(expected)) {
  for (const [name, version] of Object.entries(deps)) {
    if (root[group]?.[name] !== version) throw new Error(`root ${group}.${name} != ${version}`);
  }
}
const graph = [];
const missing = [];
for (const [path, meta] of Object.entries(lock.packages || {})) {
  if (!path || meta.link) continue;
  const rec = { path, version: meta.version || null, resolved: meta.resolved || null, integrity: meta.integrity || null };
  graph.push(rec);
  if (path.startsWith('node_modules/') && meta.version && (!meta.resolved || !meta.integrity)) missing.push(path);
}
if (missing.length) throw new Error(`missing resolved/integrity: ${missing.slice(0,20).join(',')}`);
graph.sort((a,b)=>a.path.localeCompare(b.path));
const graphJson = JSON.stringify(graph);
const out = {
  lockfileVersion: lock.lockfileVersion,
  packageCount: graph.length,
  sriComplete: true,
  lockSha256: crypto.createHash('sha256').update(fs.readFileSync('package-lock.json')).digest('hex'),
  graphSha256: crypto.createHash('sha256').update(graphJson).digest('hex')
};
fs.mkdirSync('.qualification/current', { recursive:true });
fs.writeFileSync('.qualification/current/lock-integrity.json', JSON.stringify(out,null,2)+'\n');
console.log(JSON.stringify(out));
