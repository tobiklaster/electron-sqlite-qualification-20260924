const { VitePlugin } = require('@electron-forge/plugin-vite');
module.exports = {
  packagerConfig: {
    asar: { unpack: '**/*.node' }
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
