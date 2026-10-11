-- Check-up 11 Okt 2026 (Mey): perbaikan performa database, TIDAK mengubah data / hak akses.
-- 1) Kebijakan RLS: auth.uid() dibungkus (select auth.uid()) supaya dihitung sekali per query, bukan per baris.
--    Arti aturan akses sama persis (siapa boleh apa tidak berubah).
do $$
declare r record; q text; w text; tok constant text := '@@UID@@';
begin
  for r in select tablename, policyname, qual, with_check from pg_policies
           where schemaname='public' and coalesce(qual,'')||coalesce(with_check,'') ~ 'auth\.uid\(\)' loop
    q := r.qual; w := r.with_check;
    if q is not null then
      q := replace(replace(replace(q,'( SELECT auth.uid() AS uid)',tok),'auth.uid()','(select auth.uid())'),tok,'(select auth.uid())');
      execute format('alter policy %I on public.%I using (%s)', r.policyname, r.tablename, q);
    end if;
    if w is not null then
      w := replace(replace(replace(w,'( SELECT auth.uid() AS uid)',tok),'auth.uid()','(select auth.uid())'),tok,'(select auth.uid())');
      execute format('alter policy %I on public.%I with check (%s)', r.policyname, r.tablename, w);
    end if;
  end loop;
end $$;

-- 2) Index untuk foreign key yang belum punya index
create index if not exists idx_bahan_rusak_bahan_baku_id on public.bahan_rusak(bahan_baku_id);
create index if not exists idx_bahan_rusak_dicatat_oleh on public.bahan_rusak(dicatat_oleh);
create index if not exists idx_stempel_hadiah_cabang_id on public.stempel_hadiah(cabang_id);
create index if not exists idx_stempel_hadiah_pelanggan_id on public.stempel_hadiah(pelanggan_id);
create index if not exists idx_stempel_hadiah_transaksi_id on public.stempel_hadiah(transaksi_id);
create index if not exists idx_stempel_klaim_pelanggan_id on public.stempel_klaim(pelanggan_id);
create index if not exists idx_stempel_pelanggan_cabang_id on public.stempel_pelanggan(cabang_id);
create index if not exists idx_teh_siap_log_dicatat_oleh on public.teh_siap_log(dicatat_oleh);
create index if not exists idx_transaksi_gagal_transaksi_id on public.transaksi_gagal(transaksi_id);

-- 3) Primary key untuk tabel arsip
alter table public.kas_shift_arsip add primary key (id);
alter table public.log_aktivitas_arsip add primary key (id);
