-- 2026-09-27 — sudah dijalankan di Supabase oleh Mey atas permintaan Owner.
-- 1) absen_masuk: foto absen wajib diambil <= 10 menit sebelumnya dan tidak boleh dipakai ulang.
-- 2) Sesi jam kerja tidak menumpuk: saat sesi baru dibuat, sesi lama user yang sama di HARI YANG SAMA (WIB)
--    yang masih terbuka ditutup pada jam masuk sesi baru (dianggap kerja bersambung).
--    Sesi terbuka dari hari sebelumnya dibiarkan untuk ditutup Owner (tutup_sesi_absensi).

create or replace function public.absen_masuk(p_cabang uuid, p_lat double precision, p_lng double precision, p_akurasi double precision, p_qr text, p_foto_path text)
 returns json language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_clat double precision; v_clng double precision; v_nama_cabang text;
  v_radius numeric; v_jarak numeric; v_kode text; v_id uuid; v_masuk timestamptz; v_foto_at timestamptz;
begin
  if v_uid is null then raise exception 'Belum login'; end if;
  if not exists (select 1 from users where id=v_uid and role in ('kasir','admin','owner')) then raise exception 'Akun tidak dikenal'; end if;
  if not (public.user_di_cabang(p_cabang) or public.is_owner()) then raise exception 'Kamu tidak terdaftar di cabang ini'; end if;

  select latitude, longitude, nama into v_clat, v_clng, v_nama_cabang from cabang where id=p_cabang;
  if v_clat is null or v_clng is null then raise exception 'Titik GPS outlet belum diatur Owner'; end if;
  if p_lat is null or p_lng is null then raise exception 'Lokasi GPS tidak terbaca'; end if;

  v_radius := coalesce((select nilai::numeric from pengaturan_sistem where kunci='absen_radius_meter'), 35);
  v_jarak := round((6371000 * 2 * asin(sqrt(
      power(sin(radians(p_lat - v_clat)/2),2) +
      cos(radians(v_clat)) * cos(radians(p_lat)) * power(sin(radians(p_lng - v_clng)/2),2))))::numeric);
  if v_jarak > v_radius then
    raise exception 'Kamu berada % m dari outlet (maks. % m). Absen hanya bisa di outlet.', v_jarak, v_radius;
  end if;

  select kode into v_kode from cabang_kode_absen where cabang_id=p_cabang;
  if v_kode is null or p_qr is distinct from ('ESTEHSOLO-ABSEN:' || v_kode) then
    raise exception 'QR mesin sealer tidak cocok untuk outlet ini.';
  end if;

  if p_foto_path is null or split_part(p_foto_path,'/',1) <> v_uid::text then
    raise exception 'Foto absen tidak ditemukan, ulangi foto.';
  end if;
  select created_at into v_foto_at from storage.objects where bucket_id='absensi-foto' and name=p_foto_path;
  if v_foto_at is null then raise exception 'Foto absen tidak ditemukan, ulangi foto.'; end if;
  if v_foto_at < now() - interval '10 minutes' then raise exception 'Foto sudah kedaluwarsa, ulangi foto.'; end if;
  if exists (select 1 from absensi where foto_path = p_foto_path) then raise exception 'Foto ini sudah pernah dipakai absen, ulangi foto.'; end if;

  perform set_config('app.absen_terverifikasi','1', true);
  insert into absensi(user_id, cabang_id, foto_path, latitude, longitude, jarak_meter, akurasi_gps, terverifikasi)
  values (v_uid, p_cabang, p_foto_path, p_lat, p_lng, v_jarak, p_akurasi, true)
  returning id, waktu_masuk into v_id, v_masuk;
  perform set_config('app.absen_terverifikasi','0', true);

  return json_build_object('absensi_id', v_id, 'waktu_masuk', v_masuk, 'jarak', v_jarak, 'cabang', v_nama_cabang);
end $function$;

create or replace function public.tutup_sesi_lama_absensi()
 returns trigger language plpgsql security definer set search_path to 'public'
as $function$
begin
  update absensi
     set waktu_keluar = new.waktu_masuk
   where user_id = new.user_id
     and id <> new.id
     and waktu_keluar is null
     and waktu_masuk <= new.waktu_masuk
     and (waktu_masuk at time zone 'Asia/Jakarta')::date = (new.waktu_masuk at time zone 'Asia/Jakarta')::date;
  return null;
end $function$;

drop trigger if exists trg_tutup_sesi_lama_absensi on public.absensi;
create trigger trg_tutup_sesi_lama_absensi after insert on public.absensi
  for each row execute function public.tutup_sesi_lama_absensi();
