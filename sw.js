// =====================================================================
// Service worker Kasir Es Teh S.O.L.O
// Tujuan: aplikasi TETAP BISA DIBUKA walau internet mati / HP di-refresh saat offline.
//
// - Halaman aplikasi (index.html): selalu coba ambil versi TERBARU dari internet.
//   Kalau internet mati atau terlalu lambat (> 6 detik), pakai salinan terakhir di HP.
// - Library (Supabase, Chart.js, XLSX): versinya dikunci, isinya tidak pernah berubah,
//   jadi langsung pakai salinan di HP (lebih cepat & jalan saat offline).
// - Data (database Supabase): TIDAK disentuh sama sekali, selalu langsung ke server.
//
// File ini harus di-upload di folder yang sama dengan index.html.
// =====================================================================
const CACHE = 'kasir-esteh-v2';
const LIBRARY = [
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.1',
  'https://cdn.jsdelivr.net/npm/chart.js@4.5.1',
  'https://cdn.jsdelivr.net/npm/xlsx@0.18.5/dist/xlsx.full.min.js'
];
const BATAS_TUNGGU_HALAMAN = 6000;

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    // simpan salinan halaman & library. Kalau ada yang gagal (sinyal jelek), tidak apa-apa:
    // nanti tersimpan otomatis saat dipakai.
    try {
      const res = await fetch(self.registration.scope, { cache: 'no-cache', credentials: 'same-origin' });
      if (res.ok) await cache.put(self.registration.scope, res);
    } catch (e) {}
    // mode 'cors' supaya status respons bisa dicek: yang disimpan HANYA respons sukses (200).
    // Respons 'opaque' (no-cors) tidak bisa dicek, jadi error CDN bisa ikut tersimpan & dipakai terus.
    for (const url of LIBRARY) {
      try {
        const res = await fetch(url, { mode: 'cors', credentials: 'omit' });
        if (res.ok) await cache.put(url, res);
      } catch (e) {}
    }
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    for (const key of await caches.keys()) {
      if (key !== CACHE) await caches.delete(key); // buang salinan versi lama
    }
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);

  if (req.mode === 'navigate' && url.origin === self.location.origin) {
    event.respondWith(ambilHalaman(req));
    return;
  }
  if (url.hostname === 'cdn.jsdelivr.net') {
    event.respondWith(ambilLibrary(req));
  }
  // selain itu (database Supabase, dll.) dibiarkan langsung ke internet
});

async function ambilHalaman(req) {
  const cache = await caches.open(CACHE);
  const kunci = self.registration.scope;
  const dariInternet = fetch(req.url, { cache: 'no-cache', credentials: 'same-origin' }).then((res) => {
    if (res.ok) cache.put(kunci, res.clone());
    return res;
  });
  dariInternet.catch(() => {}); // cegah error "tidak ditangani" kalau internet mati

  try {
    return await Promise.race([
      dariInternet,
      new Promise((_, gagal) => setTimeout(() => gagal(new Error('terlalu lambat')), BATAS_TUNGGU_HALAMAN))
    ]);
  } catch (e) {
    const salinan = await cache.match(kunci);
    if (salinan) return salinan;
    return dariInternet; // belum ada salinan sama sekali: terpaksa tunggu internet
  }
}

async function ambilLibrary(req) {
  const cache = await caches.open(CACHE);
  const salinan = await cache.match(req.url);
  if (salinan) return salinan;
  try {
    // ambil versi 'cors' untuk disimpan (statusnya bisa dicek); hanya respons sukses yang disimpan
    const res = await fetch(req.url, { mode: 'cors', credentials: 'omit' });
    if (res.ok) {
      cache.put(req.url, res.clone());
      return res;
    }
  } catch (e) {}
  return fetch(req); // gagal / error: teruskan permintaan asli apa adanya, TIDAK disimpan
}
