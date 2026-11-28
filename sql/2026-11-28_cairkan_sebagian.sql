-- 2026-11-28 (Boss Leo): Brankas Online bisa dicairkan SEBAGIAN.
-- Sebelumnya tombol Cairkan selalu mencairkan seluruh saldo platform; pesanan hari ini yang belum
-- cair ikut tercatat sebagai "potongan komisi". Fungsi lama brankas_online_cairkan TIDAK diubah (dipakai MeyAdmin).
create or replace function public.brankas_online_cairkan_sebagian(
  p_cabang uuid, p_platform text, p_jumlah numeric, p_diterima numeric)
returns json
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_saldo numeric; v_nama text; v_komisi numeric; v_sisa numeric;
begin
  if not public.is_admin_or_owner() then raise exception 'Khusus Owner/Admin'; end if;
  if p_platform not in ('grab','shopee','lain') then raise exception 'Platform tidak dikenal'; end if;
  v_nama := case p_platform when 'grab' then 'GrabFood' when 'shopee' then 'ShopeeFood' else 'Online lain' end;
  select coalesce((select sum(total) from transaksi where cabang_id = p_cabang and status = 'selesai'
                   and metode_bayar = 'online' and coalesce(platform,'lain') = p_platform), 0)
       - coalesce((select sum(jumlah) from brankas_online where cabang_id = p_cabang
                   and coalesce(platform,'lain') = p_platform), 0)
    into v_saldo;
  if v_saldo <= 0 then raise exception 'Saldo % kosong, tidak ada yang dicairkan', v_nama; end if;
  if p_jumlah is null or p_jumlah <= 0 then raise exception 'Isi jumlah pesanan yang dicairkan'; end if;
  if p_jumlah > v_saldo then
    raise exception 'Jumlah pesanan lebih besar dari saldo % (Rp%)', v_nama, replace(to_char(v_saldo,'FM999,999,999'),',','.');
  end if;
  if p_diterima is null or p_diterima < 0 then raise exception 'Isi uang yang diterima'; end if;
  if p_diterima > p_jumlah then
    raise exception 'Uang diterima tidak boleh lebih besar dari pesanan yang dicairkan (Rp%)', replace(to_char(p_jumlah,'FM999,999,999'),',','.');
  end if;
  v_komisi := p_jumlah - p_diterima;
  v_sisa := v_saldo - p_jumlah;
  if p_diterima > 0 then
    insert into brankas_online(cabang_id, jenis, jumlah, keterangan, dicatat_oleh, platform, diterima)
    values (p_cabang, 'ke_laci', p_diterima, 'Dicairkan ke Kas Outlet', auth.uid(), nullif(p_platform,'lain'), p_diterima);
  end if;
  if v_komisi > 0 then
    insert into brankas_online(cabang_id, jenis, jumlah, keterangan, dicatat_oleh, platform, diterima)
    values (p_cabang, 'selisih', v_komisi, 'Potongan komisi ' || v_nama, auth.uid(), nullif(p_platform,'lain'), 0);
  end if;
  insert into log_aktivitas(cabang_id, user_id, aksi, keterangan)
  values (p_cabang, auth.uid(), 'Cairkan ' || v_nama,
    v_nama || case when v_sisa > 0 then ' dicairkan SEBAGIAN' else ' dicairkan' end
    || ': pesanan Rp' || replace(to_char(p_jumlah,'FM999,999,999'),',','.')
    || ', masuk Kas Outlet Rp' || replace(to_char(p_diterima,'FM999,999,999'),',','.')
    || ', potongan komisi Rp' || replace(to_char(v_komisi,'FM999,999,999'),',','.')
    || ', sisa belum cair Rp' || replace(to_char(v_sisa,'FM999,999,999'),',','.'));
  return json_build_object('pesanan', p_jumlah, 'diterima', p_diterima, 'komisi', v_komisi, 'sisa', v_sisa);
end $function$;
revoke all on function public.brankas_online_cairkan_sebagian(uuid, text, numeric, numeric) from public, anon;
grant execute on function public.brankas_online_cairkan_sebagian(uuid, text, numeric, numeric) to authenticated;
