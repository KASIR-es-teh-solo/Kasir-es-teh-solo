-- 2026-10-14 · Laba Bersih & Titik Impas (khusus Owner)
-- Biaya tetap disimpan per cabang; galon & gas diambil dari belanja asli (rata-rata 30 hari);
-- kresek dihitung dari jumlah cup per transaksi.

create table if not exists public.biaya_tetap (
  cabang_id uuid primary key references public.cabang(id),
  gaji_per_jam numeric not null default 5000,
  jam_buka time not null default '07:30',
  jam_tutup time not null default '21:00',
  sewa_per_tahun numeric not null default 17000000,
  porsi_sewa_persen numeric not null default 11.6,
  listrik_per_hari numeric not null default 5000,
  kresek_1cup numeric not null default 68,
  kresek_2cup numeric not null default 46,
  kresek_3cup numeric not null default 200,
  diubah_oleh uuid,
  updated_at timestamptz not null default now()
);
alter table public.biaya_tetap enable row level security;
revoke all on public.biaya_tetap from anon, authenticated;

insert into public.biaya_tetap (cabang_id)
select id from public.cabang on conflict do nothing;

create or replace function public.biaya_tetap_simpan(
  p_cabang uuid, p_gaji_per_jam numeric, p_jam_buka time, p_jam_tutup time,
  p_sewa_per_tahun numeric, p_porsi_sewa_persen numeric, p_listrik_per_hari numeric,
  p_kresek_1cup numeric, p_kresek_2cup numeric, p_kresek_3cup numeric)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.is_owner() then raise exception 'Khusus Owner'; end if;
  if p_jam_tutup <= p_jam_buka then raise exception 'Jam tutup harus setelah jam buka'; end if;
  if least(p_gaji_per_jam,p_sewa_per_tahun,p_porsi_sewa_persen,p_listrik_per_hari,p_kresek_1cup,p_kresek_2cup,p_kresek_3cup) < 0
     or p_porsi_sewa_persen > 100 then raise exception 'Angka tidak valid'; end if;
  insert into biaya_tetap as b (cabang_id,gaji_per_jam,jam_buka,jam_tutup,sewa_per_tahun,porsi_sewa_persen,listrik_per_hari,kresek_1cup,kresek_2cup,kresek_3cup,diubah_oleh,updated_at)
  values (p_cabang,p_gaji_per_jam,p_jam_buka,p_jam_tutup,p_sewa_per_tahun,p_porsi_sewa_persen,p_listrik_per_hari,p_kresek_1cup,p_kresek_2cup,p_kresek_3cup,auth.uid(),now())
  on conflict (cabang_id) do update set gaji_per_jam=excluded.gaji_per_jam, jam_buka=excluded.jam_buka, jam_tutup=excluded.jam_tutup,
    sewa_per_tahun=excluded.sewa_per_tahun, porsi_sewa_persen=excluded.porsi_sewa_persen, listrik_per_hari=excluded.listrik_per_hari,
    kresek_1cup=excluded.kresek_1cup, kresek_2cup=excluded.kresek_2cup, kresek_3cup=excluded.kresek_3cup,
    diubah_oleh=auth.uid(), updated_at=now();
  insert into log_aktivitas (cabang_id,user_id,aksi,keterangan)
  values (p_cabang, auth.uid(), 'Ubah biaya tetap',
    format('Gaji %s/jam, buka %s–%s, sewa %s/th × %s%%, listrik %s/hari, kresek %s/%s/%s',
      p_gaji_per_jam, to_char(p_jam_buka,'HH24.MI'), to_char(p_jam_tutup,'HH24.MI'), p_sewa_per_tahun, p_porsi_sewa_persen,
      p_listrik_per_hari, p_kresek_1cup, p_kresek_2cup, p_kresek_3cup));
end $$;

create or replace function public.laba_bersih(p_cabang uuid, p_hari int)
returns json language plpgsql stable security definer set search_path to 'public' as $$
declare
  s biaya_tetap%rowtype;
  v_hari_ini date := (now() at time zone 'Asia/Jakarta')::date;
  v_dari timestamptz; v_awal30 timestamptz;
  v_omzet numeric; v_modal numeric; v_trx int; v_cup numeric; v_hari_buka int;
  v_k1 int; v_k2 int; v_k3 numeric; v_kresek numeric;
  v_galon30 numeric; v_gas30 numeric; v_hari30 int;
  v_jam numeric; v_gaji numeric; v_sewa numeric; v_listrik numeric; v_galon numeric; v_gas numeric;
  v_omzet_hari_ini numeric;
begin
  if not public.is_owner() then raise exception 'Khusus Owner'; end if;
  p_hari := greatest(1, least(coalesce(p_hari,30), 366));
  select * into s from biaya_tetap where cabang_id = p_cabang;  -- kalau belum ada, pakai angka bawaan
  v_dari := (v_hari_ini - (p_hari-1))::timestamp at time zone 'Asia/Jakarta';
  v_awal30 := (v_hari_ini - 29)::timestamp at time zone 'Asia/Jakarta';

  with t as (
    select t.id, t.total, (t.created_at at time zone 'Asia/Jakarta')::date tgl
    from transaksi t where t.cabang_id = p_cabang and t.status = 'selesai' and t.created_at >= v_dari),
  i as (
    select it.transaksi_id, it.qty,
      it.qty * coalesce(case when p.tipe_harga = 'varian'
        then (select v.harga_modal from produk_varian v where v.produk_id = p.id and v.kode = it.ukuran limit 1)
        when it.ukuran = 'besar' then p.harga_modal_besar else p.harga_modal_kecil end, 0) modal
    from transaksi_item it join t on t.id = it.transaksi_id join produk p on p.id = it.produk_id),
  per_trx as (select t.id, coalesce(sum(i.qty),0) cup from t left join i on i.transaksi_id = t.id group by t.id)
  select (select coalesce(sum(total),0) from t), (select coalesce(sum(modal),0) from i), (select count(*) from t),
         (select coalesce(sum(qty),0) from i), (select count(distinct tgl) from t),
         (select count(*) from per_trx where cup = 1), (select count(*) from per_trx where cup = 2),
         (select coalesce(sum(ceil(cup/6.0)),0) from per_trx where cup >= 3)
    into v_omzet, v_modal, v_trx, v_cup, v_hari_buka, v_k1, v_k2, v_k3;

  -- galon & gas: rata-rata belanja 30 hari terakhir (dibagi hari yang ada datanya, maks 30)
  select coalesce(sum(jumlah) filter (where kategori = 'Air Galon' or (kategori = 'Lainnya' and deskripsi ilike '%galon%')),0),
         coalesce(sum(jumlah) filter (where kategori = 'Gas'),0)
    into v_galon30, v_gas30
    from biaya_operasional where cabang_id = p_cabang and created_at >= v_awal30;
  select greatest(1, least(30, v_hari_ini - min((created_at at time zone 'Asia/Jakarta')::date) + 1))
    into v_hari30 from transaksi where cabang_id = p_cabang and status = 'selesai';
  v_hari30 := coalesce(v_hari30, 30);

  v_hari_buka := greatest(v_hari_buka, 0);
  v_jam := extract(epoch from (coalesce(s.jam_tutup,'21:00') - coalesce(s.jam_buka,'07:30'))) / 3600.0;
  v_gaji := v_jam * coalesce(s.gaji_per_jam,5000) * v_hari_buka;
  v_sewa := coalesce(s.sewa_per_tahun,17000000) * coalesce(s.porsi_sewa_persen,11.6) / 100.0 / 365.0 * least(p_hari, v_hari30);
  v_listrik := coalesce(s.listrik_per_hari,5000) * v_hari_buka;
  v_galon := v_galon30 / v_hari30 * v_hari_buka;
  v_gas := v_gas30 / v_hari30 * v_hari_buka;
  v_kresek := v_k1 * coalesce(s.kresek_1cup,68) + v_k2 * coalesce(s.kresek_2cup,46) + v_k3 * coalesce(s.kresek_3cup,200);

  select coalesce(sum(total),0) into v_omzet_hari_ini from transaksi
   where cabang_id = p_cabang and status = 'selesai' and created_at >= v_hari_ini::timestamp at time zone 'Asia/Jakarta';

  return json_build_object(
    'hari', p_hari, 'hari_buka', v_hari_buka, 'jam_buka_per_hari', v_jam,
    'omzet', v_omzet, 'modal', round(v_modal), 'trx', v_trx, 'cup', v_cup,
    'gaji', round(v_gaji), 'sewa', round(v_sewa), 'listrik', round(v_listrik),
    'galon', round(v_galon), 'gas', round(v_gas), 'kresek', round(v_kresek),
    'kresek_lembar', json_build_object('k1', v_k1, 'k2', v_k2, 'k3', v_k3),
    'omzet_hari_ini', v_omzet_hari_ini,
    -- biaya per hari buka (untuk titik impas)
    'biaya_tetap_per_hari', round(v_jam * coalesce(s.gaji_per_jam,5000)
        + coalesce(s.sewa_per_tahun,17000000) * coalesce(s.porsi_sewa_persen,11.6) / 100.0 / 365.0
        + coalesce(s.listrik_per_hari,5000) + (v_galon30 + v_gas30) / v_hari30
        + case when v_hari_buka > 0 then v_kresek / v_hari_buka else 0 end),
    'pengaturan', json_build_object(
        'gaji_per_jam', coalesce(s.gaji_per_jam,5000), 'jam_buka', to_char(coalesce(s.jam_buka,'07:30'),'HH24:MI'),
        'jam_tutup', to_char(coalesce(s.jam_tutup,'21:00'),'HH24:MI'), 'sewa_per_tahun', coalesce(s.sewa_per_tahun,17000000),
        'porsi_sewa_persen', coalesce(s.porsi_sewa_persen,11.6), 'listrik_per_hari', coalesce(s.listrik_per_hari,5000),
        'kresek_1cup', coalesce(s.kresek_1cup,68), 'kresek_2cup', coalesce(s.kresek_2cup,46), 'kresek_3cup', coalesce(s.kresek_3cup,200),
        'galon_per_hari', round(v_galon30 / v_hari30), 'gas_per_hari', round(v_gas30 / v_hari30))
  );
end $$;

revoke all on function public.laba_bersih(uuid,int) from public, anon;
revoke all on function public.biaya_tetap_simpan(uuid,numeric,time,time,numeric,numeric,numeric,numeric,numeric,numeric) from public, anon;
grant execute on function public.laba_bersih(uuid,int) to authenticated;
grant execute on function public.biaya_tetap_simpan(uuid,numeric,time,time,numeric,numeric,numeric,numeric,numeric,numeric) to authenticated;
