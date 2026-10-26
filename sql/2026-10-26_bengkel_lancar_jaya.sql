-- Aplikasi Bengkel Lancar Jaya Motors (terpisah dari kasir es teh, khusus Owner)
-- Tabel bengkel_* + fungsi RPC. Semua perubahan data lewat fungsi (atomik, cek Owner).

create table if not exists public.bengkel_jasa (
  id bigint generated always as identity primary key,
  nama text not null,
  harga numeric not null default 0 check (harga >= 0),
  aktif boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.bengkel_part (
  id bigint generated always as identity primary key,
  nama text not null,
  stok numeric not null default 0,
  harga_modal numeric not null default 0,
  harga_jual numeric not null default 0,
  stok_min numeric not null default 2,
  aktif boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index if not exists bengkel_part_nama_uq on public.bengkel_part (lower(nama));

create table if not exists public.bengkel_beli (
  id bigint generated always as identity primary key,
  waktu timestamptz not null default now(),
  part_id bigint not null references public.bengkel_part(id),
  jumlah numeric not null check (jumlah > 0),
  total numeric not null check (total >= 0),
  sumber text not null default 'kas' check (sumber in ('kas','lain')),
  keterangan text,
  batal boolean not null default false,
  dicatat_oleh uuid default auth.uid()
);
create index if not exists bengkel_beli_part_idx on public.bengkel_beli(part_id);

create table if not exists public.bengkel_trx (
  id bigint generated always as identity primary key,
  waktu timestamptz not null default now(),
  plat text,
  catatan text,
  total_jasa numeric not null default 0,
  total_part numeric not null default 0,
  modal_part numeric not null default 0,
  total numeric not null default 0,
  batal boolean not null default false,
  dicatat_oleh uuid default auth.uid()
);

create table if not exists public.bengkel_trx_item (
  id bigint generated always as identity primary key,
  trx_id bigint not null references public.bengkel_trx(id) on delete cascade,
  jenis text not null check (jenis in ('jasa','part')),
  ref_id bigint,
  nama text not null,
  qty numeric not null check (qty > 0),
  harga numeric not null check (harga >= 0),
  modal numeric not null default 0
);
create index if not exists bengkel_trx_item_trx_idx on public.bengkel_trx_item(trx_id);

create table if not exists public.bengkel_kas (
  id bigint generated always as identity primary key,
  waktu timestamptz not null default now(),
  jenis text not null check (jenis in ('masuk','keluar')),
  kategori text not null,
  jumlah numeric not null check (jumlah > 0),
  keterangan text,
  trx_id bigint references public.bengkel_trx(id),
  beli_id bigint references public.bengkel_beli(id),
  batal boolean not null default false,
  dicatat_oleh uuid default auth.uid()
);
create index if not exists bengkel_kas_trx_idx on public.bengkel_kas(trx_id);
create index if not exists bengkel_kas_beli_idx on public.bengkel_kas(beli_id);

-- RLS: hanya Owner yang bisa baca; tulis hanya lewat fungsi
do $$ declare t text; begin
  foreach t in array array['bengkel_jasa','bengkel_part','bengkel_beli','bengkel_trx','bengkel_trx_item','bengkel_kas'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    if not exists (select 1 from pg_policies where schemaname='public' and tablename=t and policyname='owner_baca') then
      execute format('create policy owner_baca on public.%I for select to authenticated using ((select public.is_owner()))', t);
    end if;
  end loop;
end $$;

-- ===== Fungsi =====
create or replace function public.bengkel_cek() returns void language plpgsql security definer set search_path to 'public' as $$
begin if not public.is_owner() then raise exception 'Aplikasi bengkel khusus Owner'; end if; end $$;

create or replace function public.bengkel_saldo_kas() returns numeric language sql stable security definer set search_path to 'public' as $$
  select coalesce(sum(case when jenis='masuk' then jumlah else -jumlah end),0) from bengkel_kas where not batal;
$$;

-- Data utama untuk Beranda, Kasir, Stok
create or replace function public.bengkel_data() returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_today date := (now() at time zone 'Asia/Jakarta')::date;
begin
  perform bengkel_cek();
  return jsonb_build_object(
    'saldo_kas', bengkel_saldo_kas(),
    'jasa', coalesce((select jsonb_agg(j order by j.nama) from bengkel_jasa j where j.aktif), '[]'::jsonb),
    'part', coalesce((select jsonb_agg(p order by p.nama) from bengkel_part p where p.aktif), '[]'::jsonb),
    'hari_ini', (select jsonb_build_object('trx', count(*), 'omzet', coalesce(sum(total),0),
                  'laba', coalesce(sum(total_jasa + total_part - modal_part),0))
                 from bengkel_trx where not batal and (waktu at time zone 'Asia/Jakarta')::date = v_today),
    'trx', coalesce((select jsonb_agg(x order by x.waktu desc) from (
        select t.id, t.waktu, t.plat, t.catatan, t.total, t.batal,
          (select jsonb_agg(jsonb_build_object('jenis',i.jenis,'nama',i.nama,'qty',i.qty,'harga',i.harga) order by i.id)
             from bengkel_trx_item i where i.trx_id=t.id) item
        from bengkel_trx t order by t.waktu desc limit 30) x), '[]'::jsonb),
    'kas', coalesce((select jsonb_agg(x order by x.waktu desc) from (
        select k.id, k.waktu, k.jenis, k.kategori, k.jumlah, k.keterangan, k.batal,
               (k.trx_id is null and k.beli_id is null) manual
        from bengkel_kas k order by k.waktu desc limit 60) x), '[]'::jsonb),
    'beli', coalesce((select jsonb_agg(x order by x.waktu desc) from (
        select b.id, b.waktu, p.nama, b.jumlah, b.total, b.sumber, b.keterangan, b.batal
        from bengkel_beli b join bengkel_part p on p.id=b.part_id order by b.waktu desc limit 40) x), '[]'::jsonb)
  );
end $$;

-- Jasa: tambah / ubah / nonaktifkan
create or replace function public.bengkel_jasa_simpan(p_id bigint, p_nama text, p_harga numeric, p_aktif boolean default true)
returns bigint language plpgsql security definer set search_path to 'public' as $$
declare v_id bigint;
begin
  perform bengkel_cek();
  if coalesce(trim(p_nama),'') = '' then raise exception 'Nama jasa wajib diisi'; end if;
  if p_harga is null or p_harga < 0 then raise exception 'Harga tidak valid'; end if;
  if p_id is null then
    insert into bengkel_jasa(nama, harga) values (trim(p_nama), p_harga) returning id into v_id;
  else
    update bengkel_jasa set nama=trim(p_nama), harga=p_harga, aktif=coalesce(p_aktif,true) where id=p_id returning id into v_id;
  end if;
  return v_id;
end $$;

-- Sparepart: ubah nama / harga jual / batas menipis / nonaktifkan
create or replace function public.bengkel_part_simpan(p_id bigint, p_nama text, p_harga_jual numeric, p_stok_min numeric, p_aktif boolean default true)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  perform bengkel_cek();
  if coalesce(trim(p_nama),'') = '' then raise exception 'Nama sparepart wajib diisi'; end if;
  update bengkel_part set nama=trim(p_nama), harga_jual=greatest(coalesce(p_harga_jual,0),0),
    stok_min=greatest(coalesce(p_stok_min,0),0), aktif=coalesce(p_aktif,true) where id=p_id;
end $$;

-- Koreksi stok (hasil hitung fisik)
create or replace function public.bengkel_stok_ubah(p_id bigint, p_stok numeric)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  perform bengkel_cek();
  if p_stok is null or p_stok < 0 then raise exception 'Stok tidak valid'; end if;
  update bengkel_part set stok=p_stok where id=p_id;
end $$;

-- Beli sparepart (part baru otomatis dibuat). Harga modal ikut harga beli terbaru.
create or replace function public.bengkel_beli_part(p_part_id bigint, p_nama_baru text, p_jumlah numeric, p_total numeric,
  p_harga_jual numeric default null, p_sumber text default 'kas', p_ket text default null)
returns bigint language plpgsql security definer set search_path to 'public' as $$
declare v_part bigint := p_part_id; v_beli bigint; v_nama text;
begin
  perform bengkel_cek();
  if p_jumlah is null or p_jumlah <= 0 then raise exception 'Jumlah harus lebih dari 0'; end if;
  if p_total is null or p_total < 0 then raise exception 'Total bayar tidak valid'; end if;
  if p_sumber not in ('kas','lain') then raise exception 'Sumber uang tidak valid'; end if;
  if v_part is null then
    if coalesce(trim(p_nama_baru),'') = '' then raise exception 'Pilih sparepart atau isi nama baru'; end if;
    select id into v_part from bengkel_part where lower(nama)=lower(trim(p_nama_baru));
    if v_part is null then
      insert into bengkel_part(nama) values (trim(p_nama_baru)) returning id into v_part;
    end if;
  end if;
  update bengkel_part set stok = stok + p_jumlah, harga_modal = round(p_total / p_jumlah), aktif = true,
    harga_jual = case when coalesce(p_harga_jual,0) > 0 then p_harga_jual else harga_jual end
  where id = v_part returning nama into v_nama;
  insert into bengkel_beli(part_id, jumlah, total, sumber, keterangan) values (v_part, p_jumlah, p_total, p_sumber, nullif(trim(p_ket),''))
    returning id into v_beli;
  if p_sumber = 'kas' and p_total > 0 then
    insert into bengkel_kas(jenis, kategori, jumlah, keterangan, beli_id)
      values ('keluar', 'Beli Sparepart', p_total, v_nama || ' × ' || trim(to_char(p_jumlah,'FM999999990.##')), v_beli);
  end if;
  return v_beli;
end $$;

-- Batalkan pembelian: stok dikurangi lagi, uang kas kembali
create or replace function public.bengkel_beli_batal(p_id bigint)
returns void language plpgsql security definer set search_path to 'public' as $$
declare b bengkel_beli%rowtype;
begin
  perform bengkel_cek();
  select * into b from bengkel_beli where id=p_id for update;
  if not found or b.batal then raise exception 'Pembelian tidak ditemukan / sudah dibatalkan'; end if;
  update bengkel_beli set batal=true where id=p_id;
  update bengkel_part set stok = stok - b.jumlah where id=b.part_id;
  update bengkel_kas set batal=true where beli_id=p_id;
end $$;

-- Kasir: simpan transaksi. p_item = [{jenis:'jasa'|'part', id, nama, qty, harga}]
create or replace function public.bengkel_jual(p_item jsonb, p_plat text default null, p_catatan text default null)
returns bigint language plpgsql security definer set search_path to 'public' as $$
declare v_trx bigint; it jsonb; v_jenis text; v_qty numeric; v_harga numeric; v_nama text; v_modal numeric;
  v_ref bigint; tj numeric := 0; tp numeric := 0; mp numeric := 0;
begin
  perform bengkel_cek();
  if p_item is null or jsonb_typeof(p_item) <> 'array' or jsonb_array_length(p_item) = 0 then raise exception 'Belum ada item'; end if;
  insert into bengkel_trx(plat, catatan) values (nullif(upper(trim(p_plat)),''), nullif(trim(p_catatan),'')) returning id into v_trx;
  for it in select * from jsonb_array_elements(p_item) loop
    v_jenis := it->>'jenis'; v_qty := coalesce((it->>'qty')::numeric,1); v_harga := coalesce((it->>'harga')::numeric,0);
    v_ref := nullif(it->>'id','')::bigint; v_nama := trim(coalesce(it->>'nama',''));
    if v_qty <= 0 or v_harga < 0 then raise exception 'Jumlah/harga tidak valid'; end if;
    if v_jenis = 'part' then
      select nama, harga_modal into v_nama, v_modal from bengkel_part where id=v_ref for update;
      if not found then raise exception 'Sparepart tidak ditemukan'; end if;
      update bengkel_part set stok = stok - v_qty where id=v_ref;
      tp := tp + v_qty*v_harga; mp := mp + v_qty*v_modal;
    elsif v_jenis = 'jasa' then
      if v_nama = '' then raise exception 'Nama jasa kosong'; end if;
      v_modal := 0; tj := tj + v_qty*v_harga;
    else raise exception 'Jenis item tidak valid'; end if;
    insert into bengkel_trx_item(trx_id, jenis, ref_id, nama, qty, harga, modal) values (v_trx, v_jenis, v_ref, v_nama, v_qty, v_harga, v_modal);
  end loop;
  update bengkel_trx set total_jasa=tj, total_part=tp, modal_part=mp, total=tj+tp where id=v_trx;
  if tj + tp > 0 then
    insert into bengkel_kas(jenis, kategori, jumlah, keterangan, trx_id)
      values ('masuk', 'Penjualan', tj+tp, coalesce('Servis ' || nullif(upper(trim(p_plat)),''), 'Servis / penjualan'), v_trx);
  end if;
  return v_trx;
end $$;

-- Batalkan transaksi: stok kembali, uang kas dibatalkan
create or replace function public.bengkel_trx_batal(p_id bigint)
returns void language plpgsql security definer set search_path to 'public' as $$
declare t bengkel_trx%rowtype;
begin
  perform bengkel_cek();
  select * into t from bengkel_trx where id=p_id for update;
  if not found or t.batal then raise exception 'Transaksi tidak ditemukan / sudah dibatalkan'; end if;
  update bengkel_trx set batal=true where id=p_id;
  update bengkel_part p set stok = p.stok + i.qty from bengkel_trx_item i where i.trx_id=p_id and i.jenis='part' and p.id=i.ref_id;
  update bengkel_kas set batal=true where trx_id=p_id;
end $$;

-- Kas Bengkel: catat uang masuk/keluar manual
create or replace function public.bengkel_kas_catat(p_jenis text, p_kategori text, p_jumlah numeric, p_ket text default null)
returns bigint language plpgsql security definer set search_path to 'public' as $$
declare v_id bigint;
begin
  perform bengkel_cek();
  if p_jenis not in ('masuk','keluar') then raise exception 'Jenis tidak valid'; end if;
  if p_jumlah is null or p_jumlah <= 0 then raise exception 'Jumlah harus lebih dari 0'; end if;
  if coalesce(trim(p_kategori),'') = '' then raise exception 'Pilih kategori'; end if;
  insert into bengkel_kas(jenis, kategori, jumlah, keterangan) values (p_jenis, trim(p_kategori), p_jumlah, nullif(trim(p_ket),''))
    returning id into v_id;
  return v_id;
end $$;

create or replace function public.bengkel_kas_batal(p_id bigint)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  perform bengkel_cek();
  update bengkel_kas set batal=true where id=p_id and trx_id is null and beli_id is null and not batal;
  if not found then raise exception 'Catatan ini tidak bisa dibatalkan di sini (batalkan lewat transaksi/pembelian)'; end if;
end $$;

-- Laporan periode (tanggal WIB, inklusif)
create or replace function public.bengkel_laporan(p_dari date, p_sampai date)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r jsonb;
begin
  perform bengkel_cek();
  with t as (select * from bengkel_trx where not batal and (waktu at time zone 'Asia/Jakarta')::date between p_dari and p_sampai),
  k as (select * from bengkel_kas where not batal and trx_id is null and beli_id is null and jenis='keluar'
          and kategori <> 'Ambil Owner' and (waktu at time zone 'Asia/Jakarta')::date between p_dari and p_sampai)
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
end $$;

-- Izin: cabut dari publik/anon, beri ke user login (dicek Owner di dalam fungsi)
do $$ declare f text; begin
  foreach f in array array[
    'bengkel_cek()','bengkel_saldo_kas()','bengkel_data()',
    'bengkel_jasa_simpan(bigint,text,numeric,boolean)','bengkel_part_simpan(bigint,text,numeric,numeric,boolean)',
    'bengkel_stok_ubah(bigint,numeric)','bengkel_beli_part(bigint,text,numeric,numeric,numeric,text,text)',
    'bengkel_beli_batal(bigint)','bengkel_jual(jsonb,text,text)','bengkel_trx_batal(bigint)',
    'bengkel_kas_catat(text,text,numeric,text)','bengkel_kas_batal(bigint)','bengkel_laporan(date,date)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  revoke execute on function public.bengkel_cek() from authenticated;
  revoke execute on function public.bengkel_saldo_kas() from authenticated;
end $$;
