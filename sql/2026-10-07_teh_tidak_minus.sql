-- 2026-10-07 (SUDAH DIJALANKAN oleh Mey) — teh siap saji tidak boleh minus terbawa ke seduhan baru.
-- Kasus: 6 Okt malam catatan teh -125 ml (habis), 7 Okt 08.39 seduh 6300 ml -> tampil 6175 (harusnya 6300).
-- Perbaikan data: ditambah catatan 'set' 0 ml tepat sebelum seduhan 6300 ml (atas permintaan Owner).
-- Perbaikan fungsi: saat seduh, kalau sisa tercatat < 0, otomatis dimulai dari 0.
create or replace function public.catat_teh_siap(p_cabang uuid, p_jenis text, p_ml numeric)
 returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_saldo numeric;
begin
  if not (public.user_di_cabang(p_cabang) or public.is_owner()) then raise exception 'Kamu tidak terdaftar di cabang ini'; end if;
  if p_jenis not in ('seduh','set','buang') then raise exception 'Jenis tidak dikenal'; end if;
  if p_ml is null or p_ml < 0 or p_ml > 50000 then raise exception 'Jumlah tidak masuk akal'; end if;
  if p_jenis in ('seduh','buang') and p_ml = 0 then raise exception 'Isi jumlah teh (ml)'; end if;
  if p_jenis = 'seduh' then
    v_saldo := public.saldo_teh_siap(p_cabang, now());
    if v_saldo is not null and v_saldo < 0 then
      insert into teh_siap_log(cabang_id, jenis, ml, dicatat_oleh, created_at) values (p_cabang, 'set', 0, auth.uid(), now() - interval '1 millisecond');
    end if;
  end if;
  insert into teh_siap_log(cabang_id, jenis, ml, dicatat_oleh) values (p_cabang, p_jenis, p_ml, auth.uid());
  return public.status_teh_siap(p_cabang);
end $function$;
