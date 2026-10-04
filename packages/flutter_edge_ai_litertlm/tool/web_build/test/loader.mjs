// Resolves the bundle's third-party imports to the stubs next to this file, so
// the real litert_embeddings_api.js runs under node without a browser.
const stubs = {
  '@litertjs/core': './stubs/litertjs_core.js',
  '@sctg/sentencepiece-js': './stubs/sentencepiece.js',
  '@tensorflow/tfjs-core': './stubs/tfjs_core.js',
  '@tensorflow/tfjs-backend-webgl': './stubs/empty.js',
};

export async function resolve(specifier, context, next) {
  const stub = stubs[specifier];
  if (stub) return { url: new URL(stub, import.meta.url).href, shortCircuit: true };
  return next(specifier, context);
}
