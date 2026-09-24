-- =====================================================================
-- Kasir Es Teh S.O.L.O — perubahan database 24 Sep 2026
--   A. Anti-duplikat transaksi (ID unik dari aplikasi: client_tx_id)
--   B. Fungsi tambah_stok (penjumlahan di database + riwayat siapa/jam berapa)
--   C. Daftar "Transaksi Gagal" (ditolak permanen, TIDAK dihapus)
--
-- Aman untuk data lama:
--   * kolom baru client_tx_id boleh kosong (NULL); transaksi lama tetap NULL
--     dan TIDAK bentrok dengan kunci unik (NULL tidak dianggap sama di Postgres)
--   * tidak ada data yang dihapus/diubah
--   * aplikasi yang sekarang live tetap jalan (parameter baru punya default)
--
-- Semua dibungkus 1 transaksi: kalau ada 1 langkah gagal, SEMUA dibatalkan.
-- Jalankan di Supabase -> SQL Editor -> New query -> tempel semua -> Run.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- A. ANTI-DUPLIKAT TRANSAKSI
-- ---------------------------------------------------------------------

alter table public.transaksi
  add column if not exists client_tx_id text;

comment on column public.transaksi.client_tx_id is
  'ID unik buatan aplikasi saat tombol BAYAR ditekan. NULL untuk transaksi lama.';

create unique index if not exists transaksi_client_tx_id_key
  on public.transaksi (client_tx_id);

-- Fungsi lama di-drop dulu (kalau cuma CREATE OR REPLACE dengan parameter baru,
-- Postgres bikin fungsi kembar dan Supabase bingung memilih yang mana).
drop function if exists public.simpan_transaksi(uuid, numeric, numeric, numeric, text, jsonb, timestamptz, boolean, uuid);
-- (versi baru juga di-drop, supaya SQL ini aman kalau tidak sengaja dijalankan 2x)
drop function if exists public.simpan_transaksi(uuid, numeric, numeric, numeric, text, jsonb, timestamptz, boolean, uuid, text);

create function public.simpan_transaksi(
  p_cabang uuid, p_total numeric, p_subtotal numeric, p_diskon numeric, p_metode text, p_items jsonb,
  p_created_at timestamptz default null, p_offline boolean default false, p_kasir uuid default null,
  p_client_id text default null
)
returns jsonb
language plpgsql
set search_path to 'public'
as $function$
declare v_tx uuid; v_kurang text;
begin
  -- antrian per cabang supaya 2 kasir tidak lolos bersamaan memakai bahan yang sama
  perform pg_advisory_xact_lock(hashtext('trx_' || p_cabang::text));

  -- SUDAH PERNAH TERSIMPAN? -> jangan simpan lagi (dicek SEBELUM cek stok,
  -- supaya kiriman ulang tidak ditolak STOK_KURANG padahal sudah masuk)
  if p_client_id is not null then
    select id into v_tx from transaksi where client_tx_id = p_client_id;
    if v_tx is not null then
      return jsonb_build_object('transaksi_id', v_tx, 'status', 'sudah_tersimpan');
    end if;
  end if;

  if public.stok_otomatis_aktif() then
    select string_agg(format('%s (butuh %s %s, sisa %s)', bahan, trim_scale(butuh), satuan, trim_scale(tersedia)), '; ')
      into v_kurang from public.cek_kekurangan_bahan(p_cabang, p_items);
  end if;

  if v_kurang is not null and not p_offline then
    raise exception 'STOK_KURANG: %', v_kurang using errcode = 'P0001';
  end if;

  begin
    insert into transaksi(kasir_id, cabang_id, total, subtotal, diskon, metode_bayar, created_at, client_tx_id)
    values (coalesce(p_kasir, auth.uid()), p_cabang, p_total, p_subtotal, coalesce(p_diskon,0),
            coalesce(p_metode,'tunai'), coalesce(p_created_at, now()), p_client_id)
    returning id into v_tx;
  exception when unique_violation then
    -- kiriman kembar yang lolos bersamaan: yang satu sudah menyimpan
    select id into v_tx from transaksi where client_tx_id = p_client_id;
    return jsonb_build_object('transaksi_id', v_tx, 'status', 'sudah_tersimpan');
  end;

  insert into transaksi_item(transaksi_id, produk_id, ukuran, harga_satuan, qty, subtotal)
  select v_tx, (x->>'produk_id')::uuid, x->>'ukuran', (x->>'harga_satuan')::numeric,
         (x->>'qty')::int, (x->>'subtotal')::numeric
  from jsonb_array_elements(p_items) x;

  if v_kurang is not null and p_offline then
    insert into log_aktivitas(cabang_id, user_id, aksi, keterangan)
    values (p_cabang, auth.uid(), 'Stok bahan minus (transaksi offline)',
            'Transaksi offline ' || to_char(coalesce(p_created_at, now()) at time zone 'Asia/Jakarta', 'DD/MM HH24:MI')
            || ' tetap disimpan. Bahan kurang: ' || v_kurang);
  end if;

  return jsonb_build_object('transaksi_id', v_tx, 'status', 'baru');
end $function$;

-- ---------------------------------------------------------------------
-- B. TAMBAH STOK DI DATABASE + RIWAYAT
-- ---------------------------------------------------------------------

create table if not exists public.riwayat_tambah_stok (
  id            uuid primary key default gen_random_uuid(),
  jenis         text not null check (jenis in ('produk','bahan')),
  item_id       uuid not null,
  nama_item     text,
  cabang_id     uuid,
  jumlah        numeric not null,
  stok_sebelum  numeric not null,
  stok_sesudah  numeric not null,
  oleh          uuid,
  keterangan    text,
  created_at    timestamptz not null default now()
);
create index if not exists riwayat_tambah_stok_cabang_waktu on public.riwayat_tambah_stok (cabang_id, created_at desc);

alter table public.riwayat_tambah_stok enable row level security;
drop policy if exists riwayat_tambah_stok_select_admin_owner on public.riwayat_tambah_stok;
create policy riwayat_tambah_stok_select_admin_owner on public.riwayat_tambah_stok
  for select using (public.is_admin_or_owner());
-- sengaja TIDAK ada policy insert/update/delete: riwayat hanya bisa ditulis lewat fungsi tambah_stok

create or replace function public.tambah_stok(
  p_jenis text, p_item uuid, p_cabang uuid, p_jumlah numeric, p_keterangan text default null
)
returns numeric
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_sesudah numeric; v_nama text; v_satuan text := '';
begin
  if not public.is_admin_or_owner() then
    raise exception 'Hanya Owner/Admin yang boleh menambah stok.' using errcode = '42501';
  end if;
  if p_jumlah is null or p_jumlah <= 0 then
    raise exception 'Jumlah tambahan harus lebih dari 0.' using errcode = '22023';
  end if;

  if p_jenis = 'produk' then
    if p_jumlah <> trunc(p_jumlah) then
      raise exception 'Stok produk harus bilangan bulat.' using errcode = '22023';
    end if;
    -- penjumlahan terjadi DI DATABASE: baris dikunci, tidak bisa bentrok dengan penjualan
    update stok_cabang set stok = stok + p_jumlah::int
      where produk_id = p_item and cabang_id = p_cabang
      returning stok into v_sesudah;
    select nama into v_nama from produk where id = p_item;
  elsif p_jenis = 'bahan' then
    update bahan_baku_stok set stok = stok + p_jumlah
      where bahan_baku_id = p_item and cabang_id = p_cabang
      returning stok into v_sesudah;
    select nama, coalesce(' ' || satuan, '') into v_nama, v_satuan from bahan_baku where id = p_item;
  else
    raise exception 'Jenis stok tidak dikenal: % (pakai produk / bahan)', p_jenis using errcode = '22023';
  end if;

  if v_sesudah is null then
    raise exception 'Data stok untuk cabang ini tidak ditemukan.' using errcode = 'P0002';
  end if;

  insert into riwayat_tambah_stok(jenis, item_id, nama_item, cabang_id, jumlah, stok_sebelum, stok_sesudah, oleh, keterangan)
  values (p_jenis, p_item, v_nama, p_cabang, p_jumlah, v_sesudah - p_jumlah, v_sesudah, auth.uid(), p_keterangan);

  insert into log_aktivitas(cabang_id, user_id, aksi, keterangan)
  values (p_cabang, auth.uid(), 'Tambah Stok',
          format('%s "%s": +%s%s (%s → %s)', case when p_jenis='produk' then 'Produk' else 'Bahan' end,
                 coalesce(v_nama,'?'), trim_scale(p_jumlah), v_satuan,
                 trim_scale(v_sesudah - p_jumlah), trim_scale(v_sesudah)));

  return v_sesudah;
end $function$;

-- ---------------------------------------------------------------------
-- C. TRANSAKSI GAGAL (ditolak permanen oleh server, uang sudah diterima kasir)
-- ---------------------------------------------------------------------

create table if not exists public.transaksi_gagal (
  id                 uuid primary key default gen_random_uuid(),
  client_tx_id       text not null unique,
  cabang_id          uuid,
  kasir_id           uuid,
  total              numeric not null default 0,
  waktu_transaksi    timestamptz,
  payload            jsonb not null,          -- isi lengkap transaksi dari antrian HP kasir
  alasan             text not null,           -- pesan error dari server
  kode_error         text,
  dilaporkan_oleh    uuid,
  dilaporkan_at      timestamptz not null default now(),
  status             text not null default 'menunggu' check (status in ('menunggu','disimpan','dibatalkan')),
  transaksi_id       uuid references public.transaksi(id) on delete set null,
  diputuskan_oleh    uuid,
  diputuskan_at      timestamptz,
  catatan_keputusan  text
);
create index if not exists transaksi_gagal_status on public.transaksi_gagal (status, dilaporkan_at desc);

alter table public.transaksi_gagal enable row level security;
drop policy if exists transaksi_gagal_select_admin_owner on public.transaksi_gagal;
create policy transaksi_gagal_select_admin_owner on public.transaksi_gagal
  for select using (public.is_admin_or_owner());
-- sengaja TIDAK ada policy delete: catatan transaksi gagal tidak bisa dihapus dari aplikasi

-- validasi aman (tidak error kalau isinya aneh)
create or replace function public._uuid_aman(t text) returns uuid
language sql immutable as $$
  select case when t ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then t::uuid end
$$;
create or replace function public._angka_aman(t text) returns numeric
language sql immutable as $$
  select case when t ~ '^-?[0-9]+(\.[0-9]+)?$' then t::numeric end
$$;
create or replace function public._waktu_aman(t text) returns timestamptz
language plpgsql immutable as $$
begin
  return t::timestamptz;
exception when others then
  return null;
end $$;

-- Dipanggil HP kasir saat server menolak transaksi secara permanen.
-- Boleh dipanggil berkali-kali untuk transaksi yang sama (tidak jadi dobel).
create or replace function public.laporkan_transaksi_gagal(
  p_client_id text, p_payload jsonb, p_alasan text, p_kode text default null
)
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if auth.uid() is null or not exists (select 1 from users where id = auth.uid()) then
    raise exception 'Akun tidak terdaftar sebagai pegawai.' using errcode = '42501';
  end if;
  if p_client_id is null or p_payload is null then
    raise exception 'Data transaksi gagal tidak lengkap.' using errcode = '22023';
  end if;

  -- ternyata sudah tersimpan di transaksi -> tidak perlu masuk daftar gagal
  if exists (select 1 from transaksi where client_tx_id = p_client_id) then
    return 'sudah_tersimpan';
  end if;

  insert into transaksi_gagal(client_tx_id, cabang_id, kasir_id, total, waktu_transaksi, payload, alasan, kode_error, dilaporkan_oleh)
  values (p_client_id,
          public._uuid_aman(p_payload->>'cabang_id'),
          public._uuid_aman(p_payload->>'kasir_id'),
          coalesce(public._angka_aman(p_payload->>'total'), 0),
          public._waktu_aman(p_payload->>'created_at'),
          p_payload, coalesce(nullif(p_alasan,''), '(tanpa pesan)'), p_kode, auth.uid())
  on conflict (client_tx_id) do update
    set alasan = excluded.alasan, kode_error = excluded.kode_error, dilaporkan_at = now()
    where transaksi_gagal.status = 'menunggu';

  return 'tercatat';
end $function$;

-- Keputusan Owner: 'simpan' (masukkan manual ke transaksi) atau 'batal' (tidak dimasukkan, wajib catatan).
-- Catatan TIDAK dihapus, hanya statusnya yang berubah.
create or replace function public.selesaikan_transaksi_gagal(p_id uuid, p_aksi text, p_catatan text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare g transaksi_gagal%rowtype; v_hasil jsonb; v_kasir uuid;
begin
  if not public.is_owner() then
    raise exception 'Hanya Owner yang boleh memutuskan transaksi gagal.' using errcode = '42501';
  end if;

  select * into g from transaksi_gagal where id = p_id for update;
  if not found then
    raise exception 'Catatan transaksi gagal tidak ditemukan.' using errcode = 'P0002';
  end if;
  if g.status <> 'menunggu' then
    raise exception 'Transaksi ini sudah diputuskan (%).', g.status using errcode = '22023';
  end if;

  if p_aksi = 'simpan' then
    if g.cabang_id is null then
      raise exception 'Cabang transaksi tidak valid, tidak bisa disimpan. Pilih Batalkan.' using errcode = '22023';
    end if;
    -- kasir yang akunnya sudah dihapus -> dicatat atas nama Owner yang menyimpan
    v_kasir := case when exists (select 1 from users where id = g.kasir_id) then g.kasir_id else auth.uid() end;
    v_hasil := public.simpan_transaksi(
      g.cabang_id,
      g.total,
      coalesce(public._angka_aman(g.payload->>'subtotal'), g.total),
      coalesce(public._angka_aman(g.payload->>'diskon'), 0),
      coalesce(g.payload->>'metode_bayar', 'tunai'),
      coalesce(g.payload->'items', '[]'::jsonb),
      g.waktu_transaksi,
      true,             -- perlakukan seperti transaksi offline (bahan boleh minus, tercatat di log)
      v_kasir,
      g.client_tx_id
    );
    update transaksi_gagal
      set status = 'disimpan', transaksi_id = (v_hasil->>'transaksi_id')::uuid,
          diputuskan_oleh = auth.uid(), diputuskan_at = now(), catatan_keputusan = p_catatan
      where id = p_id;
    insert into log_aktivitas(cabang_id, user_id, aksi, keterangan)
    values (g.cabang_id, auth.uid(), 'Transaksi Gagal Disimpan Manual',
            format('Transaksi %s (Rp %s) disimpan manual. Alasan gagal: %s', g.client_tx_id, trim_scale(g.total), g.alasan));
    return v_hasil;

  elsif p_aksi = 'batal' then
    if coalesce(trim(p_catatan), '') = '' then
      raise exception 'Isi catatan alasan pembatalan.' using errcode = '22023';
    end if;
    update transaksi_gagal
      set status = 'dibatalkan', diputuskan_oleh = auth.uid(), diputuskan_at = now(), catatan_keputusan = p_catatan
      where id = p_id;
    insert into log_aktivitas(cabang_id, user_id, aksi, keterangan)
    values (g.cabang_id, auth.uid(), 'Transaksi Gagal Dibatalkan',
            format('Transaksi %s (Rp %s) tidak disimpan. Catatan: %s', g.client_tx_id, trim_scale(g.total), p_catatan));
    return jsonb_build_object('status', 'dibatalkan');

  else
    raise exception 'Aksi tidak dikenal: % (pakai simpan / batal)', p_aksi using errcode = '22023';
  end if;
end $function$;

-- ---------------------------------------------------------------------
-- HAK AKSES FUNGSI: hanya user yang login (authenticated), bukan anon/publik
-- ---------------------------------------------------------------------
revoke all on function public.simpan_transaksi(uuid, numeric, numeric, numeric, text, jsonb, timestamptz, boolean, uuid, text) from public, anon;
revoke all on function public.tambah_stok(text, uuid, uuid, numeric, text) from public, anon;
revoke all on function public.laporkan_transaksi_gagal(text, jsonb, text, text) from public, anon;
revoke all on function public.selesaikan_transaksi_gagal(uuid, text, text) from public, anon;
grant execute on function public.simpan_transaksi(uuid, numeric, numeric, numeric, text, jsonb, timestamptz, boolean, uuid, text) to authenticated, service_role;
grant execute on function public.tambah_stok(text, uuid, uuid, numeric, text) to authenticated, service_role;
grant execute on function public.laporkan_transaksi_gagal(text, jsonb, text, text) to authenticated, service_role;
grant execute on function public.selesaikan_transaksi_gagal(uuid, text, text) to authenticated, service_role;

-- minta Supabase membaca ulang daftar fungsi/tabel
notify pgrst, 'reload schema';

commit;

-- =====================================================================
-- CEK HASIL (jalankan terpisah SETELAH yang di atas sukses).
-- Hasil yang benar: 1 baris, semua kolom bernilai true.
-- =====================================================================
-- select
--   exists (select 1 from information_schema.columns where table_schema='public' and table_name='transaksi' and column_name='client_tx_id') as kolom_client_tx_id,
--   exists (select 1 from pg_indexes where schemaname='public' and indexname='transaksi_client_tx_id_key')                             as index_unik,
--   (select count(*) from pg_proc where pronamespace='public'::regnamespace and proname='simpan_transaksi') = 1                         as simpan_transaksi_tunggal,
--   to_regprocedure('public.tambah_stok(text,uuid,uuid,numeric,text)') is not null                                                     as fungsi_tambah_stok,
--   to_regclass('public.riwayat_tambah_stok') is not null                                                                              as tabel_riwayat_stok,
--   to_regclass('public.transaksi_gagal') is not null                                                                                  as tabel_transaksi_gagal,
--   to_regprocedure('public.laporkan_transaksi_gagal(text,jsonb,text,text)') is not null                                               as fungsi_laporkan,
--   to_regprocedure('public.selesaikan_transaksi_gagal(uuid,text,text)') is not null                                                   as fungsi_selesaikan,
--   (select count(*) from public.transaksi) > 0                                                                                        as transaksi_lama_masih_ada;
