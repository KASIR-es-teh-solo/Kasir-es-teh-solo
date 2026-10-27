-- 2026-10-28: Buku Catatan Aplikasi (privat). Isinya TIDAK disimpan di repo karena repo publik.
-- catatan_aplikasi = peta fitur yang berlaku sekarang; riwayat_aplikasi = semua perubahan (git, migrasi, data oleh Mey, keputusan).
create table if not exists public.catatan_aplikasi (
  kunci text primary key, urutan int not null default 0, judul text not null, isi text not null,
  diubah_at timestamptz not null default now());
create table if not exists public.riwayat_aplikasi (
  id bigserial primary key, waktu timestamptz not null, aplikasi text not null,
  jenis text not null check (jenis in ('tambah','hapus','ubah','perbaiki','data','database','keputusan')),
  isi text not null, versi text, sumber text, dibuat_at timestamptz not null default now());
create index if not exists riwayat_aplikasi_waktu_idx on public.riwayat_aplikasi(waktu);
create unique index if not exists riwayat_aplikasi_sumber_uq on public.riwayat_aplikasi(sumber) where sumber is not null;
alter table public.catatan_aplikasi enable row level security;
alter table public.riwayat_aplikasi enable row level security;
revoke all on public.catatan_aplikasi, public.riwayat_aplikasi from anon;
revoke insert, update, delete on public.catatan_aplikasi, public.riwayat_aplikasi from authenticated;
grant select on public.catatan_aplikasi, public.riwayat_aplikasi to authenticated;
create policy catatan_baca_owner on public.catatan_aplikasi for select to authenticated using ((select public.is_owner()));
create policy riwayat_baca_owner on public.riwayat_aplikasi for select to authenticated using ((select public.is_owner()));
revoke usage, select on sequence public.riwayat_aplikasi_id_seq from anon, authenticated;
