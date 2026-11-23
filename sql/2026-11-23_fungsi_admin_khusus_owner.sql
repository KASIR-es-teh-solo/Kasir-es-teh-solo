-- 2026-11-23 Fungsi admin KHUSUS OWNER (Boss Leo) untuk MeyAdmin: koreksi tutup kas terakhir, harga menu,
-- resep/takaran, menu aktif/nonaktif. Wajib login Owner (is_owner). Nilai lama selalu disimpan di log; tidak ada hapus data.

create or replace function public.admin_tutup_kas_koreksi(p_cabang uuid, p_kas_fisik_baru numeric, p_alasan text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare k record;
begin
  if not public.is_owner() then raise exception 'Khusus Owner'; end if;
  if p_kas_fisik_baru is null or p_kas_fisik_baru < 0 then raise exception 'Uang fisik tidak valid'; end if;
  if nullif(btrim(coalesce(p_alasan,'')),'') is null then raise exception 'Alasan wajib diisi'; end if;
  -- hanya tutup kas TERAKHIR (yang jadi kas awal berikutnya)
  select * into k from kas_shift where cabang_id = p_cabang and waktu_tutup is not null order by waktu_tutup desc limit 1 for update;
  if k.id is null then raise exception 'Belum ada tutup kas'; end if;
  update kas_shift set kas_fisik = p_kas_fisik_baru, kas_ditinggal = p_kas_fisik_baru, selisih = p_kas_fisik_baru - kas_sistem,
    catatan = coalesce(catatan,'') || format(' | Koreksi Owner %s: fisik %s -> %s. %s', to_char(now() at time zone 'Asia/Jakarta','DD Mon HH24:MI'), k.kas_fisik, p_kas_fisik_baru, p_alasan)
  where id = k.id;
  insert into log_aktivitas(cabang_id, user_id, aksi, keterangan)
  values (p_cabang, auth.uid(), 'Admin: koreksi tutup kas', format('Tutup kas %s: fisik %s -> %s, selisih %s -> %s. %s · MeyAdmin',
    to_char(k.waktu_tutup at time zone 'Asia/Jakarta','DD Mon HH24:MI'), k.kas_fisik, p_kas_fisik_baru, k.selisih, p_kas_fisik_baru - k.kas_sistem, p_alasan));
  return jsonb_build_object('ok', true, 'tutup_kas', to_char(k.waktu_tutup at time zone 'Asia/Jakarta','DD Mon HH24:MI'),
    'selisih_baru', p_kas_fisik_baru - k.kas_sistem, 'kas_outlet', public.kas_outlet_saldo(p_cabang));
end $$;

create or replace function public.admin_menu_harga(p_produk uuid, p_ukuran text, p_harga numeric, p_alasan text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p record; v_lama numeric;
begin
  if not public.is_owner() then raise exception 'Khusus Owner'; end if;
  if p_harga is null or p_harga < 0 then raise exception 'Harga tidak valid'; end if;
  select * into p from produk where id = p_produk for update;
  if p.id is null then raise exception 'Menu tidak ditemukan'; end if;
  if p.tipe_harga = 'kecil_besar' and lower(p_ukuran) = 'kecil' then
    v_lama := p.harga_kecil; update produk set harga_kecil = p_harga where id = p_produk;
  elsif p.tipe_harga = 'kecil_besar' and lower(p_ukuran) = 'besar' then
    v_lama := p.harga_besar; update produk set harga_besar = p_harga where id = p_produk;
  else
    select harga into v_lama from produk_varian where produk_id = p_produk and lower(kode) = lower(replace(p_ukuran,' ',''));
    if v_lama is null then raise exception 'Ukuran/varian tidak ditemukan: %', p_ukuran; end if;
    update produk_varian set harga = p_harga where produk_id = p_produk and lower(kode) = lower(replace(p_ukuran,' ',''));
  end if;
  insert into log_aktivitas(cabang_id, user_id, aksi, keterangan)
  values (p.cabang_id, auth.uid(), 'Admin: ubah harga menu', format('%s %s: Rp%s -> Rp%s. %s · MeyAdmin', p.nama, p_ukuran, v_lama, p_harga, coalesce(p_alasan,'')));
  return jsonb_build_object('ok', true, 'menu', p.nama, 'lama', v_lama, 'baru', p_harga);
end $$;

create or replace function public.admin_resep_atur(p_produk uuid, p_ukuran text, p_bahan uuid, p_jumlah numeric, p_alasan text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p record; b record; v_lama numeric; v_id uuid;
begin
  if not public.is_owner() then raise exception 'Khusus Owner'; end if;
  if p_jumlah is null or p_jumlah <= 0 then raise exception 'Takaran harus lebih dari 0'; end if;
  select * into p from produk where id = p_produk;
  if p.id is null then raise exception 'Menu tidak ditemukan'; end if;
  select * into b from bahan_baku where id = p_bahan;
  if b.id is null or b.cabang_id <> p.cabang_id then raise exception 'Bahan tidak ditemukan di cabang menu ini'; end if;
  select id, jumlah into v_id, v_lama from resep where produk_id = p_produk and lower(coalesce(ukuran,'')) = lower(coalesce(p_ukuran,'')) and bahan_baku_id = p_bahan limit 1;
  if v_id is null then
    insert into resep(produk_id, ukuran, bahan_baku_id, jumlah) values (p_produk, p_ukuran, p_bahan, p_jumlah);
  else
    update resep set jumlah = p_jumlah where id = v_id;
  end if;
  insert into log_aktivitas(cabang_id, user_id, aksi, keterangan)
  values (p.cabang_id, auth.uid(), 'Admin: ubah resep', format('%s %s · %s: %s -> %s %s. %s · MeyAdmin', p.nama, p_ukuran, b.nama,
    coalesce(trim_scale(v_lama)::text, 'baru'), trim_scale(p_jumlah), b.satuan, coalesce(p_alasan,'')));
  return jsonb_build_object('ok', true, 'menu', p.nama, 'bahan', b.nama, 'lama', v_lama, 'baru', p_jumlah);
end $$;

create or replace function public.admin_menu_aktif(p_produk uuid, p_aktif boolean, p_alasan text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p record;
begin
  if not public.is_owner() then raise exception 'Khusus Owner'; end if;
  select * into p from produk where id = p_produk for update;
  if p.id is null then raise exception 'Menu tidak ditemukan'; end if;
  update produk set aktif = p_aktif where id = p_produk;
  insert into log_aktivitas(cabang_id, user_id, aksi, keterangan)
  values (p.cabang_id, auth.uid(), 'Admin: menu ' || case when p_aktif then 'ditampilkan' else 'disembunyikan' end,
    format('%s %s. %s · MeyAdmin', p.nama, case when p_aktif then 'ditampilkan lagi di kasir' else 'disembunyikan dari kasir (data tetap ada)' end, coalesce(p_alasan,'')));
  return jsonb_build_object('ok', true, 'menu', p.nama, 'aktif', p_aktif);
end $$;

revoke all on function public.admin_tutup_kas_koreksi(uuid, numeric, text), public.admin_menu_harga(uuid, text, numeric, text),
  public.admin_resep_atur(uuid, text, uuid, numeric, text), public.admin_menu_aktif(uuid, boolean, text) from public, anon;
grant execute on function public.admin_tutup_kas_koreksi(uuid, numeric, text), public.admin_menu_harga(uuid, text, numeric, text),
  public.admin_resep_atur(uuid, text, uuid, numeric, text), public.admin_menu_aktif(uuid, boolean, text) to authenticated;
