-- Stok opname: 2 minggu sekali tiap Jumat (mulai Jumat 23 Okt 2026).
-- Kasir menghitung barang, Admin yang memasukkan. Form tidak menampilkan angka stok aplikasi (hitung jujur).
-- Setelah disimpan, stok aplikasi disamakan dengan hitungan dan selisihnya dicatat.

create table if not exists public.stok_opname (
  id uuid primary key default gen_random_uuid(),
  cabang_id uuid not null references public.cabang(id),
  created_at timestamptz not null default now(),
  oleh uuid default auth.uid(),
  nama_oleh text,
  detail jsonb not null default '[]'::jsonb,   -- [{bahan_baku_id, nama, satuan, sebelum, sesudah, selisih}] dalam satuan stok
  jumlah_selisih int not null default 0
);
alter table public.stok_opname enable row level security;
drop policy if exists stok_opname_lihat on public.stok_opname;
create policy stok_opname_lihat on public.stok_opname for select using (public.is_admin_or_owner());

-- daftar barang yang dihitung (TANPA angka stok)
create or replace function public.opname_daftar(p_cabang uuid)
returns table(id uuid, nama text, satuan text, satuan_beli text, konversi numeric)
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.is_admin_or_owner() then raise exception 'Stok opname hanya untuk Admin/Owner.' using errcode = '42501'; end if;
  return query
    select b.id, b.nama, b.satuan, b.satuan_beli, b.konversi
    from bahan_baku_stok s join bahan_baku b on b.id = s.bahan_baku_id
    where s.cabang_id = p_cabang and coalesce(b.dihitung_stok, true)
    order by case when b.nama ilike 'cup%' or b.nama ilike 'sedotan%' then 0 when b.nama ilike 'teh%' then 1 else 2 end, b.nama;
end $$;

-- waktu opname terakhir cabang ini (untuk pengingat jadwal)
create or replace function public.opname_terakhir(p_cabang uuid)
returns timestamptz
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not (public.is_admin_or_owner() or public.user_di_cabang(p_cabang)) then raise exception 'Bukan cabang kamu' using errcode = '42501'; end if;
  return (select max(created_at) from stok_opname where cabang_id = p_cabang);
end $$;

-- simpan hitungan: p_items = [{id, jumlah}] (jumlah dalam satuan_beli kalau ada konversi, selain itu satuan stok)
create or replace function public.simpan_stok_opname(p_cabang uuid, p_items jsonb)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare it jsonb; v_b record; v_sebelum numeric; v_sesudah numeric; v_detail jsonb := '[]'::jsonb; v_selisih int := 0; v_nama text; v_id uuid;
begin
  if not public.is_admin_or_owner() then raise exception 'Stok opname hanya untuk Admin/Owner.' using errcode = '42501'; end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then raise exception 'Belum ada barang yang diisi.' using errcode = '22023'; end if;

  for it in select * from jsonb_array_elements(p_items) loop
    if (it->>'jumlah') is null or (it->>'jumlah')::numeric < 0 then raise exception 'Jumlah tidak valid.' using errcode = '22023'; end if;
    select b.id, b.nama, b.satuan, b.satuan_beli, b.konversi into v_b from bahan_baku b where b.id = (it->>'id')::uuid;
    if v_b.id is null then continue; end if;
    v_sesudah := round((it->>'jumlah')::numeric * coalesce(case when v_b.satuan_beli is not null then nullif(v_b.konversi, 0) end, 1), 2);
    select stok into v_sebelum from bahan_baku_stok where bahan_baku_id = v_b.id and cabang_id = p_cabang for update;
    if v_sebelum is null then continue; end if;
    update bahan_baku_stok set stok = v_sesudah where bahan_baku_id = v_b.id and cabang_id = p_cabang;
    if v_sesudah <> v_sebelum then v_selisih := v_selisih + 1; end if;
    v_detail := v_detail || jsonb_build_object('bahan_baku_id', v_b.id, 'nama', v_b.nama, 'satuan', v_b.satuan,
      'konversi', v_b.konversi, 'satuan_beli', v_b.satuan_beli, 'sebelum', v_sebelum, 'sesudah', v_sesudah, 'selisih', v_sesudah - v_sebelum);
  end loop;

  select nama into v_nama from users where id = auth.uid();
  insert into stok_opname(cabang_id, nama_oleh, detail, jumlah_selisih) values (p_cabang, v_nama, v_detail, v_selisih) returning id into v_id;
  insert into log_aktivitas(cabang_id, user_id, aksi, keterangan)
  values (p_cabang, auth.uid(), 'Stok Opname', format('%s barang dihitung, %s selisih', jsonb_array_length(v_detail), v_selisih));

  return jsonb_build_object('id', v_id, 'detail', v_detail);
end $$;

revoke all on function public.opname_daftar(uuid), public.opname_terakhir(uuid), public.simpan_stok_opname(uuid, jsonb) from public, anon;
grant execute on function public.opname_daftar(uuid), public.opname_terakhir(uuid), public.simpan_stok_opname(uuid, jsonb) to authenticated;
