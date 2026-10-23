-- KUR BRI dari kasir: Pengeluaran kategori 'KUR BRI' (Kas Outlet) otomatis masuk tandon KUR di Tandon Dollar.
-- Batal (jumlah jadi 0) -> catatan keluar di tandon. Pengingat Tabungan & KUR BRI pakai setoran_harian_status.
-- (sudah diterapkan lewat migration kur_bri_dari_kasir, 23 Okt 2026)
alter table public.kaleng_catatan add column if not exists biaya_id uuid;
alter table public.kaleng_pengaturan add column if not exists setoran_cabang uuid default '199e77b5-f52e-4534-9656-3a0d8fceddfd';
-- fungsi: public.trg_kur_dari_kasir() (trigger after insert or update of jumlah on biaya_operasional)
-- fungsi: public.setoran_harian_status(p_cabang uuid default null) -> {wajib, tabungan, kur, tabungan_target, kur_target}
