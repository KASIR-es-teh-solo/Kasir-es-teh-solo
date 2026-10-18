-- 2026-10-19 · Pesanan online dipisah GrabFood / ShopeeFood (permintaan Boss Leo: rekening Grab & Shopee beda)
-- metode_bayar tetap 'online' (tidak masuk laci), ditambah kolom platform 'grab' | 'shopee'.
alter table transaksi add column if not exists platform text;
alter table brankas_online add column if not exists platform text;
alter table brankas_online add column if not exists diterima numeric;

-- simpan_transaksi: aplikasi mengirim p_metode 'grab' / 'shopee' -> disimpan metode 'online' + platform
do $$ declare d text; begin
  d := pg_get_functiondef('public.simpan_transaksi(uuid,numeric,numeric,numeric,text,jsonb,timestamptz,boolean,uuid,text)'::regprocedure);
  if position('insert into transaksi(kasir_id, cabang_id, total, subtotal, diskon, metode_bayar, created_at, client_tx_id)' in d) = 0 then raise exception 'pola insert tidak ketemu'; end if;
  d := replace(d,
    $q$insert into transaksi(kasir_id, cabang_id, total, subtotal, diskon, metode_bayar, created_at, client_tx_id)
    values (v_kasir, p_cabang, p_total, v_subtotal, v_diskon, coalesce(p_metode, 'tunai'), v_waktu, p_client_id)$q$,
    $q$insert into transaksi(kasir_id, cabang_id, total, subtotal, diskon, metode_bayar, created_at, client_tx_id, platform)
    values (v_kasir, p_cabang, p_total, v_subtotal, v_diskon,
            case when p_metode in ('grab', 'shopee', 'online') then 'online' else coalesce(p_metode, 'tunai') end,
            v_waktu, p_client_id, case when p_metode in ('grab', 'shopee') then p_metode end)$q$);
  execute d;
end $$;

create or replace function public.brankas_online_data(p_cabang uuid)
 returns json language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_awal_bln timestamptz := date_trunc('month', now() at time zone 'Asia/Jakarta') at time zone 'Asia/Jakarta';
begin
  if not public.is_admin_or_owner() then raise exception 'Khusus Owner/Admin'; end if;
  return (
    with tx as (select coalesce(platform, 'lain') pf, total, created_at from transaksi
                 where cabang_id = p_cabang and status = 'selesai' and metode_bayar = 'online'),
         bo as (select coalesce(platform, 'lain') pf, jenis, jumlah, diterima, created_at from brankas_online where cabang_id = p_cabang),
         p as (select unnest(array['grab','shopee','lain']) pf)
    select json_build_object(
      'saldo', (select coalesce(sum(total),0) from tx) - (select coalesce(sum(jumlah),0) from bo),
      'per_platform', (select json_object_agg(p.pf, json_build_object(
          'saldo', (select coalesce(sum(total),0) from tx where tx.pf = p.pf) - (select coalesce(sum(jumlah),0) from bo where bo.pf = p.pf),
          'pesanan_bulan', (select count(*) from tx where tx.pf = p.pf and tx.created_at >= v_awal_bln),
          'masuk_bulan', (select coalesce(sum(total),0) from tx where tx.pf = p.pf and tx.created_at >= v_awal_bln),
          'cair_bulan', (select coalesce(sum(diterima),0) from bo where bo.pf = p.pf and bo.jenis = 'cair' and bo.created_at >= v_awal_bln),
          'ke_laci_bulan', (select coalesce(sum(jumlah),0) from bo where bo.pf = p.pf and bo.jenis = 'ke_laci' and bo.created_at >= v_awal_bln)
        )) from p),
      'masuk_bulan', (select coalesce(sum(total),0) from tx where created_at >= v_awal_bln),
      'pesanan_bulan', (select count(*) from tx where created_at >= v_awal_bln),
      'ke_laci_bulan', (select coalesce(sum(jumlah),0) from bo where jenis='ke_laci' and created_at >= v_awal_bln),
      'selisih_bulan', (select coalesce(sum(jumlah),0) from bo where jenis='selisih' and created_at >= v_awal_bln),
      'riwayat', coalesce((select json_agg(x order by x.waktu desc) from (
          select 'masuk' jenis, coalesce(t.platform,'lain') platform, (t.created_at at time zone 'Asia/Jakarta')::date::text tanggal, max(t.created_at) waktu,
                 count(*) jumlah_pesanan, sum(t.total) jumlah, null::numeric diterima, null::text keterangan, null::text pencatat
            from transaksi t where t.cabang_id = p_cabang and t.status='selesai' and t.metode_bayar='online'
           group by coalesce(t.platform,'lain'), (t.created_at at time zone 'Asia/Jakarta')::date
          union all
          select b.jenis, coalesce(b.platform,'lain'), (b.created_at at time zone 'Asia/Jakarta')::date::text, b.created_at, null, b.jumlah, b.diterima, b.keterangan, u.nama
            from brankas_online b left join users u on u.id = b.dicatat_oleh where b.cabang_id = p_cabang
          order by 4 desc limit 80) x), '[]'::json)
    ));
end $function$;

-- catat per platform: 'cair' = uang sudah masuk rekening (laci tidak berubah), 'ke_laci' = uang dimasukkan ke laci
create or replace function public.brankas_online_catat(p_cabang uuid, p_platform text, p_jenis text, p_jumlah numeric,
                                                        p_diterima numeric default null, p_keterangan text default null)
 returns json language plpgsql security definer set search_path to 'public'
as $function$
declare v_saldo numeric; v_nama text; rp text;
begin
  if not public.is_admin_or_owner() then raise exception 'Khusus Owner/Admin'; end if;
  if p_platform not in ('grab', 'shopee', 'lain') then raise exception 'Platform tidak dikenal'; end if;
  if p_jenis not in ('cair', 'ke_laci') then raise exception 'Jenis tidak dikenal'; end if;
  if p_jumlah is null or p_jumlah <= 0 then raise exception 'Jumlah harus lebih dari 0'; end if;
  v_nama := case p_platform when 'grab' then 'GrabFood' when 'shopee' then 'ShopeeFood' else 'Online lain' end;
  select coalesce((select sum(total) from transaksi where cabang_id = p_cabang and status = 'selesai' and metode_bayar = 'online'
                     and coalesce(platform, 'lain') = p_platform), 0)
       - coalesce((select sum(jumlah) from brankas_online where cabang_id = p_cabang and coalesce(platform, 'lain') = p_platform), 0)
    into v_saldo;
  if p_jumlah > v_saldo then raise exception 'Saldo % cuma Rp%', v_nama, replace(to_char(v_saldo, 'FM999,999,999'), ',', '.'); end if;
  if p_jenis = 'cair' and (p_diterima is null or p_diterima < 0) then raise exception 'Isi uang yang diterima di rekening'; end if;
  rp := replace(to_char(p_jumlah, 'FM999,999,999'), ',', '.');
  insert into brankas_online(cabang_id, jenis, jumlah, keterangan, dicatat_oleh, platform, diterima)
  values (p_cabang, p_jenis, p_jumlah, nullif(btrim(p_keterangan), ''), auth.uid(), nullif(p_platform, 'lain'),
          case when p_jenis = 'cair' then p_diterima end);
  insert into log_aktivitas(cabang_id, user_id, aksi, keterangan)
  values (p_cabang, auth.uid(), 'Brankas Online ' || v_nama,
          case when p_jenis = 'cair'
               then v_nama || ' cair ke rekening: pesanan Rp' || rp || ', diterima Rp' || replace(to_char(p_diterima, 'FM999,999,999'), ',', '.')
                    || ' (potongan Rp' || replace(to_char(p_jumlah - p_diterima, 'FM999,999,999'), ',', '.') || ')'
               else 'Rp' || rp || ' dari ' || v_nama || ' dimasukkan ke laci kasir' end
          || coalesce(' · ' || nullif(btrim(p_keterangan), ''), ''));
  return json_build_object('saldo', v_saldo - p_jumlah);
end $function$;
revoke all on function public.brankas_online_catat(uuid, text, text, numeric, numeric, text) from public, anon;
grant execute on function public.brankas_online_catat(uuid, text, text, numeric, numeric, text) to authenticated;
