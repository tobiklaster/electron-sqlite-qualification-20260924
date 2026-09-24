const fs = require('fs');
const vite = process.argv[2];
if (!vite) throw new Error('vite version required');
const pkg = {
  name: 'electron-sqlite-qualification',
  version: '0.0.0-qualification',
  private: true,
  main: '.vite/build/main.js',
  scripts: {},
  dependencies: {
    react: '19.3.0',
    'react-dom': '19.3.0',
    'better-sqlite3': '13.0.3'
  },
  devDependencies: {
    electron: '44.4.4',
    '@electron-forge/cli': '7.11.2',
    '@electron-forge/plugin-vite': '7.11.2',
    vite,
    typescript: '7.0.2',
    '@playwright/test': '1.63.0'
  }
};
fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
