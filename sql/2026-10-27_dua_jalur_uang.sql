-- 2026-10-27 Dua jalur uang (disetujui Boss Leo "Oke buatkan")
-- Tandon Dollar: Celengan Senang + tombol Gajian Jumat (catatan saja, Kas Outlet TIDAK diubah)
-- Bengkel: Kas Bengkel = Celengan Bengkel, kategori "Modal dari Boss" & "Bayar KUR BRI",
--          ringkasan bulan (modal vs hasil) + hitung mundur KUR tanggal 4.

-- 1) Pengaturan gajian
alter table kaleng_pengaturan
  add column if not exists gajian_jumlah  numeric not null default 550000,
  add column if not exists gajian_nafkah  numeric not null default 75000,
  add column if not exists gajian_rokok   numeric not null default 120000,
  add column if not exists gajian_senang  numeric not null default 50000,
  add column if not exists gajian_terakhir date;

-- 2) Tandon baru 'senang' + sumber 'gajian'
alter table kaleng_catatan drop constraint if exists kaleng_catatan_kaleng_check;
alter table kaleng_catatan add constraint kaleng_catatan_kaleng_check check (kaleng in ('kur','keluarga','senang'));
alter table kaleng_catatan drop constraint if exists kaleng_catatan_sumber_check;
alter table kaleng_catatan add constraint kaleng_catatan_sumber_check check (sumber in ('manual','bagi','cocokkan','bayar_kur','gajian'));

-- 3) kaleng_catat: izinkan tandon 'senang'
create or replace function public.kaleng_catat(p_kaleng text, p_jenis text, p_jumlah numeric, p_keterangan text default null, p_sumber text default 'manual')
returns void language plpgsql security definer set search_path to 'public' as $function$
declare v_nama text; v_saldo numeric;
begin
  if not public.is_admin_or_owner() then raise exception 'Khusus Owner & Admin'; end if;
  if p_kaleng not in ('kontrakan','kur','keluarga','senang') or p_jenis not in ('masuk','keluar') then raise exception 'Pilihan tidak valid'; end if;
  if p_jumlah is null or p_jumlah <= 0 then raise exception 'Jumlah harus lebih dari 0'; end if;
  if coalesce(p_sumber,'') not in ('manual','bagi','cocokkan','bayar_kur') then p_sumber := 'manual'; end if;
  v_nama := case p_kaleng when 'kontrakan' then 'Kontrakan' when 'kur' then 'KUR BRI' when 'senang' then 'Celengan Senang' else 'Dana Keluarga' end;
  if p_jenis = 'keluar' and p_sumber <> 'cocokkan' then
    v_saldo := case p_kaleng when 'kontrakan' then (select coalesce(sum(case when jenis='masuk' then jumlah else -jumlah end),0) from brankas)
               else (select coalesce(sum(case when jenis='masuk' then jumlah else -jumlah end),0) from kaleng_catatan where kaleng = p_kaleng and not dihapus) end;
    if p_jumlah > v_saldo then raise exception 'Saldo tandon % cuma Rp%', v_nama, replace(to_char(v_saldo,'FM999,999,999'),',','.'); end if;
  end if;
  if p_kaleng = 'kontrakan' then
    insert into brankas(cabang_id, jenis, jumlah, keterangan, dicatat_oleh, dilihat_owner, kas_shift_id)
    values ('199e77b5-f52e-4534-9656-3a0d8fceddfd', p_jenis, p_jumlah, coalesce(nullif(btrim(p_keterangan),''), case when p_jenis='masuk' then 'Masukkan ke tandon Kontrakan' else 'Ambil dari tandon Kontrakan' end),
            auth.uid(), true, '00000000-0000-0000-0000-000000000000');
  else
    insert into kaleng_catatan(kaleng, jenis, jumlah, sumber, keterangan) values (p_kaleng, p_jenis, p_jumlah, p_sumber, nullif(btrim(p_keterangan),''));
  end if;
  if p_sumber = 'bayar_kur' then update kaleng_pengaturan set kur_sudah = kur_sudah + 1 where id = 1; end if;
  insert into log_aktivitas(cabang_id, user_id, aksi, keterangan)
  values (null, auth.uid(), 'Tandon ' || v_nama,
          case p_jenis when 'masuk' then 'Masuk ' else 'Keluar ' end || 'Rp' || replace(to_char(p_jumlah,'FM999,999,999'),',','.') || coalesce(' · ' || nullif(btrim(p_keterangan),''), ''));
end $function$;

-- 4) Gajian Jumat: catat gajian (dari laba es teh, diambil Boss sendiri) + isi Celengan Senang
create or replace function public.gajian_jumat()
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare k kaleng_pengaturan%rowtype; v_today date := (now() at time zone 'Asia/Jakarta')::date;
begin
  if not public.is_owner() then raise exception 'Gajian Jumat khusus Owner'; end if;
  select * into k from kaleng_pengaturan where id = 1 for update;
  if k.gajian_terakhir is not null and k.gajian_terakhir > v_today - 7 then
    raise exception 'Gajian minggu ini sudah diambil (%)', to_char(k.gajian_terakhir, 'DD-MM-YYYY');
  end if;
  if k.gajian_senang > 0 then
    insert into kaleng_catatan(kaleng, jenis, jumlah, sumber, keterangan)
    values ('senang', 'masuk', k.gajian_senang, 'gajian', 'Gajian Jumat');
  end if;
  update kaleng_pengaturan set gajian_terakhir = v_today where id = 1;
  insert into log_aktivitas(cabang_id, user_id, aksi, keterangan)
  values (null, auth.uid(), 'Gajian Jumat',
          'Rp' || replace(to_char(k.gajian_jumlah,'FM999,999,999'),',','.') || ' dari laba es teh (Kas Outlet tidak diubah aplikasi) · Celengan Senang +Rp' || replace(to_char(k.gajian_senang,'FM999,999,999'),',','.'));
  return jsonb_build_object('tanggal', v_today, 'jumlah', k.gajian_jumlah);
end $function$;

-- 5) kaleng_data: + senang, gajian
create or replace function public.kaleng_data()
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare k kaleng_pengaturan%rowtype; v_kontrakan numeric; v_kur numeric; v_kel numeric; v_senang numeric; v_due date; v_hari int;
        v_today date := (now() at time zone 'Asia/Jakarta')::date;
begin
  if not public.is_admin_or_owner() then raise exception 'Khusus Owner & Admin'; end if;
  select * into k from kaleng_pengaturan where id = 1;
  select coalesce(sum(case when jenis='masuk' then jumlah else -jumlah end),0) into v_kontrakan from brankas;
  select coalesce(sum(case when jenis='masuk' then jumlah else -jumlah end),0) into v_kur from kaleng_catatan where kaleng='kur' and not dihapus;
  select coalesce(sum(case when jenis='masuk' then jumlah else -jumlah end),0) into v_kel from kaleng_catatan where kaleng='keluarga' and not dihapus;
  select coalesce(sum(case when jenis='masuk' then jumlah else -jumlah end),0) into v_senang from kaleng_catatan where kaleng='senang' and not dihapus;
  v_due := make_date(extract(year from v_today)::int, extract(month from v_today)::int, k.kur_tanggal);
  if v_due <= v_today then v_due := (v_due + interval '1 month')::date; end if;
  v_hari := (k.kontrakan_tanggal - v_today);
  return jsonb_build_object(
    'kontrakan', v_kontrakan, 'kur', v_kur, 'keluarga', v_kel, 'senang', v_senang,
    'pengaturan', to_jsonb(k),
    'hari_ini', v_today,
    'gajian_sudah', (k.gajian_terakhir is not null and k.gajian_terakhir > v_today - 7),
    'kontrakan_sisa_hari', v_hari,
    'kontrakan_kurang', greatest(k.kontrakan_target - v_kontrakan, 0),
    'kontrakan_per_hari', case when v_hari > 0 then ceil(greatest(k.kontrakan_target - v_kontrakan, 0) / v_hari) else greatest(k.kontrakan_target - v_kontrakan, 0) end,
    'kur_jatuh_tempo', v_due, 'kur_siap_sebelum', v_due - 1, 'kur_hari_lagi', (v_due - 1) - v_today,
    'kur_angsuran_ke', k.kur_sudah + 1,
    'kur_kurang', greatest(k.kur_angsuran - v_kur, 0),
    'riwayat', coalesce((select jsonb_agg(x order by x.waktu desc) from (
        select 'kontrakan' kaleng, b.jenis, b.jumlah, b.keterangan, b.created_at waktu, u.nama pencatat
          from brankas b left join users u on u.id = b.dicatat_oleh
        union all
        select c.kaleng, c.jenis, c.jumlah, c.keterangan, c.created_at, u.nama
          from kaleng_catatan c left join users u on u.id = c.dicatat_oleh
         where not c.dihapus
        order by 5 desc limit 80) x), '[]'::jsonb));
end $function$;

-- 6) Bengkel: Bayar KUR BRI ikut menaikkan angsuran ke-
create or replace function public.bengkel_kas_catat(p_jenis text, p_kategori text, p_jumlah numeric, p_ket text default null)
returns bigint language plpgsql security definer set search_path to 'public' as $function$
declare v_id bigint;
begin
  perform bengkel_cek();
  if p_jenis not in ('masuk','keluar') then raise exception 'Jenis tidak valid'; end if;
  if p_jumlah is null or p_jumlah <= 0 then raise exception 'Jumlah harus lebih dari 0'; end if;
  if coalesce(trim(p_kategori),'') = '' then raise exception 'Pilih kategori'; end if;
  if p_jenis = 'keluar' and p_jumlah > bengkel_saldo_kas() then
    raise exception 'Celengan Bengkel cuma Rp%', replace(to_char(bengkel_saldo_kas(),'FM999,999,999'),',','.');
  end if;
  insert into bengkel_kas(jenis, kategori, jumlah, keterangan) values (p_jenis, trim(p_kategori), p_jumlah, nullif(trim(p_ket),''))
    returning id into v_id;
  if p_jenis = 'keluar' and trim(p_kategori) = 'Bayar KUR BRI' then
    update kaleng_pengaturan set kur_sudah = kur_sudah + 1 where id = 1;
  end if;
  return v_id;
end $function$;

create or replace function public.bengkel_kas_batal(p_id bigint)
returns void language plpgsql security definer set search_path to 'public' as $function$
declare v_kat text; v_jenis text;
begin
  perform bengkel_cek();
  update bengkel_kas set batal=true where id=p_id and trx_id is null and beli_id is null and not batal
    returning kategori, jenis into v_kat, v_jenis;
  if not found then raise exception 'Catatan ini tidak bisa dibatalkan di sini (batalkan lewat transaksi/pembelian)'; end if;
  if v_jenis = 'keluar' and v_kat = 'Bayar KUR BRI' then
    update kaleng_pengaturan set kur_sudah = greatest(kur_sudah - 1, 0) where id = 1;
  end if;
end $function$;

-- 7) Laporan bengkel: Ambil Owner & Bayar KUR BRI bukan biaya operasional
create or replace function public.bengkel_laporan(p_dari date, p_sampai date)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare r jsonb;
begin
  perform bengkel_cek();
  with t as (select * from bengkel_trx where not batal and (waktu at time zone 'Asia/Jakarta')::date between p_dari and p_sampai),
  k as (select * from bengkel_kas where not batal and trx_id is null and beli_id is null and jenis='keluar'
          and kategori not in ('Ambil Owner','Bayar KUR BRI') and (waktu at time zone 'Asia/Jakarta')::date between p_dari and p_sampai)
  select jsonb_build_object(
    'trx', (select count(*) from t),
    'omzet', (select coalesce(sum(total),0) from t),
    'jasa', (select coalesce(sum(total_jasa),0) from t),
    'part', (select coalesce(sum(total_part),0) from t),
    'modal_part', (select coalesce(sum(modal_part),0) from t),
    'biaya', (select coalesce(sum(jumlah),0) from k),
    'biaya_rinci', coalesce((select jsonb_agg(jsonb_build_object('kategori',kategori,'jumlah',s) order by s desc)
                    from (select kategori, sum(jumlah) s from k group by kategori) x), '[]'::jsonb),
    'per_hari', coalesce((select jsonb_agg(jsonb_build_object('tgl',d,'omzet',o,'laba',l) order by d)
                    from (select (waktu at time zone 'Asia/Jakarta')::date d, sum(total) o, sum(total_jasa+total_part-modal_part) l
                          from t group by 1) x), '[]'::jsonb),
    'terlaris', coalesce((select jsonb_agg(jsonb_build_object('nama',nama,'jenis',jenis,'qty',q,'nilai',v) order by v desc)
                    from (select i.nama, i.jenis, sum(i.qty) q, sum(i.qty*i.harga) v from bengkel_trx_item i join t on t.id=i.trx_id
                          group by i.nama, i.jenis order by 4 desc limit 8) x), '[]'::jsonb)
  ) into r;
  return r;
end $function$;

-- 8) Ringkasan bulan + KUR untuk beranda bengkel
create or replace function public.bengkel_ringkas()
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare k kaleng_pengaturan%rowtype; v_today date := (now() at time zone 'Asia/Jakarta')::date;
        v_awal date; v_due date; v_modal numeric; v_hasil numeric; v_saldo numeric; v_sudah_bayar boolean;
begin
  perform bengkel_cek();
  select * into k from kaleng_pengaturan where id = 1;
  v_awal := date_trunc('month', v_today)::date;
  select coalesce(sum(jumlah),0) into v_modal from bengkel_kas
   where not batal and jenis='masuk' and kategori='Modal dari Boss' and (waktu at time zone 'Asia/Jakarta')::date >= v_awal;
  select coalesce(sum(total_jasa + total_part - modal_part),0) into v_hasil from bengkel_trx
   where not batal and (waktu at time zone 'Asia/Jakarta')::date >= v_awal;
  v_saldo := bengkel_saldo_kas();
  v_due := make_date(extract(year from v_today)::int, extract(month from v_today)::int, k.kur_tanggal);
  -- sudah bayar KUR periode ini? (catatan Bayar KUR BRI sejak tanggal tempo bulan lalu + 1)
  select exists(select 1 from bengkel_kas where not batal and jenis='keluar' and kategori='Bayar KUR BRI'
                  and (waktu at time zone 'Asia/Jakarta')::date > ((v_due - interval '1 month')::date)
                  and (waktu at time zone 'Asia/Jakarta')::date <= v_due) into v_sudah_bayar;
  if v_due < v_today or (v_due = v_today and v_sudah_bayar) then
    v_due := (v_due + interval '1 month')::date;
  end if;
  return jsonb_build_object(
    'bulan', to_char(v_today, 'YYYY-MM'),
    'modal', v_modal, 'hasil', v_hasil, 'saldo', v_saldo,
    'kur_angsuran', k.kur_angsuran, 'kur_ke', k.kur_sudah + 1, 'kur_tenor', k.kur_tenor,
    'kur_tempo', v_due, 'kur_hari_lagi', v_due - v_today,
    'kur_kurang', greatest(k.kur_angsuran - v_saldo, 0));
end $function$;

revoke all on function public.gajian_jumat() from public, anon;
revoke all on function public.bengkel_ringkas() from public, anon;
grant execute on function public.gajian_jumat() to authenticated;
grant execute on function public.bengkel_ringkas() to authenticated;
