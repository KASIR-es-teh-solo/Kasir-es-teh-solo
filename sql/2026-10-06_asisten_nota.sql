-- 2026-10-06 (SUDAH DIJALANKAN oleh Mey) — catatan pemakaian Asisten Nota (AI), untuk batas harian & pantau saldo
create table if not exists public.asisten_nota_pakai (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  created_at timestamptz not null default now(),
  berhasil boolean not null default false,
  token_masuk int, token_keluar int
);
alter table public.asisten_nota_pakai enable row level security;
create policy "owner baca pemakaian asisten" on public.asisten_nota_pakai for select to authenticated using (public.is_owner());
-- Edge function: supabase/functions/asisten-nota (sudah di-deploy). Butuh secret ANTHROPIC_API_KEY.
