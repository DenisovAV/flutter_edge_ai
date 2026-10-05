/**
 * OPFS (Origin Private File System) Helper for Flutter Gemma
 *
 * Provides OPFS-based storage for large model files (>2GB) to bypass
 * ArrayBuffer memory limitations in browsers.
 *
 * Key features:
 * - Download large files directly to OPFS with streaming
 * - Check if models are already cached
 * - Get ReadableStreamDefaultReader for MediaPipe streaming
 * - Storage quota management
 *
 * Browser support: Requires OPFS (Chrome 86+, Edge 86+, Safari 15.2+)
 */

window.flutterGemmaOPFS = {
  /**
   * Check if a model is already cached in OPFS
   * @param {string} filename - Model filename (used as cache key)
   * @returns {Promise<boolean>} True if model exists in OPFS
   */
  async isModelCached(filename) {
    try {
      const opfs = await navigator.storage.getDirectory();
      await opfs.getFileHandle(filename);
      return true;
    } catch (error) {
      // File doesn't exist or OPFS not supported
      return false;
    }
  },

  /**
   * Get the size of a cached model
   * @param {string} filename - Model filename
   * @returns {Promise<number|null>} File size in bytes, or null if not found
   */
  async getCachedModelSize(filename) {
    try {
      const opfs = await navigator.storage.getDirectory();
      const handle = await opfs.getFileHandle(filename);
      const file = await handle.getFile();
      return file.size;
    } catch (error) {
      return null;
    }
  },

  /**
   * Download a model file to OPFS with progress tracking and cancellation support
   *
   * @param {string} url - Model download URL
   * @param {string} filename - Filename to save in OPFS
   * @param {string|null} authToken - Optional authentication token (e.g., HuggingFace token)
   * @param {function(number): void} onProgress - Progress callback (0-100)
   * @param {AbortSignal|null} abortSignal - Optional AbortSignal for cancellation
   * @returns {Promise<boolean>} True on success
   * @throws {Error} On download failure, storage quota exceeded, or cancellation
   */
  async downloadToOPFS(url, filename, authToken, onProgress, abortSignal) {
    let writable = null;
    let reader = null;

    try {
      console.log(`[OPFS] Starting download: ${filename} from ${url}`);

      // Check storage quota before downloading
      const estimate = await navigator.storage.estimate();
      console.log(`[OPFS] Storage - Used: ${(estimate.usage / 1e9).toFixed(2)}GB, Quota: ${(estimate.quota / 1e9).toFixed(2)}GB`);

      // Prepare fetch options with abort signal
      const fetchOptions = {};
      if (authToken) {
        fetchOptions.headers = { 'Authorization': `Bearer ${authToken}` };
      }
      if (abortSignal) {
        fetchOptions.signal = abortSignal;
      }

      // Fetch with optional authentication and abort signal
      const response = await fetch(url, fetchOptions);
      if (!response.ok) {
        throw new Error(`HTTP ${response.status}: ${response.statusText}`);
      }

      const contentLength = parseInt(response.headers.get('content-length') || '0');
      console.log(`[OPFS] Content-Length: ${(contentLength / 1e9).toFixed(2)}GB`);

      // Check if we have enough space
      if (estimate.quota && contentLength > 0) {
        const availableSpace = estimate.quota - (estimate.usage || 0);
        if (contentLength > availableSpace) {
          throw new Error(
            `Insufficient storage: need ${(contentLength / 1e9).toFixed(2)}GB, ` +
            `available ${(availableSpace / 1e9).toFixed(2)}GB`
          );
        }
      }

      // Get OPFS directory and create file handle
      const opfs = await navigator.storage.getDirectory();
      const fileHandle = await opfs.getFileHandle(filename, { create: true });
      writable = await fileHandle.createWritable();

      // Stream download to OPFS
      reader = response.body.getReader();
      let bytesReceived = 0;
      let lastProgressPercent = 0;

      while (true) {
        // Check for abort before each read
        if (abortSignal?.aborted) {
          throw new DOMException('Download aborted', 'AbortError');
        }

        const { done, value } = await reader.read();
        if (done) break;

        // Write chunk to OPFS
        await writable.write(value);
        bytesReceived += value.length;

        // Report progress
        if (contentLength > 0) {
          const progressPercent = Math.round((bytesReceived / contentLength) * 100);
          if (progressPercent !== lastProgressPercent) {
            onProgress(progressPercent);
            lastProgressPercent = progressPercent;
          }
        }
      }

      // Finalize write
      await writable.close();
      writable = null;
      console.log(`[OPFS] Download complete: ${filename} (${(bytesReceived / 1e9).toFixed(2)}GB)`);
      return true;

    } catch (error) {
      // Cleanup on error
      if (reader) {
        try { await reader.cancel(); } catch (e) { /* ignore */ }
      }
      if (writable) {
        try { await writable.abort(); } catch (e) { /* ignore */ }
      }

      // Handle abort specifically
      if (error.name === 'AbortError') {
        console.log(`[OPFS] Download aborted: ${filename}`);
        // Remove partial file
        try {
          const opfs = await navigator.storage.getDirectory();
          await opfs.removeEntry(filename);
          console.log(`[OPFS] Cleaned up partial file: ${filename}`);
        } catch (e) { /* ignore - file may not exist */ }
      } else {
        console.error(`[OPFS] Download failed: ${error.message}`);
      }

      throw error;
    }
  },

  /**
   * Get a ReadableStreamDefaultReader for a cached model file
   *
   * This is used to pass the model to MediaPipe's modelAssetBuffer parameter,
   * enabling streaming without loading the entire model into memory.
   *
   * @param {string} filename - Model filename in OPFS
   * @returns {Promise<ReadableStreamDefaultReader>} Stream reader for the file
   * @throws {Error} If file not found in OPFS
   */
  async getStreamReader(filename) {
    try {
      const opfs = await navigator.storage.getDirectory();
      const handle = await opfs.getFileHandle(filename);
      const file = await handle.getFile();

      // Return the ReadableStream's reader
      // MediaPipe will consume this stream directly
      return file.stream().getReader();
    } catch (error) {
      console.error(`[OPFS] Failed to get stream reader: ${error.message}`);
      throw new Error(`Model not found in OPFS: ${filename}`);
    }
  },

  /**
   * Get a ReadableStream for streaming a cached model (NOT a reader).
   * Used by @litert-lm/core Engine.create({model: <ReadableStream>}) on web,
   * which wants the raw stream rather than the reader (per
   * https://ai.google.dev/edge/litert-lm/js).
   *
   * @param {string} filename - Model filename in OPFS
   * @returns {Promise<ReadableStream>} Raw ReadableStream for the file
   * @throws {Error} If file not found in OPFS
   */
  async getReadableStream(filename) {
    try {
      const opfs = await navigator.storage.getDirectory();
      const handle = await opfs.getFileHandle(filename);
      const file = await handle.getFile();
      return file.stream();
    } catch (error) {
      console.error(`[OPFS] Failed to get readable stream: ${error.message}`);
      throw new Error(`Model not found in OPFS: ${filename}`);
    }
  },

  /**
   * Delete a model from OPFS
   * @param {string} filename - Model filename to delete
   * @returns {Promise<void>}
   */
  async deleteModel(filename) {
    try {
      const opfs = await navigator.storage.getDirectory();
      await opfs.removeEntry(filename);
      console.log(`[OPFS] Deleted: ${filename}`);
    } catch (error) {
      console.error(`[OPFS] Failed to delete ${filename}: ${error.message}`);
      throw error;
    }
  },

  /**
   * Get current storage statistics
   * @returns {Promise<{usage: number, quota: number}>} Storage stats in bytes
   */
  async getStorageStats() {
    const estimate = await navigator.storage.estimate();
    return {
      usage: estimate.usage || 0,
      quota: estimate.quota || 0
    };
  },

  /**
   * Clear all models from OPFS (for development/testing)
   * @returns {Promise<number>} Number of files deleted
   */
  async clearAll() {
    try {
      const opfs = await navigator.storage.getDirectory();
      let count = 0;

      // Iterate through all entries
      for await (const [name, handle] of opfs.entries()) {
        if (handle.kind === 'file') {
          await opfs.removeEntry(name);
          count++;
        }
      }

      console.log(`[OPFS] Cleared ${count} files`);
      return count;
    } catch (error) {
      console.error(`[OPFS] Failed to clear: ${error.message}`);
      throw error;
    }
  }
};

// Log OPFS availability on load
if (typeof navigator !== 'undefined' && navigator.storage && navigator.storage.getDirectory) {
  console.log('[OPFS] Origin Private File System available');
} else {
  console.warn('[OPFS] Origin Private File System NOT available - streaming mode will not work');
}
