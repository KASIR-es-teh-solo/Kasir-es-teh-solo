-- 2026-10-24 audit Belanja Harian (sudah diterapkan langsung di database):
-- 1. dana_hitung_sisih: pesanan online (Grab/Shopee) ikut dihitung ke Dana Stok -> metode_bayar in ('tunai','online')
-- 2. policy biaya_insert_kasir_dana_stok: kasir boleh catat Gas & Bahan Harian (sealer) dari Dana Stok
create policy biaya_insert_kasir_dana_stok on public.biaya_operasional for insert
  with check (exists (select 1 from users where users.id = (select auth.uid()) and users.role = 'kasir')
    and public.user_di_cabang(cabang_id) and sumber_dana = 'dana_stok'
    and kategori in ('Gas', 'Bayar Hutang Bahan') and dicatat_oleh = (select auth.uid()));
-- 3. laba_bersih: tambah 'lain' = belanja nyata di luar resep & biaya terhitung (kebersihan, lemon, dll.), kresek & galon tidak dobel
