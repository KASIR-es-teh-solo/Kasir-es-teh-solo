-- 2026-09-27 — sudah dijalankan di Supabase oleh Mey atas permintaan Owner.
-- Saklar ON/OFF fitur "akhiri shift otomatis setelah Hitung Kas" (default OFF).
insert into pengaturan_sistem(kunci,nilai) values ('akhiri_shift_aktif','false') on conflict (kunci) do nothing;

create or replace function public.pengaturan_absen()
 returns json language sql stable security definer set search_path to 'public'
as $function$
  select json_build_object(
    'wajib', coalesce((select nilai='true' from pengaturan_sistem where kunci='absen_foto_wajib'), false),
    'radius', coalesce((select nilai::numeric from pengaturan_sistem where kunci='absen_radius_meter'), 35),
    'akhiri_shift', coalesce((select nilai='true' from pengaturan_sistem where kunci='akhiri_shift_aktif'), false));
$function$;

create or replace function public.set_akhiri_shift(p_aktif boolean)
 returns text language plpgsql security definer set search_path to 'public'
as $function$
begin
  if not public.is_owner() then raise exception 'Hanya owner yang boleh mengubah pengaturan ini'; end if;
  insert into pengaturan_sistem(kunci,nilai) values ('akhiri_shift_aktif', case when p_aktif then 'true' else 'false' end)
    on conflict (kunci) do update set nilai=excluded.nilai, updated_at=now();
  return case when p_aktif then 'Akhiri shift otomatis: ON' else 'Akhiri shift otomatis: OFF' end;
end $function$;

grant execute on function public.set_akhiri_shift(boolean) to authenticated;
