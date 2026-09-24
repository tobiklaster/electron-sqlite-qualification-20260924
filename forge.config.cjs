const { VitePlugin } = require('@electron-forge/plugin-vite');
module.exports = {
  packagerConfig: {
    asar: { unpackDir: 'node_modules/better-sqlite3' }
  },
  rebuildConfig: {},
  plugins: [
    new VitePlugin({
      build: [
        { entry: 'src/main.ts', config: 'vite.main.config.mjs', target: 'main' },
        { entry: 'src/preload.ts', config: 'vite.preload.config.mjs', target: 'preload' }
      ],
      renderer: [
        { name: 'main_window', config: 'vite.renderer.config.mjs' }
      ]
    })
  ]
};
