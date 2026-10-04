-- 2026-10-04 — RENCANA (belum dijalankan, menunggu izin Owner). Disiapkan oleh Mey atas permintaan Owner.
-- Riwayat Tutup Kas (kas_shift) yang sudah lewat 3 hari dihapus otomatis dari daftar.
-- * "Lewat 3 hari" = tanggal tutup (WIB) lebih lama dari hari ini - 3 (hari ini + 3 hari sebelumnya tetap tampil).
-- * Tutup kas TERAKHIR tiap cabang tidak pernah dihapus (dipakai hitung Saldo Kas & kas awal berikutnya).
-- * Data yang dihapus dipindah ke kas_shift_arsip (cadangan, hanya Owner yang bisa lihat) supaya masih bisa dicek kalau perlu.
-- * Pembersihan jalan otomatis setiap ada tutup kas baru (trigger), tanpa jadwal tambahan.

create table if not exists public.kas_shift_arsip (
  like public.kas_shift including defaults,
  diarsipkan_at timestamptz not null default now()
);
alter table public.kas_shift_arsip enable row level security;
drop policy if exists kas_shift_arsip_read_owner on public.kas_shift_arsip;
create policy kas_shift_arsip_read_owner on public.kas_shift_arsip for select using (public.is_owner());

create or replace function public.bersihkan_riwayat_kas()
 returns integer language plpgsql security definer set search_path to 'public'
as $function$
declare v_jumlah integer;
begin
  with terakhir as (
    select distinct on (cabang_id) id from kas_shift
    where waktu_tutup is not null
    order by cabang_id, waktu_tutup desc
  ), lama as (
    delete from kas_shift k
     where k.waktu_tutup is not null
       and (k.waktu_tutup at time zone 'Asia/Jakarta')::date < (now() at time zone 'Asia/Jakarta')::date - 3
       and k.id not in (select id from terakhir)
    returning k.*
  )
  insert into kas_shift_arsip select lama.*, now() from lama;
  get diagnostics v_jumlah = row_count;
  return v_jumlah;
end $function$;
revoke all on function public.bersihkan_riwayat_kas() from public, anon;

create or replace function public.trg_bersihkan_riwayat_kas()
 returns trigger language plpgsql security definer set search_path to 'public'
as $function$
begin
  perform public.bersihkan_riwayat_kas();
  return null;
end $function$;

drop trigger if exists trg_bersihkan_riwayat_kas on public.kas_shift;
create trigger trg_bersihkan_riwayat_kas after insert on public.kas_shift
  for each statement execute function public.trg_bersihkan_riwayat_kas();

-- jalankan sekali sekarang + catat di log aktivitas
do $$
declare n integer; v_owner uuid;
begin
  n := public.bersihkan_riwayat_kas();
  select id into v_owner from users where role='owner' limit 1;
  insert into log_aktivitas(user_id, aksi, keterangan)
  values (v_owner, 'Hapus Riwayat Kas Otomatis',
    'Riwayat tutup kas lebih dari 3 hari dihapus dari daftar (' || n || ' catatan, cadangan di kas_shift_arsip). Mulai sekarang otomatis setiap tutup kas baru (dicatat oleh Mey atas permintaan Owner)');
end $$;
