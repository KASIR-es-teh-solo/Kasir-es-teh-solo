-- 2026-11-23 Fungsi admin resmi untuk MeyAdmin (bot WhatsApp) — permintaan Boss Leo.
-- Semua fungsi: wajib login Owner/Admin (MeyAdmin memakai sesi Owner), tidak bisa membuat angka dobel,
-- menyimpan nilai lama di log_aktivitas (aksi diawali "Admin:"), dan tidak menghapus data.

-- ---------- bantu: harga produk per ukuran ----------
create or replace function public.admin_harga_produk(p_produk uuid, p_ukuran text) returns numeric
language sql stable security definer set search_path = public as $$
  select case
    when p.tipe_harga = 'kecil_besar' and lower(p_ukuran) = 'kecil' then p.harga_kecil
    when p.tipe_harga = 'kecil_besar' and lower(p_ukuran) = 'besar' then p.harga_besar
    else (select v.harga from produk_varian v where v.produk_id = p.id and lower(v.kode) = lower(replace(p_ukuran,' ','')) limit 1)
  end
  from produk p where p.id = p_produk $$;
revoke all on function public.admin_harga_produk(uuid, text) from public, anon;
grant execute on function public.admin_harga_produk(uuid, text) to authenticated;

-- ---------- 1. ringkasan harian (baca saja) ----------
create or replace function public.admin_ringkasan(p_cabang uuid, p_tanggal date default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d date := coalesce(p_tanggal, (now() at time zone 'Asia/Jakarta')::date);
        a timestamptz := (d::timestamp at time zone 'Asia/Jakarta'); b timestamptz := ((d + 1)::timestamp at time zone 'Asia/Jakarta');
begin
  if not public.is_admin_or_owner() then raise exception 'Khusus Owner/Admin'; end if;
  return jsonb_build_object(
    'tanggal', d,
    'penjualan', coalesce((select jsonb_agg(jsonb_build_object('metode', metode_bayar, 'platform', platform, 'transaksi', n, 'rupiah', rp))
        from (select metode_bayar, platform, count(*) n, sum(total) rp from transaksi
              where cabang_id = p_cabang and status = 'selesai' and created_at >= a and created_at < b group by 1,2) x), '[]'::jsonb),
    'dibatalkan', (select count(*) from transaksi where cabang_id = p_cabang and status = 'dibatalkan' and created_at >= a and created_at < b),
    'belanja', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'jam', to_char(created_at at time zone 'Asia/Jakarta','HH24:MI'), 'kategori', kategori,
        'keterangan', deskripsi, 'rupiah', jumlah, 'sumber', sumber_dana) order by created_at)
        from biaya_operasional where cabang_id = p_cabang and created_at >= a and created_at < b), '[]'::jsonb),
    'beli_stok', coalesce((select jsonb_agg(jsonb_build_object('jam', to_char(p.created_at at time zone 'Asia/Jakarta','HH24:MI'), 'bahan', bb.nama,
        'jumlah', p.jumlah, 'rupiah', p.total, 'sumber', p.sumber_dana) order by p.created_at)
        from pembelian p join bahan_baku bb on bb.id = p.bahan_baku_id where p.cabang_id = p_cabang and p.created_at >= a and p.created_at < b), '[]'::jsonb),
    'tutup_kas', (select jsonb_build_object('jam', to_char(waktu_tutup at time zone 'Asia/Jakarta','HH24:MI'), 'seharusnya', kas_sistem, 'fisik', kas_fisik, 'selisih', selisih, 'catatan', catatan)
        from kas_shift where cabang_id = p_cabang and waktu_tutup >= a and waktu_tutup < b order by waktu_tutup desc limit 1),
    'kas_outlet_sekarang', public.kas_outlet_saldo(p_cabang),
    'dana_amplop', public.dana_saldo(p_cabang),
    'dana_belum_pindah', public.dana_belum_pindah(p_cabang),
    'gaji_owner', case when public.is_owner() then public.gaji_owner_status() end,
    'stok_menipis', coalesce((select jsonb_agg(jsonb_build_object('bahan', b2.nama, 'stok', s.stok, 'satuan', b2.satuan) order by b2.nama)
        from bahan_baku_stok s join bahan_baku b2 on b2.id = s.bahan_baku_id
        where s.cabang_id = p_cabang and coalesce(b2.dihitung_stok, true)
          and ((b2.satuan = 'pcs' and s.stok < 30) or (b2.satuan = 'gram' and s.stok < 150) or (b2.satuan = 'ml' and s.stok < 20000))), '[]'::jsonb));
end $$;

-- ---------- 2. cari transaksi (baca saja) ----------
create or replace function public.admin_cari_transaksi(p_cabang uuid, p_tanggal date default null, p_jam_dari text default null, p_jam_sampai text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d date := coalesce(p_tanggal, (now() at time zone 'Asia/Jakarta')::date);
        a timestamptz := ((d + coalesce(p_jam_dari,'00:00')::time)::timestamp at time zone 'Asia/Jakarta');
        b timestamptz := ((d + coalesce(p_jam_sampai,'23:59:59')::time)::timestamp at time zone 'Asia/Jakarta');
begin
  if not public.is_admin_or_owner() then raise exception 'Khusus Owner/Admin'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'jam', to_char(t.created_at at time zone 'Asia/Jakarta','HH24:MI:SS'),
      'metode', t.metode_bayar, 'platform', t.platform, 'total', t.total, 'status', t.status, 'kasir', u.nama,
      'item', (select jsonb_agg(jsonb_build_object('menu', p.nama, 'ukuran', ti.ukuran, 'qty', ti.qty, 'harga', ti.harga_satuan))
               from transaksi_item ti join produk p on p.id = ti.produk_id where ti.transaksi_id = t.id)) order by t.created_at)
    from transaksi t left join users u on u.id = t.kasir_id
    where t.cabang_id = p_cabang and t.created_at between a and b), '[]'::jsonb);
end $$;

-- ---------- 3. ubah cara bayar transaksi ----------
create or replace function public.admin_transaksi_ubah_bayar(p_id uuid, p_metode text, p_platform text default null, p_alasan text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t record;
begin
  if not public.is_admin_or_owner() then raise exception 'Khusus Owner/Admin'; end if;
  if p_metode not in ('tunai','online') then raise exception 'Cara bayar hanya tunai atau online'; end if;
  if p_metode = 'online' and coalesce(p_platform,'') not in ('grab','shopee') then raise exception 'Online wajib platform grab atau shopee'; end if;
  select * into t from transaksi where id = p_id for update;
  if t.id is null then raise exception 'Transaksi tidak ditemukan'; end if;
  if t.status <> 'selesai' then raise exception 'Transaksi sudah %', t.status; end if;
  if t.metode_bayar = p_metode and coalesce(t.platform,'') = coalesce(case when p_metode='online' then p_platform end,'') then
    return jsonb_build_object('ok', true, 'catatan', 'sudah sama, tidak diubah');
  end if;
  update transaksi set metode_bayar = p_metode, platform = case when p_metode = 'online' then p_platform end where id = p_id;
  insert into log_aktivitas(cabang_id, user_id, aksi, keterangan)
  values (t.cabang_id, auth.uid(), 'Admin: ubah cara bayar', format('Transaksi %s (Rp%s) %s%s -> %s%s. %s · MeyAdmin',
    to_char(t.created_at at time zone 'Asia/Jakarta','DD Mon HH24:MI:SS'), t.total, t.metode_bayar, coalesce('/'||t.platform,''),
    p_metode, coalesce('/'||case when p_metode='online' then p_platform end,''), coalesce(p_alasan,'')));
  return jsonb_build_object('ok', true, 'kas_outlet', public.kas_outlet_saldo(t.cabang_id));
end $$;

-- ---------- 4. batalkan transaksi (stok kembali otomatis) ----------
create or replace function public.admin_transaksi_batal(p_id uuid, p_alasan text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t record;
begin
  if not public.is_admin_or_owner() then raise exception 'Khusus Owner/Admin'; end if;
  if nullif(btrim(coalesce(p_alasan,'')),'') is null then raise exception 'Alasan batal wajib diisi'; end if;
  select * into t from transaksi where id = p_id for update;
  if t.id is null then raise exception 'Transaksi tidak ditemukan'; end if;
  if t.status <> 'selesai' then raise exception 'Transaksi sudah %', t.status; end if;
  update transaksi set status = 'dibatalkan', alasan_batal = btrim(p_alasan) || ' · MeyAdmin' where id = p_id;
  insert into log_aktivitas(cabang_id, user_id, aksi, keterangan)
  values (t.cabang_id, auth.uid(), 'Admin: batal transaksi', format('Transaksi %s %s Rp%s dibatalkan: %s · MeyAdmin',
    to_char(t.created_at at time zone 'Asia/Jakarta','DD Mon HH24:MI:SS'), t.metode_bayar, t.total, p_alasan));
  return jsonb_build_object('ok', true, 'kas_outlet', public.kas_outlet_saldo(t.cabang_id));
end $$;

-- ---------- 5. transaksi susulan (lupa input) ----------
-- p_items: [{"produk_id":"…","ukuran":"besar","qty":2}]; harga diambil dari menu (bisa ditimpa "harga").
create or replace function public.admin_transaksi_susulan(p_cabang uuid, p_items jsonb, p_metode text default 'tunai', p_platform text default null,
  p_waktu timestamptz default null, p_catatan text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare it jsonb; v_harga numeric; v_total numeric := 0; v_id uuid; v_items jsonb := '[]'::jsonb; v_kasir uuid; v_ringkas text := '';
begin
  if not public.is_admin_or_owner() then raise exception 'Khusus Owner/Admin'; end if;
  if p_metode not in ('tunai','online') then raise exception 'Cara bayar hanya tunai atau online'; end if;
  if p_metode = 'online' and coalesce(p_platform,'') not in ('grab','shopee') then raise exception 'Online wajib platform grab atau shopee'; end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then raise exception 'Item kosong'; end if;
  if p_waktu is not null and (p_waktu > now() or p_waktu < now() - interval '7 days') then raise exception 'Waktu susulan maksimal 7 hari ke belakang'; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    if not exists (select 1 from produk where id = (it->>'produk_id')::uuid and cabang_id = p_cabang and aktif) then raise exception 'Menu tidak ditemukan / tidak aktif di cabang ini'; end if;
    if coalesce((it->>'qty')::int, 0) <= 0 then raise exception 'Qty harus lebih dari 0'; end if;
    v_harga := coalesce((it->>'harga')::numeric, public.admin_harga_produk((it->>'produk_id')::uuid, it->>'ukuran'));
    if v_harga is null then raise exception 'Harga menu/ukuran tidak ketemu: %', it->>'ukuran'; end if;
    v_total := v_total + v_harga * (it->>'qty')::int;
    v_items := v_items || jsonb_build_object('produk_id', it->>'produk_id', 'ukuran', it->>'ukuran', 'qty', (it->>'qty')::int, 'harga', v_harga);
    v_ringkas := v_ringkas || (select nama from produk where id = (it->>'produk_id')::uuid) || ' ' || coalesce(it->>'ukuran','') || ' x' || (it->>'qty') || '; ';
  end loop;
  select u.id into v_kasir from users u where u.role = 'kasir' and (u.cabang_id = p_cabang or exists(select 1 from user_cabang uc where uc.user_id = u.id and uc.cabang_id = p_cabang)) order by u.created_at limit 1;
  insert into transaksi(kasir_id, total, subtotal, diskon, metode_bayar, platform, status, cabang_id, client_tx_id, created_at)
  values (coalesce(v_kasir, auth.uid()), v_total, v_total, 0, p_metode, case when p_metode='online' then p_platform end, 'selesai', p_cabang,
          'susulan-meyadmin-' || gen_random_uuid(), coalesce(p_waktu, now()))
  returning id into v_id;
  insert into transaksi_item(transaksi_id, produk_id, ukuran, harga_satuan, qty, subtotal)
  select v_id, (x->>'produk_id')::uuid, x->>'ukuran', (x->>'harga')::numeric, (x->>'qty')::int, (x->>'harga')::numeric * (x->>'qty')::int
  from jsonb_array_elements(v_items) x;
  insert into log_aktivitas(cabang_id, user_id, aksi, keterangan)
  values (p_cabang, auth.uid(), 'Admin: transaksi susulan', format('Susulan %s Rp%s: %s%s · MeyAdmin', p_metode || coalesce('/'||p_platform,''), v_total, v_ringkas, coalesce(p_catatan,'')));
  return jsonb_build_object('ok', true, 'id', v_id, 'total', v_total, 'kas_outlet', public.kas_outlet_saldo(p_cabang));
end $$;

-- ---------- 6. koreksi stok bahan (selain SO) ----------
create or replace function public.admin_stok_koreksi(p_cabang uuid, p_bahan uuid, p_stok_baru numeric, p_alasan text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_lama numeric; v_nama text; v_sat text;
begin
  if not public.is_admin_or_owner() then raise exception 'Khusus Owner/Admin'; end if;
  if p_stok_baru is null or p_stok_baru < 0 then raise exception 'Stok baru tidak boleh minus'; end if;
  if nullif(btrim(coalesce(p_alasan,'')),'') is null then raise exception 'Alasan wajib diisi'; end if;
  select b.nama, b.satuan into v_nama, v_sat from bahan_baku b where b.id = p_bahan;
  select stok into v_lama from bahan_baku_stok where bahan_baku_id = p_bahan and cabang_id = p_cabang for update;
  if v_lama is null then raise exception 'Bahan tidak ada di cabang ini'; end if;
  update bahan_baku_stok set stok = p_stok_baru where bahan_baku_id = p_bahan and cabang_id = p_cabang;
  insert into log_aktivitas(cabang_id, user_id, aksi, keterangan)
  values (p_cabang, auth.uid(), 'Admin: koreksi stok', format('%s %s -> %s %s (nilai lama disimpan). %s · MeyAdmin', v_nama, trim_scale(v_lama), trim_scale(p_stok_baru), v_sat, p_alasan));
  return jsonb_build_object('ok', true, 'bahan', v_nama, 'lama', v_lama, 'baru', p_stok_baru);
end $$;

-- ---------- 7. rapikan kategori/keterangan belanja (jumlah & sumber dana tidak berubah) ----------
create or replace function public.admin_biaya_rapikan(p_id uuid, p_kategori text, p_keterangan text default null, p_alasan text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b record;
begin
  if not public.is_admin_or_owner() then raise exception 'Khusus Owner/Admin'; end if;
  if p_kategori not in ('Es Batu','Air Galon','Gas','Kresek','Kebersihan','Lemon','Bayar Hutang Bahan','Langganan Aplikasi','Lainnya','Gaji Owner') then
    raise exception 'Kategori tidak dikenal';
  end if;
  select * into b from biaya_operasional where id = p_id for update;
  if b.id is null then raise exception 'Belanja tidak ditemukan'; end if;
  if p_kategori = 'Gaji Owner' and b.jumlah <> coalesce((select gaji_owner from kaleng_pengaturan where id = 1), 300000) then
    raise exception 'Jumlah tidak sama dengan Gaji Owner';
  end if;
  update biaya_operasional set kategori = p_kategori, deskripsi = coalesce(nullif(btrim(p_keterangan),''), deskripsi) where id = p_id;
  insert into log_aktivitas(cabang_id, user_id, aksi, keterangan)
  values (b.cabang_id, auth.uid(), 'Admin: rapikan belanja', format('Belanja %s Rp%s: "%s" (%s) -> "%s" (%s). Jumlah & sumber dana tetap. %s · MeyAdmin',
    to_char(b.created_at at time zone 'Asia/Jakarta','DD Mon HH24:MI'), b.jumlah, coalesce(b.deskripsi,''), b.kategori,
    coalesce(nullif(btrim(p_keterangan),''), b.deskripsi), p_kategori, coalesce(p_alasan,'')));
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.admin_ringkasan(uuid, date), public.admin_cari_transaksi(uuid, date, text, text),
  public.admin_transaksi_ubah_bayar(uuid, text, text, text), public.admin_transaksi_batal(uuid, text),
  public.admin_transaksi_susulan(uuid, jsonb, text, text, timestamptz, text), public.admin_stok_koreksi(uuid, uuid, numeric, text),
  public.admin_biaya_rapikan(uuid, text, text, text) from public, anon;
grant execute on function public.admin_ringkasan(uuid, date), public.admin_cari_transaksi(uuid, date, text, text),
  public.admin_transaksi_ubah_bayar(uuid, text, text, text), public.admin_transaksi_batal(uuid, text),
  public.admin_transaksi_susulan(uuid, jsonb, text, text, timestamptz, text), public.admin_stok_koreksi(uuid, uuid, numeric, text),
  public.admin_biaya_rapikan(uuid, text, text, text) to authenticated;

-- + Papan Izin #4: meyadmin_opname_ambil menambah field dikirim_terakhir (lihat migrasi Supabase "fungsi_admin_meyadmin").
