-- 2026-10-15 · Batalkan belanja dari laci (Owner & Admin). Pembatalan transaksi tetap khusus Owner.
-- 1) laporan_biaya_kas TIDAK diubah; id belanja diambil langsung dari biaya_operasional (Owner/Admin boleh baca).

-- 2) belanja_batal: Owner/Admin membatalkan satu catatan belanja (biaya_operasional).
--    Tidak dihapus: jumlah jadi 0 & keterangan diberi tanda DIBATALKAN, plus masuk Log Aktivitas.
create or replace function public.belanja_batal(p_id uuid, p_alasan text default null)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
declare v_role text; v_nama text; r biaya_operasional%rowtype;
begin
  select role, nama into v_role, v_nama from users where id = auth.uid();
  if v_role is null or v_role not in ('owner', 'admin') then raise exception 'Hanya Owner/Admin yang bisa membatalkan belanja'; end if;
  select * into r from biaya_operasional where id = p_id for update;
  if not found then raise exception 'Catatan belanja tidak ditemukan'; end if;
  if r.jumlah = 0 or r.deskripsi like 'DIBATALKAN%' then raise exception 'Belanja ini sudah dibatalkan'; end if;
  update biaya_operasional
     set jumlah = 0,
         deskripsi = 'DIBATALKAN (semula Rp' || replace(to_char(r.jumlah, 'FM999G999G999'), ',', '.') || ') · '
                     || coalesce(r.deskripsi, r.kategori) || coalesce(' — ' || nullif(trim(p_alasan), ''), '')
   where id = p_id;
  insert into log_aktivitas(cabang_id, user_id, aksi, keterangan)
  values (r.cabang_id, auth.uid(), 'Batalkan Belanja',
          r.kategori || ' Rp' || replace(to_char(r.jumlah, 'FM999G999G999'), ',', '.') || ' (' || coalesce(r.deskripsi, '-') || ', '
          || to_char(r.created_at at time zone 'Asia/Jakarta', 'DD Mon HH24.MI') || ') dibatalkan oleh ' || coalesce(v_nama, v_role)
          || coalesce('. Alasan: ' || nullif(trim(p_alasan), ''), ''));
end $function$;
revoke all on function public.belanja_batal(uuid, text) from public, anon;
grant execute on function public.belanja_batal(uuid, text) to authenticated;
