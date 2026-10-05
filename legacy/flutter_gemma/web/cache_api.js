/**
 * Cache API wrapper for flutter_gemma
 *
 * Provides browser Cache API operations with proper error handling.
 * All functions are async and return Promises.
 */

/**
 * Check if a URL is cached
 * @param {string} cacheName - Name of the cache
 * @param {string} url - URL to check
 * @returns {Promise<boolean>}
 */
window.cacheHas = async function(cacheName, url) {
  try {
    const cache = await caches.open(cacheName);
    const response = await cache.match(url);
    return !!response;
  } catch (error) {
    console.error('cacheHas error:', error);
    return false;
  }
};

/**
 * Get blob URL from cached data
 * @param {string} cacheName - Name of the cache
 * @param {string} url - URL to retrieve
 * @returns {Promise<string|null>} Blob URL or null if not found/error
 */
window.cacheGetBlobUrl = async function(cacheName, url) {
  try {
    const cache = await caches.open(cacheName);
    const response = await cache.match(url);

    if (!response) {
      console.log('cacheGetBlobUrl: Not found in cache:', url);
      return null;
    }

    // Get arrayBuffer to preserve exact binary data (not response.blob() which can modify data)
    // This ensures TFLite/LiteRT models load correctly
    const arrayBuffer = await response.arrayBuffer();

    // Create blob exactly as it was created originally (matching direct blob creation)
    const blob = new Blob([arrayBuffer], {
      type: 'application/octet-stream'
    });

    // Create blob URL
    const blobUrl = URL.createObjectURL(blob);
    console.log('cacheGetBlobUrl: Created blob URL:', blobUrl, 'for:', url);

    return blobUrl;
  } catch (error) {
    console.error('cacheGetBlobUrl error:', error);
    return null;
  }
};

/**
 * Store data in cache
 * @param {string} cacheName - Name of the cache
 * @param {string} url - URL key for the cache entry
 * @param {Uint8Array} data - Binary data to cache
 * @returns {Promise<void>}
 */
window.cachePut = async function(cacheName, url, data) {
  try {
    const cache = await caches.open(cacheName);

    // Create Response from Uint8Array
    const response = new Response(data, {
      headers: {
        'Content-Type': 'application/octet-stream',
        'Content-Length': data.length.toString()
      }
    });

    await cache.put(url, response);
    console.log('cachePut: Cached', data.length, 'bytes for:', url);
  } catch (error) {
    console.error('cachePut error:', error);

    // Handle QuotaExceededError
    if (error.name === 'QuotaExceededError') {
      throw new Error('Storage quota exceeded. Please clear some cache space.');
    }

    throw error;
  }
};

/**
 * Delete a cache entry
 * @param {string} cacheName - Name of the cache
 * @param {string} url - URL to delete
 * @returns {Promise<boolean>} true if deleted, false otherwise
 */
window.cacheDelete = async function(cacheName, url) {
  try {
    const cache = await caches.open(cacheName);
    const success = await cache.delete(url);
    console.log('cacheDelete:', success ? 'Deleted' : 'Not found', url);
    return success;
  } catch (error) {
    console.error('cacheDelete error:', error);
    return false;
  }
};

/**
 * Delete entire cache
 * @param {string} cacheName - Name of the cache to delete
 * @returns {Promise<boolean>} true if deleted, false otherwise
 */
window.cacheDeleteCache = async function(cacheName) {
  try {
    const success = await caches.delete(cacheName);
    console.log('cacheDeleteCache:', success ? 'Deleted' : 'Not found', cacheName);
    return success;
  } catch (error) {
    console.error('cacheDeleteCache error:', error);
    return false;
  }
};

/**
 * Get all keys in cache
 * @param {string} cacheName - Name of the cache
 * @returns {Promise<string[]>} Array of URLs
 */
window.cacheGetAllKeys = async function(cacheName) {
  try {
    const cache = await caches.open(cacheName);
    const requests = await cache.keys();
    const urls = requests.map(req => req.url);
    console.log('cacheGetAllKeys: Found', urls.length, 'entries in', cacheName);
    return urls;
  } catch (error) {
    console.error('cacheGetAllKeys error:', error);
    return [];
  }
};

/**
 * Request persistent storage
 * @returns {Promise<boolean>} true if granted, false otherwise
 */
window.storageRequestPersistent = async function() {
  try {
    if (!navigator.storage || !navigator.storage.persist) {
      console.warn('Persistent storage not supported');
      return false;
    }

    const granted = await navigator.storage.persist();
    console.log('storageRequestPersistent:', granted ? 'Granted' : 'Denied');
    return granted;
  } catch (error) {
    console.error('storageRequestPersistent error:', error);
    return false;
  }
};

/**
 * Get storage quota information
 * @returns {Promise<{usage: number, quota: number}>}
 */
window.storageGetQuota = async function() {
  try {
    if (!navigator.storage || !navigator.storage.estimate) {
      console.warn('Storage estimate not supported');
      return { usage: 0, quota: 0 };
    }

    const estimate = await navigator.storage.estimate();
    console.log('storageGetQuota:', {
      usage: estimate.usage,
      quota: estimate.quota,
      percent: ((estimate.usage / estimate.quota) * 100).toFixed(1) + '%'
    });

    return {
      usage: estimate.usage || 0,
      quota: estimate.quota || 0
    };
  } catch (error) {
    console.error('storageGetQuota error:', error);
    return { usage: 0, quota: 0 };
  }
};

/**
 * Revoke a blob URL
 * @param {string} blobUrl - Blob URL to revoke
 */
window.blobUrlRevoke = function(blobUrl) {
  try {
    URL.revokeObjectURL(blobUrl);
    console.log('blobUrlRevoke: Revoked', blobUrl);
  } catch (error) {
    console.error('blobUrlRevoke error:', error);
  }
};

/**
 * Create a blob from Uint8Array
 * @param {Uint8Array} data - Binary data
 * @returns {Blob} Blob object
 */
window.createBlob = function(data) {
  try {
    const blob = new Blob([data], {
      type: 'application/octet-stream'
    });
    console.log('createBlob: Created blob of size', data.length);
    return blob;
  } catch (error) {
    console.error('createBlob error:', error);
    throw error;
  }
};

console.log('Cache API wrapper loaded');
