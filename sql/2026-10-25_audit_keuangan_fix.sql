-- 2026-10-25 · Perbaikan hasil audit jalur keuangan (permintaan Boss Leo: "Perbaiki semua")
-- 1+2) transaksi.masuk_at = jam transaksi benar-benar masuk server. Tutup kas & amplop menghitung pakai ini,
--      jadi penjualan sesudah tutup kas / transaksi offline yang telat terkirim ikut tutup kas berikutnya.
-- 3)   brankas tanpa cabang otomatis diisi cabangnya.
-- 4)   tutup kas terakhir tidak bisa dihapus (jadi modal awal besok).
-- 5)   stok yang dibeli pakai Kas Outlet mengurangi sisihan Dana Stok berikutnya (tidak dobel).

-- 1+2 ---------------------------------------------------------------
do $$ begin
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='transaksi' and column_name='masuk_at') then
    alter table public.transaksi add column masuk_at timestamptz;
    update public.transaksi set masuk_at = created_at where masuk_at is null;
    alter table public.transaksi alter column masuk_at set default now();
    alter table public.transaksi alter column masuk_at set not null;
  end if;
  if not exists (select 1 from pg_indexes where schemaname='public' and indexname='transaksi_cabang_masuk_at_idx') then
    create index transaksi_cabang_masuk_at_idx on public.transaksi(cabang_id, masuk_at);
  end if;
end $$;

create or replace function public.paksa_metode_tunai()
 returns trigger language plpgsql set search_path to 'public' as $function$
begin
  -- semua pembayaran di outlet dihitung tunai; kecuali pesanan online (Shopee/Grab) yang uangnya tidak masuk Kas Outlet
  if coalesce(new.metode_bayar, '') <> 'online' then
    new.metode_bayar := 'tunai';
  end if;
  -- jam masuk server tidak bisa diatur dari HP
  if tg_op = 'INSERT' then new.masuk_at := now(); else new.masuk_at := old.masuk_at; end if;
  return new;
end $function$;

-- 3 -----------------------------------------------------------------
create or replace function public.isi_cabang_brankas()
 returns trigger language plpgsql security definer set search_path to 'public' as $function$
begin
  if new.cabang_id is null then
    new.cabang_id := coalesce(
      (select cabang_id from users where id = auth.uid()),
      (select uc.cabang_id from user_cabang uc where uc.user_id = auth.uid() limit 1),
      (select cabang_id from kas_shift order by waktu_tutup desc nulls last limit 1));
  end if;
  return new;
end $function$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname='trg_isi_cabang_brankas') then
    create trigger trg_isi_cabang_brankas before insert on public.brankas for each row execute function public.isi_cabang_brankas();
  end if;
end $$;

-- 4 -----------------------------------------------------------------
create or replace function public.jaga_hapus_kas_shift()
 returns trigger language plpgsql set search_path to 'public' as $function$
begin
  if old.status = 'selesai' and not exists (
       select 1 from kas_shift k where k.cabang_id = old.cabang_id and k.id <> old.id and k.waktu_tutup > old.waktu_tutup) then
    raise exception 'Tutup kas terakhir tidak bisa dihapus, karena jadi modal awal Kas Outlet berikutnya. Minta Mey koreksi kalau ada yang salah.';
  end if;
  return old;
end $function$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname='trg_jaga_hapus_kas_shift') then
    create trigger trg_jaga_hapus_kas_shift before delete on public.kas_shift for each row execute function public.jaga_hapus_kas_shift();
  end if;
end $$;

-- 1+2+5: amplop --------------------------------------------------------
CREATE OR REPLACE FUNCTION public.dana_hitung_sisih(p_cabang uuid, p_sejak timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_sejak timestamptz; v_bahan numeric := 0; v_gas numeric := 0; v_sewa numeric := 0; v_listrik numeric := 0; v_gaji numeric := 0;
        bt biaya_tetap%rowtype; v_hari date := (now() at time zone 'Asia/Jakarta')::date; v_rinci jsonb; v_talang numeric := 0;
begin
  if not (public.is_admin_or_owner() or public.user_di_cabang(p_cabang)) then raise exception 'Bukan cabang kamu'; end if;
  v_sejak := coalesce(p_sejak, (select max(waktu_tutup) from kas_shift where cabang_id = p_cabang), now() - interval '1 day');
  with pakai as (
    select r.bahan_baku_id, sum(ti.qty * r.jumlah) jml
      from transaksi t join transaksi_item ti on ti.transaksi_id = t.id
      join resep r on r.produk_id = ti.produk_id and lower(replace(coalesce(r.ukuran,''),' ','')) = lower(replace(coalesce(ti.ukuran,''),' ',''))
      join bahan_baku b on b.id = r.bahan_baku_id and b.pos_dana = 'stok'
     where t.cabang_id = p_cabang and t.status = 'selesai' and coalesce(t.metode_bayar,'tunai') in ('tunai','online')  -- pesanan Grab/Shopee ikut (ditalangi Owner)
       and t.masuk_at > v_sejak and t.masuk_at <= now()   -- 2026-10-25: pakai jam masuk server (transaksi offline telat ikut)
     group by r.bahan_baku_id)
  select coalesce(sum(p.jml * public.harga_per_unit_bahan(p.bahan_baku_id)), 0),
         jsonb_agg(jsonb_build_object('nama', b.nama, 'jumlah', round(p.jml, 2), 'satuan', b.satuan, 'rupiah', round(p.jml * public.harga_per_unit_bahan(p.bahan_baku_id))) order by p.jml * public.harga_per_unit_bahan(p.bahan_baku_id) desc)
    into v_bahan, v_rinci
    from pakai p join bahan_baku b on b.id = p.bahan_baku_id;
  select * into bt from biaya_tetap where cabang_id = p_cabang;
  if not exists (select 1 from dana_pos where cabang_id = p_cabang and sumber = 'tutup_kas' and pos = 'operasional'
                  and (created_at at time zone 'Asia/Jakarta')::date = v_hari) then
    v_sewa := coalesce(bt.sewa_per_tahun, 0) * coalesce(bt.porsi_sewa_persen, 0) / 100 / 365;
    v_listrik := coalesce(bt.listrik_per_hari, 0);
    if coalesce(bt.gaji_aktif, false) then
      v_gaji := coalesce(bt.gaji_per_jam, 0) * extract(epoch from (coalesce(bt.jam_tutup,'21:00') - coalesce(bt.jam_buka,'07:30'))) / 3600;
    end if;
  end if;
  if not exists (select 1 from dana_pos where cabang_id = p_cabang and sumber = 'tutup_kas' and pos = 'stok' and coalesce((rincian->>'gas')::numeric,0) > 0
                  and (created_at at time zone 'Asia/Jakarta')::date = v_hari) then
    v_gas := coalesce(bt.gas_per_hari, 1650);
  end if;
  -- 2026-10-25: barang Dana Stok yang dibeli pakai Kas Outlet (cup, sedotan, bubuk, kopi, sealer, gas) = Kas Outlet sudah menalangi,
  -- jadi sisihan Dana Stok dikurangi sebesar itu supaya Kas Outlet tidak keluar 2x.
  v_talang := coalesce((select sum(p.total) from pembelian p join bahan_baku b on b.id = p.bahan_baku_id
                         where p.cabang_id = p_cabang and p.sumber_dana = 'tunai' and b.pos_dana = 'stok' and p.created_at > v_sejak), 0)
            + coalesce((select sum(jumlah) from biaya_operasional
                         where cabang_id = p_cabang and sumber_dana = 'tunai' and created_at > v_sejak and jumlah > 0
                           and (kategori = 'Gas' or (kategori = 'Bayar Hutang Bahan' and coalesce(deskripsi,'') ~* 'sealer'))), 0);
  return jsonb_build_object(
    'sejak', v_sejak,
    'stok', greatest(0, ceil((v_bahan + v_gas - v_talang) / 500) * 500),
    'operasional', ceil((v_sewa + v_listrik + v_gaji) / 500) * 500,
    'rincian', jsonb_build_object('bahan', round(v_bahan), 'gas', round(v_gas), 'sewa', round(v_sewa), 'listrik', round(v_listrik), 'gaji', round(v_gaji),
                                  'talangan_kas', round(v_talang),
                                  'gaji_aktif', coalesce(bt.gaji_aktif, false), 'per_bahan', coalesce(v_rinci, '[]'::jsonb)));
end $function$;

-- 2026-10-25 23.06 Boss Leo: "uang diambil dari mana, itu yang berkurang" -> penyesuaian talangan (bagian 5) DILEPAS,
-- dana_hitung_sisih kembali murni pemakaian (masuk_at tetap). Koreksi Rp26.000 Dana Stok -> Kas Outlet juga dibatalkan.
