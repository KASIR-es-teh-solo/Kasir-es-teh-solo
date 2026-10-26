-- 2026-10-27: Pusat Kendali (Pengaturan & Amplop) membaca biaya_tetap; sebelumnya ditolak (permission denied)
grant select on public.biaya_tetap to authenticated;
do $$ begin
  if not exists (select 1 from pg_policies where tablename='biaya_tetap' and policyname='biaya_tetap_baca_admin_owner') then
    create policy biaya_tetap_baca_admin_owner on public.biaya_tetap for select to authenticated using (public.is_admin_or_owner());
  end if;
end $$;
