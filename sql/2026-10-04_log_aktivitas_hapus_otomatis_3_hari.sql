-- 2026-10-04 (SUDAH DIJALANKAN oleh Mey) — Log Aktivitas lebih dari 3 hari dipindah otomatis ke arsip
create table if not exists public.log_aktivitas_arsip (like public.log_aktivitas including defaults);
alter table public.log_aktivitas_arsip add column if not exists diarsipkan_at timestamptz default now();
alter table public.log_aktivitas_arsip enable row level security;
create policy "owner baca arsip log" on public.log_aktivitas_arsip for select to authenticated using (public.is_owner());

create or replace function public.arsipkan_log_aktivitas_lama()
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  with pindah as (
    delete from log_aktivitas where created_at < now() - interval '3 days' returning *
  )
  insert into log_aktivitas_arsip select p.*, now() from pindah p;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.arsipkan_log_aktivitas_lama() from public, anon, authenticated;

-- tiap hari 01:05 WIB (18:05 UTC)
select cron.schedule('arsip-log-aktivitas', '5 18 * * *', 'select public.arsipkan_log_aktivitas_lama()');
