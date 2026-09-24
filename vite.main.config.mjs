import { defineConfig } from 'vite';
export default defineConfig({
  build: {
    sourcemap: false,
    // Native Node modules must remain runtime dependencies; bundling them breaks
    // better-sqlite3's native binding resolution in both dev and packaged Electron.
    rollupOptions: { external: ['better-sqlite3'] }
  }
});
