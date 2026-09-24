const fs = require('fs');
const lock = JSON.parse(fs.readFileSync('package-lock.json', 'utf8'));
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
const esbuild = lock.packages?.['node_modules/esbuild']?.version;
if (!esbuild) throw new Error('resolved esbuild version missing');
pkg.allowScripts = {
  'better-sqlite3@13.0.3': true,
  [`esbuild@${esbuild}`]: true
};
fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
console.log(JSON.stringify({allowScripts: pkg.allowScripts}));
