// Service worker bengkel Lancar Jaya Motors (terpisah dari kasir). Tidak menyimpan data: semua langsung ke internet.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', () => {});
