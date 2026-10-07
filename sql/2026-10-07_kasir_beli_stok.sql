-- Admin (form simpel pengganti Catat Pembelian) bisa catat pembelian bahan yang stoknya berkurang saat transaksi (cup, kopi, milo, sedotan, bubuk rasa, teh)
-- lewat tombol Beli Stok Bahan di menu Pembelian. Uang selalu dari laci (tunai). Stok bertambah lewat trigger pembelian seperti biasa.
create or replace function public.kasir_beli_stok(p_cabang uuid, p_bahan uuid, p_jumlah numeric, p_total numeric)
returns json
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_bahan bahan_baku%rowtype;
  v_id uuid;
begin
  if auth.uid() is null or not public.is_pegawai() then
    raise exception 'Harus login sebagai pegawai';
  end if;
  if not (public.is_admin_or_owner() or public.user_di_cabang(p_cabang)) then
    raise exception 'Tidak punya akses ke cabang ini';
  end if;
  select * into v_bahan from bahan_baku where id = p_bahan;
  if not found or not coalesce(v_bahan.dihitung_stok, false) then
    raise exception 'Bahan ini tidak dihitung stoknya';
  end if;
  if p_jumlah is null or p_jumlah <= 0 then raise exception 'Jumlah harus lebih dari 0'; end if;
  if p_total is null or p_total <= 0 then raise exception 'Total bayar harus diisi'; end if;

  insert into pembelian (cabang_id, bahan_baku_id, jumlah, harga_satuan, total, catatan, sumber_dana, dibeli_oleh)
  values (p_cabang, p_bahan, p_jumlah, round(p_total / p_jumlah, 4), p_total, 'dicatat lewat Beli Stok Bahan', 'tunai', auth.uid())
  returning id into v_id;

  insert into log_aktivitas (cabang_id, user_id, aksi, keterangan)
  values (p_cabang, auth.uid(), 'Beli Stok Bahan',
          v_bahan.nama || ' ' || trim_scale(p_jumlah) || ' ' || coalesce(v_bahan.satuan_beli, v_bahan.satuan) || ' Rp' || trim_scale(p_total) || ' (dari laci)');

  return json_build_object('id', v_id, 'harga_satuan', round(p_total / p_jumlah, 2));
end;
$$;

revoke all on function public.kasir_beli_stok(uuid, uuid, numeric, numeric) from public, anon;
grant execute on function public.kasir_beli_stok(uuid, uuid, numeric, numeric) to authenticated;
