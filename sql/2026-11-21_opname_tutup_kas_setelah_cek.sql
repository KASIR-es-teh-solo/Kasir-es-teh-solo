-- 2026-11-21: SO Jumat tanpa batas jam. Tutup Kas (kasir, hari Jumat) baru terbuka setelah SO dikirim DAN dicek MeyAdmin.
-- Kasir chat MeyAdmin "SO selesai" -> MeyAdmin cek -> hijau setujui / kuning hitung ulang / merah lapor_boss (kasir tetap bisa tutup kas).
-- Hari selain Jumat: tutup kas normal.

alter table public.opname_kasir add column if not exists dicek_at timestamptz;

-- status untuk halaman kasir (+ sudah_dicek; wajib_sebelum_tutup_kas sampai dicek)
create or replace function public.kasir_opname_status(p_cabang uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare w timestamp := opname_wib(); v_jumat boolean; v_minggu date; v_aktif boolean; r record; v_ulang record; v_dicek boolean := false;
begin
  if not (is_admin_or_owner() or user_di_cabang(p_cabang)) then raise exception 'Bukan cabang kamu' using errcode = '42501'; end if;
  v_aktif := coalesce((select opname_aktif from cabang where id = p_cabang), true);
  v_jumat := extract(isodow from w) = 5;
  v_minggu := w::date;
  select * into v_ulang from opname_kasir where cabang_id = p_cabang and status = 'hitung_ulang' order by dikirim_at desc limit 1;
  select * into r from opname_kasir where cabang_id = p_cabang and minggu = v_minggu and induk_id is null order by dikirim_at desc limit 1;
  if r.id is not null then
    v_dicek := r.status in ('disetujui', 'ditolak')
      or (r.status = 'menunggu' and r.dicek_at is not null
          and r.dicek_at >= (select max(dikirim_at) from opname_kasir where id = r.id or induk_id = r.id));
  end if;
  return jsonb_build_object(
    'aktif', v_aktif,
    'jumat', v_jumat,
    'menu_buka', v_aktif and ((v_jumat and w::time >= time '20:30') or v_ulang.id is not null),
    'sudah_kirim', r.id is not null,
    'sudah_dicek', v_dicek,
    'status', r.status,
    'wajib_sebelum_tutup_kas', v_aktif and v_jumat and not v_dicek,
    'hitung_ulang', case when v_ulang.id is null then null else jsonb_build_object('id', v_ulang.id, 'barang', to_jsonb(v_ulang.barang_ulang), 'catatan', v_ulang.catatan) end);
end $$;

-- keputusan MeyAdmin/Owner: + 'lapor_boss' (merah: sudah dicek, kasir boleh tutup kas, SO tetap menunggu Boss)
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
  if p_keputusan = 'lapor_boss' then
    update opname_kasir set dicek_at = now() where id = o.id;
    insert into log_aktivitas(cabang_id, user_id, aksi, keterangan) values (o.cabang_id, null, 'Stok Opname Kasir', format('%s: SO lewat batas, dilaporkan ke Owner. %s', v_oleh, coalesce(p_catatan,'')));
    return jsonb_build_object('ok', true, 'status', 'menunggu_boss');
  elsif p_keputusan = 'hitung_ulang' then
    if exists(select 1 from opname_kasir where induk_id = o.id) then return jsonb_build_object('galat', 'hitung ulang hanya boleh sekali'); end if;
    if p_barang is null or array_length(p_barang, 1) is null then return jsonb_build_object('galat', 'pilih barang yang dihitung ulang'); end if;
    update opname_kasir set status = 'hitung_ulang', barang_ulang = p_barang, catatan = p_catatan, diputus_oleh = v_oleh, diputus_at = now(), dicek_at = null where id = o.id;
    insert into log_aktivitas(cabang_id, user_id, aksi, keterangan) values (o.cabang_id, null, 'Stok Opname Kasir', format('%s minta hitung ulang %s barang', v_oleh, array_length(p_barang,1)));
    return jsonb_build_object('ok', true, 'status', 'hitung_ulang');
  elsif p_keputusan = 'tolak' then
    update opname_kasir set status = 'ditolak', catatan = p_catatan, diputus_oleh = v_oleh, diputus_at = now(), dicek_at = now() where id = o.id or induk_id = o.id;
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
    update opname_kasir set status = 'disetujui', catatan = p_catatan, diputus_oleh = v_oleh, diputus_at = now(), dicek_at = now(), stok_opname_id = v_soid where id = o.id or induk_id = o.id;
    insert into log_aktivitas(cabang_id, user_id, aksi, keterangan) values (o.cabang_id, null, 'Stok Opname', format('SO kasir disetujui %s: %s barang, %s selisih. %s', v_oleh, jsonb_array_length(v_det), v_sel, coalesce(p_catatan,'')));
    return jsonb_build_object('ok', true, 'status', 'disetujui', 'detail', v_det);
  end if;
  return jsonb_build_object('galat', 'keputusan tidak dikenal');
end $$;
