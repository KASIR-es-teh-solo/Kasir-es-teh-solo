// Service worker Kaleng Keluarga (terpisah dari aplikasi kasir). Tidak menyimpan data: semua langsung ke internet.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', () => {});
