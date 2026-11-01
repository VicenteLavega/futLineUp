importScripts("./compiled/module-precache.js");
const CACHE_PREFIX = "futbolclub-";
const CACHE_VERSION = `${CACHE_PREFIX}v39`;
const APP_SHELL = [
  "./futbolClub.html",
  "./manifest.webmanifest",
  "./icons/icon.svg",
  "./styles/app.css",
  "./styles/pages.css",
  "./styles/league-table-upgrade.css",
  "./styles/league-setup.css",
  "./src/bootstrap.js",
  "./src/observability.js",
  "./src/auto-backup.js",
  "./compiled/release.js",
  "./compiled/module-precache.js",
  ...self.FC_MODULE_PRECACHE,
  "./compiled/icons.js",
  "./compiled/data.js",
  "./compiled/supabase.js",
  "./compiled/kits.js",
  "./compiled/pitch.js",
  "./compiled/sidebar.js",
  "./compiled/page-auth.js",
  "./compiled/page-home.js",
  "./compiled/page-mode.js",
  "./compiled/page-editor.js",
  "./compiled/page-draw.js",
  "./compiled/page-kits.js",
  "./compiled/page-crests.js",
  "./compiled/page-rival.js",
  "./compiled/page-share.js",
  "./compiled/platform-charts.js",
  "./compiled/page-settings.js",
  "./compiled/page-coach.js",
  "./compiled/page-league.js",
  "./compiled/league-table-upgrade.js",
  "./compiled/page-league-setup.js",
  "./compiled/league-participant-guard.js",
  "./compiled/platform-mount.js",
  "./vendor/html2canvas.min.js",
  "./vendor/jspdf.umd.min.js",
  "./vendor/supabase.js",
  "./vendor/react.production.min.js",
  "./vendor/react-dom.production.min.js",
  "./vendor/web-vitals.attribution.iife.js",
];
const OPTIONAL_EXTERNAL = [
  "https://fonts.googleapis.com/css2?family=Bebas+Neue&family=Archivo+Narrow:wght@400;500;600;700&family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap",
];
const SHELL_URLS = new Set(
  APP_SHELL.map((path) => new URL(path, self.location.href).href),
);
const EXTERNAL_URLS = new Set(OPTIONAL_EXTERNAL);

async function fetchWithTimeout(url, timeoutMs = 8000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { mode: "cors", signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}
self.addEventListener("install", (event) => {
  event.waitUntil(
    (async () => {
      const cache = await caches.open(CACHE_VERSION);
      await cache.addAll(APP_SHELL);
      await Promise.allSettled(
        OPTIONAL_EXTERNAL.map(async (url) => {
          const response = await fetchWithTimeout(url);
          if (response.ok) await cache.put(url, response);
        }),
      );
      await self.skipWaiting();
    })(),
  );
});
self.addEventListener("activate", (event) => {
  event.waitUntil(
    (async () => {
      const keys = await caches.keys();
      await Promise.all(
        keys
          .filter(
            (key) => key.startsWith(CACHE_PREFIX) && key !== CACHE_VERSION,
          )
          .map((key) => caches.delete(key)),
      );
      await self.clients.claim();
    })(),
  );
});
self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET") return;
  const requestURL = new URL(event.request.url);
  if (
    requestURL.origin === self.location.origin &&
    requestURL.pathname.endsWith("/src/local-config.js")
  )
    return;
  const isSameOrigin = requestURL.origin === self.location.origin;
  const isExplicitAsset =
    SHELL_URLS.has(requestURL.href) || EXTERNAL_URLS.has(requestURL.href);
  // Never intercept cross-origin APIs, authentication or private resources.
  if (!isSameOrigin && !isExplicitAsset) return;
  if (event.request.mode === "navigate" && isSameOrigin) {
    event.respondWith(
      (async () => {
        try {
          const response = await fetch(event.request);
          const cache = await caches.open(CACHE_VERSION);
          await cache.put("./futbolClub.html", response.clone());
          return response;
        } catch {
          return (await caches.match("./futbolClub.html")) || Response.error();
        }
      })(),
    );
    return;
  }
  if (!isExplicitAsset) return;
  event.respondWith(
    (async () => {
      const cached = await caches.match(event.request);
      if (cached) return cached;
      try {
        const response = await fetch(event.request);
        if (response.ok || response.type === "opaque") {
          const cache = await caches.open(CACHE_VERSION);
          await cache.put(event.request, response.clone());
        }
        return response;
      } catch {
        return new Response("", { status: 503, statusText: "Offline" });
      }
    })(),
  );
});
