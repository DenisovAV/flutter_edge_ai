import { resolve } from 'path';
import { defineConfig } from 'vite';

// Builds the four files this package's `web/` ships. They are one
// bundle in four pieces — the entry plus three vendor chunks — so they must be
// copied out of the SAME build: a mismatched pair is how a 0.2.x wrapper ended
// up calling a 2.x WASM runtime and failing with `loadAndCompileWebGpu is not
// defined`.
export default defineConfig({
  build: {
    target: 'esnext',
    outDir: resolve(__dirname, '../../web'),
    emptyOutDir: false, // web/ is the package's, not this build's
    lib: {
      entry: { litert_embeddings: resolve(__dirname, 'litert_embeddings_api.js') },
      formats: ['es'],
    },
    rollupOptions: {
      output: {
        entryFileNames: '[name].js',
        chunkFileNames: '[name].js',
        manualChunks: {
          tensorflow: ['@tensorflow/tfjs-core', '@tensorflow/tfjs-backend-webgl'],
          litert: ['@litertjs/core'],
          sentencepiece: ['@sctg/sentencepiece-js'],
        },
      },
    },
  },
});
