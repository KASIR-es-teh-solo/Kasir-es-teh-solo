-- 2026-10-18 · Tutup kas 3 langkah + kas awal paten (permintaan Boss Leo)
-- Kas awal tiap hari paten (default Rp200.000). Saat tutup kas, kelebihan uang laci (fisik − paten)
-- otomatis jadi "Setoran tutup kas" ke Brankas; sisa paten ditinggal di laci untuk kembalian besok.

alter table kas_shift add column if not exists setoran numeric not null default 0;
alter table kas_shift add column if not exists kas_ditinggal numeric;
alter table kas_shift_arsip add column if not exists setoran numeric not null default 0;
alter table kas_shift_arsip add column if not exists kas_ditinggal numeric;
-- tanpa foreign key: kas_shift lama dipindah ke arsip (dihapus dari kas_shift)
alter table brankas add column if not exists kas_shift_id uuid;

-- arsip: kolom ditulis eksplisit (sebelumnya pakai p.* -> rusak kalau kolom bertambah)
create or replace function public.arsipkan_riwayat_kas_lama()
 returns integer language plpgsql security definer set search_path to 'public'
as $function$
declare n integer;
begin
  with target as (
    select k.id from kas_shift k
    where k.status = 'selesai'
      and k.waktu_tutup < now() - interval '3 days'
      and k.id not in (
        select distinct on (cabang_id) id from kas_shift
        where status = 'selesai' order by cabang_id, waktu_tutup desc nulls last)
  ), pindah as (
    delete from kas_shift k using target t where k.id = t.id returning k.*
  )
  insert into kas_shift_arsip (id, cabang_id, dibuka_oleh, kas_awal, waktu_buka, status, kas_sistem, kas_fisik, selisih,
                               catatan, ditutup_oleh, waktu_tutup, created_at, total_biaya, setoran, kas_ditinggal, diarsipkan_at)
  select p.id, p.cabang_id, p.dibuka_oleh, p.kas_awal, p.waktu_buka, p.status, p.kas_sistem, p.kas_fisik, p.selisih,
         p.catatan, p.ditutup_oleh, p.waktu_tutup, p.created_at, p.total_biaya, p.setoran, p.kas_ditinggal, now()
  from pindah p;
  get diagnostics n = row_count;
  return n;
end $function$;

-- setoran tutup kas BUKAN uang keluar laci harian (sudah dihitung di tutup kas) -> dikecualikan
create or replace function public.laporan_biaya_kas(p_cabang uuid, p_sejak timestamptz)
 returns table(deskripsi text, kategori text, jumlah numeric, created_at timestamptz, pencatat text)
 language sql stable security definer set search_path to 'public'
as $function$
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
  ) x
  where (public.is_admin_or_owner() or public.user_di_cabang(p_cabang))
  order by 4;
$function$;

-- pengaturan kas awal paten
insert into pengaturan_sistem(kunci, nilai) values ('kas_awal_paten', '200000')
  on conflict (kunci) do nothing;

create or replace function public.pengaturan_kas()
 returns json language sql stable security definer set search_path to 'public'
as $function$
  select json_build_object('kas_awal_paten',
    coalesce((select nilai::numeric from pengaturan_sistem where kunci = 'kas_awal_paten'), 200000));
$function$;
revoke all on function public.pengaturan_kas() from public, anon;
grant execute on function public.pengaturan_kas() to authenticated;

create or replace function public.set_kas_awal_paten(p_nilai numeric)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
begin
  if not public.is_owner() then raise exception 'Hanya Owner yang bisa mengubah kas awal paten'; end if;
  if p_nilai is null or p_nilai < 0 or p_nilai > 10000000 then raise exception 'Nilai kas awal tidak valid'; end if;
  insert into pengaturan_sistem(kunci, nilai) values ('kas_awal_paten', trim_scale(p_nilai)::text)
    on conflict (kunci) do update set nilai = excluded.nilai;
  insert into log_aktivitas(cabang_id, user_id, aksi, keterangan)
    values (null, auth.uid(), 'Ubah Kas Awal Paten', 'Kas awal paten jadi Rp' || replace(to_char(p_nilai, 'FM999G999G999'), ',', '.'));
end $function$;
revoke all on function public.set_kas_awal_paten(numeric) from public, anon;
grant execute on function public.set_kas_awal_paten(numeric) to authenticated;

-- simpan tutup kas + setoran ke brankas sekaligus (atomik)
create or replace function public.kas_tutup(p_cabang uuid, p_kas_awal numeric, p_kas_sistem numeric, p_kas_fisik numeric,
                                            p_total_biaya numeric, p_catatan text, p_waktu_buka timestamptz)
 returns json language plpgsql security definer set search_path to 'public'
as $function$
declare v_role text; v_paten numeric; v_setor numeric; v_tinggal numeric; v_id uuid;
begin
  select role into v_role from users where id = auth.uid();
  if v_role is null or v_role not in ('kasir', 'admin', 'owner') then raise exception 'Tidak punya akses tutup kas'; end if;
  if v_role <> 'owner' and not public.user_di_cabang(p_cabang) then raise exception 'Bukan cabang kamu'; end if;
  if p_kas_fisik is null or p_kas_fisik < 0 then raise exception 'Jumlah uang di laci tidak valid'; end if;
  if p_kas_fisik <> p_kas_sistem and nullif(trim(coalesce(p_catatan, '')), '') is null then
    raise exception 'Kas tidak pas, isi alasannya dulu';
  end if;
  v_paten := coalesce((select nilai::numeric from pengaturan_sistem where kunci = 'kas_awal_paten'), 200000);
  v_setor := greatest(0, p_kas_fisik - v_paten);
  v_tinggal := p_kas_fisik - v_setor;
  insert into kas_shift(cabang_id, dibuka_oleh, ditutup_oleh, kas_awal, status, kas_sistem, kas_fisik, selisih, total_biaya,
                        catatan, waktu_buka, waktu_tutup, setoran, kas_ditinggal)
  values (p_cabang, auth.uid(), auth.uid(), p_kas_awal, 'selesai', p_kas_sistem, p_kas_fisik, p_kas_fisik - p_kas_sistem,
          p_total_biaya, nullif(trim(coalesce(p_catatan, '')), ''), p_waktu_buka, now(), v_setor, v_tinggal)
  returning id into v_id;
  if v_setor > 0 then
    insert into brankas(cabang_id, jenis, jumlah, keterangan, dicatat_oleh, kas_shift_id)
    values (p_cabang, 'masuk', v_setor, 'Setoran tutup kas', auth.uid(), v_id);
  end if;
  return json_build_object('id', v_id, 'setoran', v_setor, 'kas_ditinggal', v_tinggal, 'kas_awal_paten', v_paten);
end $function$;
revoke all on function public.kas_tutup(uuid, numeric, numeric, numeric, numeric, text, timestamptz) from public, anon;
grant execute on function public.kas_tutup(uuid, numeric, numeric, numeric, numeric, text, timestamptz) to authenticated;
