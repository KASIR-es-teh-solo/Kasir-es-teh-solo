-- 2026-11-22 Perbaikan tutup kas: uang yang masuk/keluar lewat tabel kas_toko (suntik modal Owner, dari Brankas,
-- beli stok / biaya "Kas Outlet") hanya dihitung SEKALI, di tutup kas pertama sesudahnya.
-- Penyebab bug 21 Nov: saldo kas_toko (seluruh riwayat) ditambahkan ke Kas Awal di SETIAP tutup kas dan tidak pernah
-- di-nol-kan, sehingga suntikan modal terhitung lagi di tutup kas berikutnya (selisih palsu).
-- Perbaikan: kas_tutup_v2 menyerap saldo kas_toko ke Kas Outlet (baris koreksi bertanda kas_shift_id) setiap tutup kas,
-- persis pola 22 Okt. Uang fisik yang dihitung kasir sudah termasuk uang itu, jadi kas_ditinggal tetap jadi patokan hari berikutnya.

alter table public.kas_toko drop constraint if exists kas_toko_sumber_check;
alter table public.kas_toko add constraint kas_toko_sumber_check
  check (sumber = any (array['setoran_tutup_kas','ke_brankas','dari_brankas','koreksi','suntik_modal']));

create or replace function public.kas_toko_saldo_mentah(p_cabang uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce((select sum(case when jenis='masuk' then jumlah else -jumlah end) from kas_toko where cabang_id=p_cabang),0)
       - coalesce((select sum(total) from pembelian where cabang_id=p_cabang and sumber_dana='kas_toko'),0)
       - coalesce((select sum(jumlah) from biaya_operasional where cabang_id=p_cabang and sumber_dana='kas_toko'),0) $$;
revoke all on function public.kas_toko_saldo_mentah(uuid) from public, anon, authenticated;

create or replace function public.kas_tutup_v2(p_cabang uuid, p_kas_awal numeric, p_kas_sistem numeric, p_kas_fisik numeric, p_total_biaya numeric, p_catatan text, p_waktu_buka timestamptz)
returns json language plpgsql security definer set search_path = public as $$
declare v_role text; v_id uuid; v_dana jsonb; v_ds numeric := 0; v_do numeric := 0; v_kt numeric;
begin
  select role into v_role from users where id = auth.uid();
  if v_role is null or v_role not in ('kasir', 'admin', 'owner') then raise exception 'Tidak punya akses tutup kas'; end if;
  if v_role <> 'owner' and not public.user_di_cabang(p_cabang) then raise exception 'Bukan cabang kamu'; end if;
  if p_kas_fisik is null or p_kas_fisik < 0 then raise exception 'Jumlah uang Kas Outlet tidak valid'; end if;
  if p_kas_fisik <> p_kas_sistem and nullif(trim(coalesce(p_catatan, '')), '') is null then
    raise exception 'Kas tidak pas, isi alasannya dulu';
  end if;
  v_dana := public.dana_hitung_sisih(p_cabang, null);
  v_ds := coalesce((v_dana->>'stok')::numeric, 0);
  v_do := coalesce((v_dana->>'operasional')::numeric, 0);
  insert into kas_shift(cabang_id, dibuka_oleh, ditutup_oleh, kas_awal, status, kas_sistem, kas_fisik, selisih, total_biaya,
                        catatan, waktu_buka, waktu_tutup, setoran, kas_ditinggal)
  values (p_cabang, auth.uid(), auth.uid(), p_kas_awal, 'selesai', p_kas_sistem, p_kas_fisik, p_kas_fisik - p_kas_sistem,
          p_total_biaya, nullif(trim(coalesce(p_catatan, '')), ''), p_waktu_buka, now(), 0, p_kas_fisik)
  returning id into v_id;
  if v_ds > 0 then insert into dana_tagih(cabang_id, pos, jumlah, rincian, kas_shift_id) values (p_cabang, 'stok', v_ds, v_dana->'rincian', v_id); end if;
  if v_do > 0 then insert into dana_tagih(cabang_id, pos, jumlah, rincian, kas_shift_id) values (p_cabang, 'operasional', v_do, v_dana->'rincian', v_id); end if;
  -- serap saldo kas_toko: sudah ikut terhitung di Kas Awal tutup kas ini dan sudah ada di uang fisik
  v_kt := public.kas_toko_saldo_mentah(p_cabang);
  if v_kt <> 0 then
    insert into kas_toko(cabang_id, jenis, sumber, jumlah, keterangan, dicatat_oleh, kas_shift_id)
    values (p_cabang, case when v_kt > 0 then 'keluar' else 'masuk' end, 'koreksi', abs(v_kt),
            'Digabung ke Kas Outlet saat tutup kas', auth.uid(), v_id);
  end if;
  return json_build_object('id', v_id, 'kas_ditinggal', p_kas_fisik, 'tagih_stok', v_ds, 'tagih_operasional', v_do, 'kas_toko_digabung', coalesce(v_kt, 0));
end $$;

-- cara resmi Owner menambah uang pribadi (suntik modal) ke Kas Outlet; ikut dihitung sekali di tutup kas berikutnya
create or replace function public.kas_outlet_suntik(p_cabang uuid, p_jumlah numeric, p_keterangan text default null)
returns json language plpgsql security definer set search_path = public as $$
declare rp text;
begin
  if not public.is_owner() then raise exception 'Khusus Owner'; end if;
  if p_jumlah is null or p_jumlah <= 0 then raise exception 'Jumlah harus lebih dari 0'; end if;
  rp := replace(to_char(p_jumlah,'FM999,999,999'), ',', '.');
  insert into kas_toko(cabang_id, jenis, sumber, jumlah, keterangan, dicatat_oleh)
  values (p_cabang, 'masuk', 'suntik_modal', p_jumlah, coalesce(nullif(btrim(p_keterangan),''), 'Suntik modal Owner ke Kas Outlet'), auth.uid());
  insert into log_aktivitas(cabang_id, user_id, aksi, keterangan)
  values (p_cabang, auth.uid(), 'Suntik Modal Kas Outlet', 'Rp' || rp || ' uang pribadi Owner masuk Kas Outlet' || coalesce(' — ' || nullif(btrim(p_keterangan),''), ''));
  return json_build_object('ok', true, 'kas_outlet', public.kas_outlet_saldo(p_cabang));
end $$;
revoke all on function public.kas_outlet_suntik(uuid, numeric, text) from public, anon;
grant execute on function public.kas_outlet_suntik(uuid, numeric, text) to authenticated;

-- cek saldo pakai Kas Outlet utuh (bukan sisa kas_toko yang sekarang selalu 0 setelah tutup kas)
create or replace function public.kas_toko_ke_brankas(p_cabang uuid, p_jumlah numeric, p_keterangan text default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_saldo numeric; rp text;
begin
  if not public.is_admin_or_owner() then raise exception 'Khusus Owner/Admin'; end if;
  if p_jumlah is null or p_jumlah <= 0 then raise exception 'Jumlah harus lebih dari 0'; end if;
  v_saldo := public.kas_outlet_saldo(p_cabang);
  if p_jumlah > v_saldo then raise exception 'Saldo Kas Outlet cuma Rp%', replace(to_char(v_saldo,'FM999,999,999'), ',', '.'); end if;
  rp := replace(to_char(p_jumlah,'FM999,999,999'), ',', '.');
  insert into kas_toko(cabang_id, jenis, sumber, jumlah, keterangan, dicatat_oleh)
  values (p_cabang, 'keluar', 'ke_brankas', p_jumlah, coalesce(nullif(btrim(p_keterangan),''), 'Dipindah ke Brankas'), auth.uid());
  insert into brankas(cabang_id, jenis, jumlah, keterangan, dicatat_oleh, dilihat_owner, kas_shift_id)
  values (p_cabang, 'masuk', p_jumlah, 'Dari Kas Outlet' || coalesce(' — ' || nullif(btrim(p_keterangan),''), ''), auth.uid(), coalesce(public.is_owner(), false), '00000000-0000-0000-0000-000000000000');
  insert into log_aktivitas(cabang_id, user_id, aksi, keterangan)
  values (p_cabang, auth.uid(), 'Kas Outlet ke Brankas', 'Rp' || rp || ' dipindah dari Kas Outlet ke Brankas');
  return json_build_object('saldo', v_saldo - p_jumlah);
end $$;

create or replace function public.beli_stok_bahan(p_cabang uuid, p_bahan uuid, p_jumlah numeric, p_total numeric, p_sumber_dana text)
returns json language plpgsql security definer set search_path = public as $$
declare v_bahan bahan_baku%rowtype; v_id uuid; v_saldo numeric;
begin
  if auth.uid() is null or not public.is_pegawai() then raise exception 'Harus login sebagai pegawai'; end if;
  if not (public.is_admin_or_owner() or public.user_di_cabang(p_cabang)) then raise exception 'Tidak punya akses ke cabang ini'; end if;
  if p_sumber_dana not in ('tunai','non_tunai','kas_toko','dana_stok','dana_operasional') then raise exception 'Sumber uang tidak valid'; end if;
  if p_sumber_dana = 'kas_toko' and not public.is_admin_or_owner() then raise exception 'Kas Outlet khusus Owner/Admin'; end if;
  select * into v_bahan from bahan_baku where id = p_bahan;
  if not found or not coalesce(v_bahan.dihitung_stok, false) then raise exception 'Bahan ini tidak dihitung stoknya'; end if;
  if p_jumlah is null or p_jumlah <= 0 then raise exception 'Jumlah harus lebih dari 0'; end if;
  if p_total is null or p_total <= 0 then raise exception 'Total bayar harus diisi'; end if;
  if p_sumber_dana = 'kas_toko' then
    v_saldo := public.kas_outlet_saldo(p_cabang);
    if p_total > v_saldo then raise exception 'Saldo Kas Outlet cuma Rp%', replace(to_char(v_saldo,'FM999,999,999'), ',', '.'); end if;
  end if;
  if p_sumber_dana in ('dana_stok','dana_operasional') then
    v_saldo := (public.dana_saldo(p_cabang) ->> case when p_sumber_dana = 'dana_stok' then 'stok' else 'operasional' end)::numeric;
    if p_total > v_saldo then raise exception 'Saldo % cuma Rp%', case when p_sumber_dana = 'dana_stok' then 'Dana Stok' else 'Dana Operasional' end, replace(to_char(v_saldo,'FM999,999,999'), ',', '.'); end if;
  end if;
  insert into pembelian (cabang_id, bahan_baku_id, jumlah, harga_satuan, total, catatan, sumber_dana, dibeli_oleh)
  values (p_cabang, p_bahan, p_jumlah, round(p_total / p_jumlah, 4), p_total, 'dicatat lewat Beli Stok', p_sumber_dana, auth.uid())
  returning id into v_id;
  insert into log_aktivitas (cabang_id, user_id, aksi, keterangan)
  values (p_cabang, auth.uid(), 'Beli Stok',
          v_bahan.nama || ' ' || trim_scale(p_jumlah) || ' ' || coalesce(v_bahan.satuan_beli, v_bahan.satuan) || ' Rp' || trim_scale(p_total)
          || case p_sumber_dana when 'tunai' then ' (Kas Outlet)' when 'kas_toko' then ' (Kas Outlet)' when 'dana_stok' then ' (Dana Stok)' when 'dana_operasional' then ' (Dana Operasional)' else ' (uang lain)' end);
  return json_build_object('id', v_id, 'harga_satuan', round(p_total / p_jumlah, 2));
end $$;
