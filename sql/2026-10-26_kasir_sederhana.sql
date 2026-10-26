-- 2026-10-26 · Kasir Sederhana (konsep disetujui Boss Leo: QRIS dipisah, amplop dipindah Owner, Simpanan Harian oleh Owner/Admin)
-- Semua perubahan di sini ADITIF: aplikasi lama tetap jalan sama (tidak memakai qris / kas_tutup_v2 / dana_pindah).

-- 1) QRIS boleh disimpan sebagai metode sendiri (tidak masuk hitungan Kas Outlet)
create or replace function public.paksa_metode_tunai()
 returns trigger language plpgsql set search_path to 'public' as $function$
begin
  -- tunai = uang fisik masuk Kas Outlet; qris = masuk rekening QRIS; online = Grab/Shopee
  if coalesce(new.metode_bayar, '') not in ('online', 'qris') then
    new.metode_bayar := 'tunai';
  end if;
  if tg_op = 'INSERT' then new.masuk_at := now(); else new.masuk_at := old.masuk_at; end if;
  return new;
end $function$;

-- 2) Tagihan amplop (yang SEHARUSNYA disisihkan saat tutup kas; uangnya tetap di Kas Outlet)
create table if not exists public.dana_tagih (
  id uuid primary key default gen_random_uuid(),
  cabang_id uuid not null references public.cabang(id),
  pos text not null check (pos in ('stok','operasional')),
  jumlah numeric not null check (jumlah > 0),
  rincian jsonb,
  kas_shift_id uuid,
  created_at timestamptz not null default now()
);
-- 3) Pemindahan uang Kas Outlet -> amplop oleh Owner/Admin
create table if not exists public.dana_pindah (
  id uuid primary key default gen_random_uuid(),
  cabang_id uuid not null references public.cabang(id),
  pos text not null check (pos in ('stok','operasional')),
  jumlah numeric not null check (jumlah > 0),
  keterangan text,
  dicatat_oleh uuid,
  created_at timestamptz not null default now()
);
alter table public.dana_tagih enable row level security;
alter table public.dana_pindah enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename='dana_tagih' and policyname='dana_tagih_lihat') then
    create policy dana_tagih_lihat on public.dana_tagih for select using (public.is_admin_or_owner());
  end if;
  if not exists (select 1 from pg_policies where tablename='dana_pindah' and policyname='dana_pindah_lihat') then
    create policy dana_pindah_lihat on public.dana_pindah for select using (public.is_admin_or_owner());
  end if;
end $$;
create index if not exists dana_tagih_cabang_idx on public.dana_tagih(cabang_id, created_at);
create index if not exists dana_pindah_cabang_idx on public.dana_pindah(cabang_id, created_at);

-- 4) Saldo amplop = isi fisik amplop (lama) + yang sudah dipindah dari Kas Outlet
CREATE OR REPLACE FUNCTION public.dana_saldo(p_cabang uuid)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select case when not (public.is_admin_or_owner() or public.user_di_cabang(p_cabang)) then null else jsonb_build_object(
    'stok', coalesce((select sum(case when jenis='masuk' then jumlah else -jumlah end) from dana_pos where cabang_id=p_cabang and pos='stok'),0)
          + coalesce((select sum(jumlah) from dana_pindah where cabang_id=p_cabang and pos='stok'),0)
          - coalesce((select sum(total) from pembelian where cabang_id=p_cabang and sumber_dana='dana_stok'),0)
          - coalesce((select sum(jumlah) from biaya_operasional where cabang_id=p_cabang and sumber_dana='dana_stok'),0),
    'operasional', coalesce((select sum(case when jenis='masuk' then jumlah else -jumlah end) from dana_pos where cabang_id=p_cabang and pos='operasional'),0)
          + coalesce((select sum(jumlah) from dana_pindah where cabang_id=p_cabang and pos='operasional'),0)
          - coalesce((select sum(total) from pembelian where cabang_id=p_cabang and sumber_dana='dana_operasional'),0)
          - coalesce((select sum(jumlah) from biaya_operasional where cabang_id=p_cabang and sumber_dana='dana_operasional'),0)) end;
$function$;

-- 5) Uang keluar Kas Outlet ikut menghitung pemindahan ke amplop
CREATE OR REPLACE FUNCTION public.laporan_biaya_kas(p_cabang uuid, p_sejak timestamp with time zone)
 RETURNS TABLE(deskripsi text, kategori text, jumlah numeric, created_at timestamp with time zone, pencatat text)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select * from (
    select b.deskripsi, b.kategori, b.jumlah, b.created_at, u.nama
    from biaya_operasional b left join users u on u.id = b.dicatat_oleh
    where b.cabang_id = p_cabang and b.sumber_dana = 'tunai' and b.created_at >= p_sejak
    union all
    select 'Beli ' || bb.nama || ' ' || trim_scale(p.jumlah) || ' ' || coalesce(bb.satuan_beli, bb.satuan, '')
             || coalesce(' — ' || nullif(p.catatan, ''), ''),
           'Pembelian Stok', p.total, p.created_at, u.nama
    from pembelian p join bahan_baku bb on bb.id = p.bahan_baku_id left join users u on u.id = p.dibeli_oleh
    where p.cabang_id = p_cabang and p.sumber_dana = 'tunai' and p.created_at >= p_sejak
    union all
    select nullif(k.keterangan, ''), 'Tabungan', k.jumlah, k.created_at, u.nama
    from brankas k left join users u on u.id = k.dicatat_oleh
    where k.cabang_id = p_cabang and k.jenis = 'masuk' and k.kas_shift_id is null and k.created_at >= p_sejak
    union all
    select 'Dari Brankas Online' || coalesce(' — ' || nullif(o.keterangan,''), ''), 'Masuk dari Brankas Online', -o.jumlah, o.created_at, u.nama
    from brankas_online o left join users u on u.id = o.dicatat_oleh
    where o.cabang_id = p_cabang and o.jenis = 'ke_laci' and o.created_at >= p_sejak
    union all
    select case d.pos when 'stok' then 'Ke amplop Dana Stok' else 'Ke amplop Dana Operasional' end || coalesce(' — ' || nullif(d.keterangan,''), ''),
           'Pindah ke Amplop', d.jumlah, d.created_at, u.nama
    from dana_pindah d left join users u on u.id = d.dicatat_oleh
    where d.cabang_id = p_cabang and d.created_at >= p_sejak
  ) x
  where (public.is_admin_or_owner() or public.user_di_cabang(p_cabang))
  order by 4;
$function$;

-- 6) Sisihan amplop: QRIS ikut dihitung; biaya harian sekali sehari juga melihat tagihan baru
CREATE OR REPLACE FUNCTION public.dana_hitung_sisih(p_cabang uuid, p_sejak timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_sejak timestamptz; v_bahan numeric := 0; v_gas numeric := 0; v_sewa numeric := 0; v_listrik numeric := 0; v_gaji numeric := 0;
        bt biaya_tetap%rowtype; v_hari date := (now() at time zone 'Asia/Jakarta')::date; v_rinci jsonb;
begin
  if not (public.is_admin_or_owner() or public.user_di_cabang(p_cabang)) then raise exception 'Bukan cabang kamu'; end if;
  v_sejak := coalesce(p_sejak, (select max(waktu_tutup) from kas_shift where cabang_id = p_cabang), now() - interval '1 day');
  with pakai as (
    select r.bahan_baku_id, sum(ti.qty * r.jumlah) jml
      from transaksi t join transaksi_item ti on ti.transaksi_id = t.id
      join resep r on r.produk_id = ti.produk_id and lower(replace(coalesce(r.ukuran,''),' ','')) = lower(replace(coalesce(ti.ukuran,''),' ',''))
      join bahan_baku b on b.id = r.bahan_baku_id and b.pos_dana = 'stok'
     where t.cabang_id = p_cabang and t.status = 'selesai' and coalesce(t.metode_bayar,'tunai') in ('tunai','online','qris')
       and t.masuk_at > v_sejak and t.masuk_at <= now()
     group by r.bahan_baku_id)
  select coalesce(sum(p.jml * public.harga_per_unit_bahan(p.bahan_baku_id)), 0),
         jsonb_agg(jsonb_build_object('nama', b.nama, 'jumlah', round(p.jml, 2), 'satuan', b.satuan, 'rupiah', round(p.jml * public.harga_per_unit_bahan(p.bahan_baku_id))) order by p.jml * public.harga_per_unit_bahan(p.bahan_baku_id) desc)
    into v_bahan, v_rinci
    from pakai p join bahan_baku b on b.id = p.bahan_baku_id;
  select * into bt from biaya_tetap where cabang_id = p_cabang;
  if not exists (select 1 from dana_pos where cabang_id = p_cabang and sumber = 'tutup_kas' and pos = 'operasional' and (created_at at time zone 'Asia/Jakarta')::date = v_hari)
     and not exists (select 1 from dana_tagih where cabang_id = p_cabang and pos = 'operasional' and (created_at at time zone 'Asia/Jakarta')::date = v_hari) then
    v_sewa := coalesce(bt.sewa_per_tahun, 0) * coalesce(bt.porsi_sewa_persen, 0) / 100 / 365;
    v_listrik := coalesce(bt.listrik_per_hari, 0);
    if coalesce(bt.gaji_aktif, false) then
      v_gaji := coalesce(bt.gaji_per_jam, 0) * extract(epoch from (coalesce(bt.jam_tutup,'21:00') - coalesce(bt.jam_buka,'07:30'))) / 3600;
    end if;
  end if;
  if not exists (select 1 from dana_pos where cabang_id = p_cabang and sumber = 'tutup_kas' and pos = 'stok' and coalesce((rincian->>'gas')::numeric,0) > 0 and (created_at at time zone 'Asia/Jakarta')::date = v_hari)
     and not exists (select 1 from dana_tagih where cabang_id = p_cabang and pos = 'stok' and coalesce((rincian->>'gas')::numeric,0) > 0 and (created_at at time zone 'Asia/Jakarta')::date = v_hari) then
    v_gas := coalesce(bt.gas_per_hari, 1650);
  end if;
  return jsonb_build_object(
    'sejak', v_sejak,
    'stok', ceil((v_bahan + v_gas) / 500) * 500,
    'operasional', ceil((v_sewa + v_listrik + v_gaji) / 500) * 500,
    'rincian', jsonb_build_object('bahan', round(v_bahan), 'gas', round(v_gas), 'sewa', round(v_sewa), 'listrik', round(v_listrik), 'gaji', round(v_gaji),
                                  'gaji_aktif', coalesce(bt.gaji_aktif, false), 'per_bahan', coalesce(v_rinci, '[]'::jsonb)));
end $function$;

-- 7) Tutup kas versi kasir sederhana: uang TIDAK dipisah ke amplop, hanya dicatat sebagai tagihan
CREATE OR REPLACE FUNCTION public.kas_tutup_v2(p_cabang uuid, p_kas_awal numeric, p_kas_sistem numeric, p_kas_fisik numeric, p_total_biaya numeric, p_catatan text, p_waktu_buka timestamp with time zone)
 RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_role text; v_id uuid; v_dana jsonb; v_ds numeric := 0; v_do numeric := 0;
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
  return json_build_object('id', v_id, 'kas_ditinggal', p_kas_fisik, 'tagih_stok', v_ds, 'tagih_operasional', v_do);
end $function$;

-- 8) Berapa yang belum dipindah ke amplop (tagihan − sudah dipindah − stok yang sudah dibeli pakai Kas Outlet)
CREATE OR REPLACE FUNCTION public.dana_belum_pindah(p_cabang uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_mulai timestamptz; v_ts numeric; v_to numeric; v_ps numeric; v_po numeric; v_beli numeric; v_biaya numeric;
begin
  if not public.is_admin_or_owner() then raise exception 'Khusus Owner/Admin'; end if;
  select min(created_at) into v_mulai from dana_tagih where cabang_id = p_cabang;
  if v_mulai is null then return jsonb_build_object('aktif', false, 'stok', 0, 'operasional', 0); end if;
  select coalesce(sum(jumlah) filter (where pos='stok'),0), coalesce(sum(jumlah) filter (where pos='operasional'),0) into v_ts, v_to from dana_tagih where cabang_id = p_cabang;
  select coalesce(sum(jumlah) filter (where pos='stok'),0), coalesce(sum(jumlah) filter (where pos='operasional'),0) into v_ps, v_po from dana_pindah where cabang_id = p_cabang;
  -- stok yang dibeli pakai Kas Outlet sejak cara baru = sudah "terpakai" dari bagian Dana Stok
  select coalesce(sum(p.total),0) into v_beli from pembelian p join bahan_baku b on b.id = p.bahan_baku_id
   where p.cabang_id = p_cabang and p.sumber_dana = 'tunai' and b.pos_dana = 'stok' and p.created_at >= v_mulai;
  select coalesce(sum(jumlah),0) into v_biaya from biaya_operasional
   where cabang_id = p_cabang and sumber_dana = 'tunai' and created_at >= v_mulai and jumlah > 0
     and (kategori = 'Gas' or (kategori = 'Bayar Hutang Bahan' and coalesce(deskripsi,'') ~* 'sealer'));
  return jsonb_build_object('aktif', true, 'sejak', v_mulai,
    'stok', greatest(0, v_ts - v_ps - v_beli - v_biaya), 'operasional', greatest(0, v_to - v_po),
    'rincian', jsonb_build_object('tagih_stok', v_ts, 'pindah_stok', v_ps, 'stok_dibeli_kas_outlet', v_beli + v_biaya, 'tagih_operasional', v_to, 'pindah_operasional', v_po));
end $function$;

-- 9) Owner/Admin memindahkan uang Kas Outlet ke amplop
CREATE OR REPLACE FUNCTION public.dana_pindahkan(p_cabang uuid, p_pos text, p_jumlah numeric, p_keterangan text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_nama text;
begin
  if not public.is_admin_or_owner() then raise exception 'Khusus Owner/Admin'; end if;
  if p_pos not in ('stok','operasional') then raise exception 'Pilihan tidak valid'; end if;
  if p_jumlah is null or p_jumlah <= 0 then raise exception 'Jumlah harus lebih dari 0'; end if;
  v_nama := case p_pos when 'stok' then 'Dana Stok' else 'Dana Operasional' end;
  insert into dana_pindah(cabang_id, pos, jumlah, keterangan, dicatat_oleh) values (p_cabang, p_pos, p_jumlah, nullif(btrim(p_keterangan),''), auth.uid());
  insert into log_aktivitas(cabang_id, user_id, aksi, keterangan)
  values (p_cabang, auth.uid(), 'Pindah ke ' || v_nama, 'Rp' || replace(to_char(p_jumlah,'FM999,999,999'),',','.') || ' dari Kas Outlet ke amplop ' || v_nama || coalesce(' · ' || nullif(btrim(p_keterangan),''), ''));
  return public.dana_belum_pindah(p_cabang);
end $function$;

revoke all on function public.kas_tutup_v2(uuid,numeric,numeric,numeric,numeric,text,timestamptz) from public, anon;
revoke all on function public.dana_belum_pindah(uuid) from public, anon;
revoke all on function public.dana_pindahkan(uuid,text,numeric,text) from public, anon;
grant execute on function public.kas_tutup_v2(uuid,numeric,numeric,numeric,numeric,text,timestamptz) to authenticated;
grant execute on function public.dana_belum_pindah(uuid) to authenticated;
grant execute on function public.dana_pindahkan(uuid,text,numeric,text) to authenticated;
