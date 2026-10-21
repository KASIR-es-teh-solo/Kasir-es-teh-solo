-- 21 Okt 2026: Mulai baru (data keuangan lama diarsip ke schema arsip.*_20261021,
-- saldo awal Kas Outlet Pusat Dermo Rp500.000 & Brankas Rp7.100.000).
-- Cek kesehatan: fungsi saldo tutup kas tidak boleh dipanggil tanpa login.
revoke execute on function public.kas_toko_saldo_tutup(uuid) from public, anon;
grant execute on function public.kas_toko_saldo_tutup(uuid) to authenticated;
