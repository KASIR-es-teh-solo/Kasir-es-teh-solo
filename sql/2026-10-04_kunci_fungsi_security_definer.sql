-- 2026-10-04 (SUDAH DIJALANKAN oleh Mey) — keamanan fungsi database
-- 1) Fungsi arsip kas: cuma jadwal otomatis (pg_cron) yang boleh jalankan; arsip cuma dibaca owner/admin
alter policy "owner baca arsip kas" on public.kas_shift_arsip using (public.is_admin_or_owner());
revoke execute on function public.arsipkan_riwayat_kas_lama() from public, anon, authenticated;

-- 2) Semua fungsi SECURITY DEFINER: tidak bisa dipanggil tanpa login (anon).
--    Fungsi trigger juga tidak bisa dipanggil langsung oleh user login (trigger tetap jalan normal).
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as f, p.prorettype = 'trigger'::regtype as is_trg
           from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.prosecdef loop
    execute format('revoke execute on function %s from public, anon', r.f);
    if r.is_trg then
      execute format('revoke execute on function %s from authenticated', r.f);
    end if;
  end loop;
end $$;
alter default privileges in schema public revoke execute on functions from public, anon;

-- Juga sudah jalan: sql/2026-10-04_riwayat_kas_hapus_otomatis_3_hari.sql (versi Mey: tabel kas_shift_arsip,
-- fungsi arsipkan_riwayat_kas_lama, pg_cron 'arsip-riwayat-kas' jam 18:00 UTC = 01:00 WIB)

-- 3) Fungsi internal hitung ulang modal & sinkron stok: cuma dipanggil trigger/fungsi lain, bukan oleh user
revoke execute on function public.hitung_ulang_modal_bahan(uuid) from authenticated;
revoke execute on function public.sinkron_stok_produk(uuid, uuid) from authenticated;
