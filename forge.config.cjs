const { VitePlugin } = require('@electron-forge/plugin-vite');
module.exports = {
  packagerConfig: {
    // Forge/Vite package staging must preserve runtime node_modules before ASAR.
    // Make Electron Packager's documented native-node unpack glob explicit.
    asar: { unpack: '**/{.**,**}/**/*.node' },
    prune: true,
    ignore: (file) => {
      if (!file) return false;
      const keep =
        file === '/package.json' ||
        file.startsWith('/.vite') ||
        file.startsWith('/node_modules');
      return !keep;
    }
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
