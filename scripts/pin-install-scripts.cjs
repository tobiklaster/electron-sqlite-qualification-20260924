const fs = require('fs');
const lock = JSON.parse(fs.readFileSync('package-lock.json', 'utf8'));
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
const allowScripts = { 'better-sqlite3@13.0.3': true };
const esbuild = lock.packages?.['node_modules/esbuild']?.version;
if (esbuild) allowScripts[`esbuild@${esbuild}`] = true;
pkg.allowScripts = allowScripts;
fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
console.log(JSON.stringify({allowScripts, esbuildPresent:Boolean(esbuild)}));
