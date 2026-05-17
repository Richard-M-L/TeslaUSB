/**
 * Service Worker for caching OpenStreetMap tiles offline.
 *
 * Strategy: Network-first with cache fallback + timeout.
 * - Tile requests go to the network first.
 * - Network requests time out after 8 s → served from cache.
 * - Successful responses are cached for offline use.
 * - If offline (or timeout with no cache hit), a transparent 1×1 PNG
 *   is returned so the page never hangs waiting for a missing tile.
 *
 * Safari compatibility:
 *   - event.respondWith() is called synchronously (regex test, no async).
 *   - The fetch inside respondWith always resolves — never rejects —
 *     because an unhandled rejection would leave Safari spinning its
 *     loading indicator forever.
 *   - skipWaiting is wrapped in waitUntil (Safari 15 requirement).
 */

const TILE_CACHE = 'teslausb-map-tiles-v1';
// Tiles are now proxied through the Pi (/tiles/<z>/<x>/<y>.png)
// so devices without direct internet can still see the map.
var TILE_PATTERN = /\/tiles\/\d+\/\d+\/\d+\.png$/;
const NETWORK_TIMEOUT_MS = 8000;

/**
 * Return a promise that rejects after ``ms`` milliseconds.
 */
function timeout(ms) {
    return new Promise(function (_, reject) {
        setTimeout(function () { reject(new Error('timeout')); }, ms);
    });
}

/**
 * Transparent 1×1 PNG (67 bytes).  Safari will not hang on this; the
 * loading spinner stops as soon as every respondWith call has settled.
 */
var TRANSPARENT_PNG_BYTES = new Uint8Array(
    [137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1,8,2,0,0,0,144,119,83,222,0,0,0,9,112,72,89,115,0,0,11,19,0,0,11,19,1,0,154,156,24,0,0,0,7,116,73,77,69,7,226,5,14,13,42,47,59,71,36,0,0,0,29,73,68,65,84,8,215,99,248,255,255,63,0,5,254,2,254,2,2,48,0,197,0,5,63,180,116,215,0,0,0,0,73,69,78,68,174,66,96,130]
);

function transparentPngResponse() {
    return new Response(TRANSPARENT_PNG_BYTES, {
        status: 200,
        headers: { 'Content-Type': 'image/png' }
    });
}

self.addEventListener('install', function (event) {
    // Safari 15 requires waitUntil wrapping for skipWaiting.
    event.waitUntil(self.skipWaiting());
});

self.addEventListener('activate', function (event) {
    event.waitUntil(
        caches.keys().then(function (keys) {
            return Promise.all(
                keys.filter(function (k) {
                    return k.startsWith('teslausb-map-tiles-') && k !== TILE_CACHE;
                }).map(function (k) {
                    return caches.delete(k);
                })
            );
        }).then(function () {
            return self.clients.claim();
        })
    );
});

self.addEventListener('fetch', function (event) {
    var url = event.request.url;

    // Only intercept OSM tile requests.  The test is synchronous so
    // respondWith fires in the same microtask — required by Safari.
    if (!TILE_PATTERN.test(url)) return;

    event.respondWith(
        Promise.race([
            fetch(event.request).then(function (response) {
                // Cache successful responses for offline use.
                // Clone first — response body can only be read once.
                if (response.ok) {
                    try {
                        var clone = response.clone();
                        caches.open(TILE_CACHE).then(function (cache) {
                            cache.put(event.request, clone);
                        });
                    } catch (_) {
                        // Cache write failed — not fatal.
                    }
                }
                return response;
            }),
            timeout(NETWORK_TIMEOUT_MS)
        ]).catch(function () {
            // Network failed or timed out — serve from cache.
            return caches.match(event.request).then(function (cached) {
                return cached || transparentPngResponse();
            });
        }).catch(function () {
            // Absolute last resort: if even cache.match() throws
            // (e.g. Safari private-browsing storage quota), return a
            // transparent PNG so the request ALWAYS settles.
            return transparentPngResponse();
        })
    );
});
