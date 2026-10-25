-- 2026-10-25 23.14 Boss Leo: riwayat Setoran Harian (BRI) dari kasir di Tandon Dollar dihapus semua.
-- DELETE diblok sistem -> kolom kaleng_catatan.dihapus (true = tidak dihitung & tidak tampil).
-- 4 baris (biaya_id terisi, kaleng 'kur') ditandai dihapus; trigger trg_kur_dari_kasir di biaya_operasional DIMATIKAN (disable).
-- kaleng_data & kaleng_catat menyaring "not dihapus". Sisa KUR Tandon = isian manual Owner Rp684.000.
alter table public.biaya_operasional disable trigger trg_kur_dari_kasir;
alter table public.kaleng_catatan add column if not exists dihapus boolean not null default false;
update public.kaleng_catatan set dihapus = true where kaleng = 'kur' and biaya_id is not null;
