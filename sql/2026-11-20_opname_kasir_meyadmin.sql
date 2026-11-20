-- 2026-11-20 Stok opname dikerjakan kasir, dicek MeyAdmin (WhatsApp)
-- Kasir mengisi jumlah fisik tiap Jumat (menu muncul 20.30 WIB) tanpa melihat angka stok aplikasi.
-- Stok aplikasi BELUM berubah sampai MeyAdmin (atau Owner) memutuskan: setujui / tolak / hitung ulang.
-- Toleransi: barang pcs selisih maks 3 pcs; barang gram/ml selisih maks 5%.
--   hijau = semua dalam batas; kuning = ada yang lewat batas tapi < 2x batas; merah = >= 2x batas (atau tetap lewat setelah hitung ulang).
-- Penyesuaian stok saat disetujui: stok_sekarang + (fisik - stok_saat_kirim), supaya penjualan sesudah kirim tetap terhitung.

create table if not exists public.opname_kasir (
  id uuid primary key default gen_random_uuid(),
  cabang_id uuid not null references public.cabang(id),
  minggu date not null,                         -- tanggal Jumat (WIB) putaran ini
  induk_id uuid references public.opname_kasir(id), -- diisi kalau ini hitung ulang
  dikirim_oleh uuid,
  nama_oleh text,
  dikirim_at timestamptz not null default now(),
  items jsonb not null,                         -- [{bahan_baku_id,nama,satuan,jenis,fisik,stok_saat_kirim}]
  status text not null default 'menunggu' check (status in ('menunggu','disetujui','ditolak','hitung_ulang')),
  barang_ulang uuid[],                          -- barang yang diminta dihitung ulang
  diputus_oleh text,
  diputus_at timestamptz,
  catatan text,
  stok_opname_id uuid
);
create index if not exists opname_kasir_cabang_minggu on public.opname_kasir(cabang_id, minggu);
alter table public.opname_kasir enable row level security;
drop policy if exists opname_kasir_lihat on public.opname_kasir;
create policy opname_kasir_lihat on public.opname_kasir for select to authenticated using (public.is_admin_or_owner());
revoke all on public.opname_kasir from anon;

-- hari & jam WIB
create or replace function public.opname_wib() returns timestamp language sql stable as $$ select now() at time zone 'Asia/Jakarta' $$;

-- batas wajar per barang
create or replace function public.opname_warna(p_jenis text, p_stok numeric, p_fisik numeric) returns text
language sql immutable as $$
  select case
    when p_jenis = 'pcs' then case when abs(p_fisik - p_stok) <= 3 then 'hijau' when abs(p_fisik - p_stok) < 6 then 'kuning' else 'merah' end
    else case
      when abs(p_fisik - p_stok) <= greatest(abs(p_stok), 0) * 0.05 then 'hijau'
      when abs(p_fisik - p_stok) < greatest(abs(p_stok), 0) * 0.10 then 'kuning'
      else 'merah' end
  end $$;

-- status untuk halaman kasir
create or replace function public.kasir_opname_status(p_cabang uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare w timestamp := opname_wib(); v_jumat boolean; v_minggu date; v_aktif boolean; r record; v_ulang record;
begin
  if not (is_admin_or_owner() or user_di_cabang(p_cabang)) then raise exception 'Bukan cabang kamu' using errcode = '42501'; end if;
  v_aktif := coalesce((select opname_aktif from cabang where id = p_cabang), true);
  v_jumat := extract(isodow from w) = 5;
  v_minggu := w::date;
  select * into v_ulang from opname_kasir where cabang_id = p_cabang and status = 'hitung_ulang' order by dikirim_at desc limit 1;
  select * into r from opname_kasir where cabang_id = p_cabang and minggu = v_minggu and induk_id is null order by dikirim_at desc limit 1;
  return jsonb_build_object(
    'aktif', v_aktif,
    'jumat', v_jumat,
    'menu_buka', v_aktif and ((v_jumat and w::time >= time '20:30') or v_ulang.id is not null),
    'sudah_kirim', r.id is not null,
    'status', r.status,
    'wajib_sebelum_tutup_kas', v_aktif and v_jumat and r.id is null,
    'hitung_ulang', case when v_ulang.id is null then null else jsonb_build_object('id', v_ulang.id, 'barang', to_jsonb(v_ulang.barang_ulang), 'catatan', v_ulang.catatan) end);
end $$;

-- daftar barang untuk kasir (TANPA angka stok); gula disembunyikan
create or replace function public.kasir_opname_daftar(p_cabang uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_ulang uuid[];
begin
  if not (is_admin_or_owner() or user_di_cabang(p_cabang)) then raise exception 'Bukan cabang kamu' using errcode = '42501'; end if;
  select barang_ulang into v_ulang from opname_kasir where cabang_id = p_cabang and status = 'hitung_ulang' order by dikirim_at desc limit 1;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', b.id, 'nama', b.nama, 'satuan', b.satuan, 'satuan_beli', b.satuan_beli, 'konversi', b.konversi)
           order by case when b.nama ilike 'cup%' or b.nama ilike 'sedotan%' then 0 when b.nama ilike 'teh%' then 1 else 2 end, b.nama)
    from bahan_baku_stok s join bahan_baku b on b.id = s.bahan_baku_id
    where s.cabang_id = p_cabang and coalesce(b.dihitung_stok, true) and b.nama not ilike 'gula%'
      and (v_ulang is null or b.id = any(v_ulang))), '[]'::jsonb);
end $$;

-- kasir kirim hasil hitung (stok BELUM berubah)
-- p_items: [{id, fisik}] fisik dalam satuan stok (teh: ml, sudah dihitung halaman dari gram kering x konversi + ml teh jadi)
create or replace function public.kasir_opname_kirim(p_cabang uuid, p_items jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w timestamp := opname_wib(); v_ulang record; v_ada uuid; it jsonb; v_b record; v_stok numeric; v_items jsonb := '[]'::jsonb; v_id uuid; v_nama text; v_minggu date;
begin
  if auth.uid() is null or not (is_admin_or_owner() or user_di_cabang(p_cabang)) then raise exception 'Bukan cabang kamu' using errcode = '42501'; end if;
  if not coalesce((select opname_aktif from cabang where id = p_cabang), true) then raise exception 'Stok opname cabang ini sedang dimatikan Owner.' using errcode = '42501'; end if;
  select * into v_ulang from opname_kasir where cabang_id = p_cabang and status = 'hitung_ulang' order by dikirim_at desc limit 1;
  if v_ulang.id is null then
    if extract(isodow from w) <> 5 then raise exception 'Stok opname hanya hari Jumat.' using errcode = '22023'; end if;
    select id into v_ada from opname_kasir where cabang_id = p_cabang and minggu = w::date and induk_id is null limit 1;
    if v_ada is not null then raise exception 'Stok opname minggu ini sudah dikirim.' using errcode = '22023'; end if;
    v_minggu := w::date;
  else
    v_minggu := v_ulang.minggu;
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then raise exception 'Belum ada barang yang diisi.' using errcode = '22023'; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    if (it->>'fisik') is null or (it->>'fisik')::numeric < 0 then raise exception 'Jumlah tidak valid.' using errcode = '22023'; end if;
    select b.id, b.nama, b.satuan into v_b from bahan_baku b where b.id = (it->>'id')::uuid and coalesce(b.dihitung_stok, true);
    if v_b.id is null then continue; end if;
    if v_ulang.id is not null and not (v_b.id = any(v_ulang.barang_ulang)) then continue; end if;
    select stok into v_stok from bahan_baku_stok where bahan_baku_id = v_b.id and cabang_id = p_cabang;
    if v_stok is null then continue; end if;
    v_items := v_items || jsonb_build_object('bahan_baku_id', v_b.id, 'nama', v_b.nama, 'satuan', v_b.satuan,
      'jenis', case when v_b.satuan = 'pcs' then 'pcs' else 'takar' end,
      'fisik', round((it->>'fisik')::numeric, 2), 'stok_saat_kirim', v_stok);
  end loop;
  if jsonb_array_length(v_items) = 0 then raise exception 'Belum ada barang yang diisi.' using errcode = '22023'; end if;
  if v_ulang.id is null then
    -- putaran pertama wajib lengkap (semua barang di daftar)
    if jsonb_array_length(v_items) < jsonb_array_length(kasir_opname_daftar(p_cabang)) then
      raise exception 'Semua barang wajib diisi (isi 0 kalau habis).' using errcode = '22023';
    end if;
  end if;
  select nama into v_nama from users where id = auth.uid();
  insert into opname_kasir(cabang_id, minggu, induk_id, dikirim_oleh, nama_oleh, items)
  values (p_cabang, v_minggu, v_ulang.id, auth.uid(), v_nama, v_items) returning id into v_id;
  if v_ulang.id is not null then
    update opname_kasir set status = 'menunggu' where id = v_ulang.id; -- induk kembali menunggu bersama hasil ulang
  end if;
  insert into log_aktivitas(cabang_id, user_id, aksi, keterangan)
  values (p_cabang, auth.uid(), 'Stok Opname Kasir', format('%s barang dikirim%s, menunggu cek MeyAdmin', jsonb_array_length(v_items), case when v_ulang.id is not null then ' (hitung ulang)' else '' end));
  return jsonb_build_object('id', v_id, 'jumlah', jsonb_array_length(v_items));
end $$;

-- gabungan hasil: putaran pertama ditimpa hasil hitung ulang (barang yang sama)
create or replace function public.opname_kasir_gabungan(p_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  with akar as (select coalesce(induk_id, id) id from opname_kasir where id = p_id),
  semua as (
    select o.dikirim_at, it from opname_kasir o, akar, jsonb_array_elements(o.items) it
    where o.id = akar.id or o.induk_id = akar.id),
  terbaru as (select distinct on (it->>'bahan_baku_id') it from semua order by it->>'bahan_baku_id', dikirim_at desc)
  select coalesce(jsonb_agg(it || jsonb_build_object(
      'stok_sekarang', s.stok,
      'selisih', (it->>'fisik')::numeric - (it->>'stok_saat_kirim')::numeric,
      'batas', case when it->>'jenis' = 'pcs' then 3 else round(abs((it->>'stok_saat_kirim')::numeric) * 0.05, 2) end,
      'warna', opname_warna(it->>'jenis', (it->>'stok_saat_kirim')::numeric, (it->>'fisik')::numeric)) order by it->>'nama'), '[]'::jsonb)
  from terbaru join akar on true
  left join bahan_baku_stok s on s.bahan_baku_id = (it->>'bahan_baku_id')::uuid and s.cabang_id = (select cabang_id from opname_kasir where id = akar.id) $$;

-- MeyAdmin: ambil SO yang menunggu keputusan (berkunci token)
create or replace function public.meyadmin_opname_ambil(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if way1_cadangan_cek_kunci(p_token) is null then return jsonb_build_object('galat', 'kunci salah'); end if;
  return jsonb_build_object('waktu_wib', opname_wib(), 'menunggu', coalesce((
    select jsonb_agg(x order by x->>'dikirim_at') from (
      select jsonb_build_object('id', o.id, 'cabang_id', o.cabang_id, 'cabang', c.nama, 'minggu', o.minggu,
        'dikirim_oleh', o.nama_oleh, 'dikirim_at', o.dikirim_at at time zone 'Asia/Jakarta',
        'sudah_hitung_ulang', exists(select 1 from opname_kasir u where u.induk_id = o.id),
        'barang', g.b,
        'warna', case when exists(select 1 from jsonb_array_elements(g.b) e where e->>'warna'='merah') then 'merah'
                      when exists(select 1 from jsonb_array_elements(g.b) e where e->>'warna'='kuning') then 'kuning' else 'hijau' end) x
      from opname_kasir o join cabang c on c.id = o.cabang_id, lateral (select opname_kasir_gabungan(o.id) b) g
      where o.status = 'menunggu' and o.induk_id is null) q), '[]'::jsonb),
    'belum_kirim', coalesce((
      select jsonb_agg(jsonb_build_object('cabang_id', c.id, 'cabang', c.nama)) from cabang c
      where extract(isodow from opname_wib()) = 5 and coalesce(c.opname_aktif, true)
        and not exists(select 1 from opname_kasir o where o.cabang_id = c.id and o.minggu = opname_wib()::date and o.induk_id is null)), '[]'::jsonb),
    'hitung_ulang', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'cabang_id', cabang_id, 'barang', barang_ulang, 'sejak', diputus_at at time zone 'Asia/Jakarta'))
      from opname_kasir where status = 'hitung_ulang'), '[]'::jsonb));
end $$;

-- MeyAdmin / Owner: putuskan. p_keputusan: 'setujui' | 'tolak' | 'hitung_ulang' (p_barang wajib, hanya sekali)
create or replace function public.meyadmin_opname_putuskan(p_token text, p_id uuid, p_keputusan text, p_catatan text default null, p_barang uuid[] default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o record; g jsonb; e jsonb; v_det jsonb := '[]'::jsonb; v_sel int := 0; v_soid uuid; v_oleh text; v_lama numeric;
begin
  if way1_cadangan_cek_kunci(p_token) is not null then v_oleh := 'MeyAdmin';
  elsif auth.uid() is not null and is_owner() then v_oleh := 'Owner';
  else return jsonb_build_object('galat', 'kunci salah'); end if;
  select * into o from opname_kasir where id = p_id for update;
  if o.id is null then return jsonb_build_object('galat', 'SO tidak ditemukan'); end if;
  if o.induk_id is not null then select * into o from opname_kasir where id = o.induk_id for update; end if;
  if o.status <> 'menunggu' then return jsonb_build_object('galat', 'SO ini sudah ' || o.status); end if;
  if p_keputusan = 'hitung_ulang' then
    if exists(select 1 from opname_kasir where induk_id = o.id) then return jsonb_build_object('galat', 'hitung ulang hanya boleh sekali'); end if;
    if p_barang is null or array_length(p_barang, 1) is null then return jsonb_build_object('galat', 'pilih barang yang dihitung ulang'); end if;
    update opname_kasir set status = 'hitung_ulang', barang_ulang = p_barang, catatan = p_catatan, diputus_oleh = v_oleh, diputus_at = now() where id = o.id;
    insert into log_aktivitas(cabang_id, user_id, aksi, keterangan) values (o.cabang_id, null, 'Stok Opname Kasir', format('%s minta hitung ulang %s barang', v_oleh, array_length(p_barang,1)));
    return jsonb_build_object('ok', true, 'status', 'hitung_ulang');
  elsif p_keputusan = 'tolak' then
    update opname_kasir set status = 'ditolak', catatan = p_catatan, diputus_oleh = v_oleh, diputus_at = now() where id = o.id or induk_id = o.id;
    insert into log_aktivitas(cabang_id, user_id, aksi, keterangan) values (o.cabang_id, null, 'Stok Opname Kasir', format('SO ditolak %s, stok aplikasi tidak diubah. %s', v_oleh, coalesce(p_catatan,'')));
    return jsonb_build_object('ok', true, 'status', 'ditolak');
  elsif p_keputusan = 'setujui' then
    g := opname_kasir_gabungan(o.id);
    for e in select * from jsonb_array_elements(g) loop
      select stok into v_lama from bahan_baku_stok where bahan_baku_id = (e->>'bahan_baku_id')::uuid and cabang_id = o.cabang_id for update;
      if v_lama is null then continue; end if;
      update bahan_baku_stok set stok = round(v_lama + (e->>'selisih')::numeric, 2) where bahan_baku_id = (e->>'bahan_baku_id')::uuid and cabang_id = o.cabang_id;
      if (e->>'selisih')::numeric <> 0 then v_sel := v_sel + 1; end if;
      v_det := v_det || jsonb_build_object('bahan_baku_id', e->>'bahan_baku_id', 'nama', e->>'nama', 'satuan', e->>'satuan',
        'sebelum', v_lama, 'sesudah', round(v_lama + (e->>'selisih')::numeric, 2), 'selisih', (e->>'selisih')::numeric, 'warna', e->>'warna');
    end loop;
    insert into stok_opname(cabang_id, nama_oleh, detail, jumlah_selisih)
    values (o.cabang_id, coalesce(o.nama_oleh,'Kasir') || ' · disetujui ' || v_oleh, v_det, v_sel) returning id into v_soid;
    update opname_kasir set status = 'disetujui', catatan = p_catatan, diputus_oleh = v_oleh, diputus_at = now(), stok_opname_id = v_soid where id = o.id or induk_id = o.id;
    insert into log_aktivitas(cabang_id, user_id, aksi, keterangan) values (o.cabang_id, null, 'Stok Opname', format('SO kasir disetujui %s: %s barang, %s selisih. %s', v_oleh, jsonb_array_length(v_det), v_sel, coalesce(p_catatan,'')));
    return jsonb_build_object('ok', true, 'status', 'disetujui', 'detail', v_det);
  end if;
  return jsonb_build_object('galat', 'keputusan tidak dikenal');
end $$;

revoke all on function public.opname_kasir_gabungan(uuid) from public, anon, authenticated;
revoke all on function public.opname_warna(text, numeric, numeric) from anon;
revoke all on function public.kasir_opname_status(uuid) from public, anon;
revoke all on function public.kasir_opname_daftar(uuid) from public, anon;
revoke all on function public.kasir_opname_kirim(uuid, jsonb) from public, anon;
grant execute on function public.kasir_opname_status(uuid), public.kasir_opname_daftar(uuid), public.kasir_opname_kirim(uuid, jsonb) to authenticated;
-- fungsi meyadmin dipanggil dari HP (kunci anon + token), sama seperti way1_paket_ambil
grant execute on function public.meyadmin_opname_ambil(text), public.meyadmin_opname_putuskan(text, uuid, text, text, uuid[]) to anon, authenticated;

-- revisi: belum_kirim hanya cabang yang ada transaksi 7 hari terakhir (lihat migrasi meyadmin_opname_ambil_cabang_aktif)
