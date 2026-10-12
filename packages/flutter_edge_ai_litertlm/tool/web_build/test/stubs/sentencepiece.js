// Stands in for @sctg/sentencepiece-js. encodeIds is globalThis.__encodeIds
// when a test sets it, else it returns no ids.
export class SentencePieceProcessor {
  async loadFromBuffer() {}
  encodeIds(text) {
    return globalThis.__encodeIds ? globalThis.__encodeIds(text) : [];
  }
  decodeIds() { return ''; }
  delete() {}
}
