-- 2026-10-07 (SUDAH DIJALANKAN oleh Mey, dites dalam mode uji lalu dibatalkan) — Stempel Digital Es Teh Original besar (10 stempel = gratis 1 Original besar)
-- Pembeli: scan QR di meja kasir -> halaman stempel.html (tanpa login, dikenali lewat token di HP).
-- Aturan: hanya transaksi TERAKHIR di cabang, maks 3 menit setelah bayar, harus ada Original besar,
--         1 transaksi 1 klaim, 1 pelanggan jeda 15 menit, stempel = jumlah Original besar.
-- Kasir: notifikasi klaim + Batalkan, +stempel manual, tukar kode hadiah -> transaksi gratis otomatis.

create table if not exists public.stempel_pelanggan (
  id uuid primary key default gen_random_uuid(),
  nama text not null,
  wa text not null unique,
  token uuid not null unique default gen_random_uuid(),
  stempel int not null default 0,
  total_cup int not null default 0,
  cabang_id uuid references public.cabang(id),
  created_at timestamptz not null default now(),
  terakhir_klaim timestamptz,
  diblokir boolean not null default false
);
create table if not exists public.stempel_klaim (
  id uuid primary key default gen_random_uuid(),
  pelanggan_id uuid not null references public.stempel_pelanggan(id),
  transaksi_id uuid references public.transaksi(id),
  cabang_id uuid references public.cabang(id),
  jumlah int not null check (jumlah > 0),
  jenis text not null default 'scan' check (jenis in ('scan','manual')),
  dibuat_oleh uuid,
  created_at timestamptz not null default now(),
  dibatalkan_at timestamptz,
  dibatalkan_oleh uuid
);
create unique index if not exists stempel_klaim_transaksi_aktif on public.stempel_klaim(transaksi_id) where transaksi_id is not null and dibatalkan_at is null;
create index if not exists stempel_klaim_cabang_waktu on public.stempel_klaim(cabang_id, created_at desc);
create table if not exists public.stempel_hadiah (
  id uuid primary key default gen_random_uuid(),
  pelanggan_id uuid not null references public.stempel_pelanggan(id),
  kode text not null,
  dibuat_at timestamptz not null default now(),
  berlaku_sampai timestamptz not null,
  dipakai_at timestamptz,
  dipakai_oleh uuid,
  transaksi_id uuid references public.transaksi(id),
  cabang_id uuid references public.cabang(id)
);
create index if not exists stempel_hadiah_kode on public.stempel_hadiah(kode) where dipakai_at is null;
alter table public.stempel_pelanggan enable row level security;
alter table public.stempel_klaim enable row level security;
alter table public.stempel_hadiah enable row level security;
-- tidak ada policy: semua akses lewat fungsi di bawah

-- ---------- bantuan ----------
create or replace function public.stempel_wa_normal(p text) returns text language sql immutable set search_path to 'public' as $$
  select case when d like '62%' then '0' || substr(d, 3) else d end
  from (select regexp_replace(coalesce(p,''), '[^0-9]', '', 'g') d) x $$;

create or replace function public.stempel_produk_ori() returns uuid language sql stable security definer set search_path to 'public' as $$
  select id from produk where nama = 'Es Teh Solo Original' limit 1 $$;

-- buat kode hadiah kalau stempel >= 10 dan belum ada kode aktif hari ini
create or replace function public.stempel_siapkan_hadiah(p_pel uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
declare v_kode text; v_akhir timestamptz := (date_trunc('day', now() at time zone 'Asia/Jakarta') + interval '1 day' - interval '1 second') at time zone 'Asia/Jakarta';
begin
  if (select stempel from stempel_pelanggan where id = p_pel) < 10 then return; end if;
  if exists (select 1 from stempel_hadiah where pelanggan_id = p_pel and dipakai_at is null and berlaku_sampai > now()) then return; end if;
  loop
    v_kode := lpad((floor(random() * 10000))::int::text, 4, '0');
    exit when not exists (select 1 from stempel_hadiah where kode = v_kode and dipakai_at is null and berlaku_sampai > now());
  end loop;
  insert into stempel_hadiah(pelanggan_id, kode, berlaku_sampai) values (p_pel, v_kode, v_akhir);
end $$;

create or replace function public.stempel_info(p_pel uuid) returns json
language plpgsql security definer set search_path to 'public' as $$
declare r record; h record; v_tunggu int := 0;
begin
  perform stempel_siapkan_hadiah(p_pel);
  select * into r from stempel_pelanggan where id = p_pel;
  select kode, berlaku_sampai into h from stempel_hadiah where pelanggan_id = p_pel and dipakai_at is null and berlaku_sampai > now() order by dibuat_at desc limit 1;
  if r.terakhir_klaim is not null and r.terakhir_klaim > now() - interval '15 minutes' then
    v_tunggu := ceil(extract(epoch from (r.terakhir_klaim + interval '15 minutes' - now())))::int;
  end if;
  return json_build_object('nama', r.nama, 'stempel', r.stempel, 'total_cup', r.total_cup,
    'hadiah_kode', h.kode, 'hadiah_sampai', h.berlaku_sampai, 'tunggu_detik', v_tunggu, 'diblokir', r.diblokir);
end $$;

-- ---------- untuk pembeli (tanpa login) ----------
create or replace function public.stempel_daftar(p_nama text, p_wa text, p_cabang uuid default null) returns json
language plpgsql security definer set search_path to 'public' as $$
declare v_wa text := stempel_wa_normal(p_wa); v_nama text := btrim(regexp_replace(coalesce(p_nama,''), '\s+', ' ', 'g')); r record;
begin
  if length(v_nama) < 2 or length(v_nama) > 30 then raise exception 'Isi nama (2–30 huruf).'; end if;
  if v_wa !~ '^08[0-9]{8,12}$' then raise exception 'Nomor WA tidak valid. Contoh: 0812 3456 7890'; end if;
  select * into r from stempel_pelanggan where wa = v_wa;
  if found then raise exception 'Nomor WA ini sudah terdaftar. Pilih "Sudah pernah daftar?" untuk memulihkan.'; end if;
  insert into stempel_pelanggan(nama, wa, cabang_id) values (v_nama, v_wa, p_cabang) returning * into r;
  return (json_build_object('token', r.token)::jsonb || stempel_info(r.id)::jsonb)::json;
end $$;

-- pulihkan di HP baru: nomor WA + nama depan harus cocok; token lama diganti (HP lama otomatis keluar)
create or replace function public.stempel_pulihkan(p_nama text, p_wa text) returns json
language plpgsql security definer set search_path to 'public' as $$
declare r record; v_wa text := stempel_wa_normal(p_wa);
begin
  select * into r from stempel_pelanggan where wa = v_wa;
  if not found or split_part(lower(btrim(r.nama)), ' ', 1) <> split_part(lower(btrim(coalesce(p_nama,''))), ' ', 1) then
    raise exception 'Nomor WA & nama tidak cocok. Tanya kasir kalau lupa.';
  end if;
  update stempel_pelanggan set token = gen_random_uuid() where id = r.id returning * into r;
  return (json_build_object('token', r.token)::jsonb || stempel_info(r.id)::jsonb)::json;
end $$;

create or replace function public.stempel_status(p_token uuid) returns json
language plpgsql security definer set search_path to 'public' as $$
declare v uuid;
begin
  select id into v from stempel_pelanggan where token = p_token;
  if v is null then return json_build_object('terdaftar', false); end if;
  return (json_build_object('terdaftar', true)::jsonb || stempel_info(v)::jsonb)::json;
end $$;

-- pesanan terakhir yang bisa diambil stempelnya (tanpa mengubah apa pun)
create or replace function public.stempel_cek(p_token uuid, p_cabang uuid) returns json
language plpgsql security definer set search_path to 'public' as $$
declare p record; t record; v_jml int; v_ori uuid := stempel_produk_ori();
begin
  select * into p from stempel_pelanggan where token = p_token;
  if not found then return json_build_object('ada', false, 'alasan', 'belum_daftar'); end if;
  if p.diblokir then return json_build_object('ada', false, 'alasan', 'diblokir'); end if;
  if p.terakhir_klaim is not null and p.terakhir_klaim > now() - interval '15 minutes' then
    return json_build_object('ada', false, 'alasan', 'tunggu',
      'tunggu_detik', ceil(extract(epoch from (p.terakhir_klaim + interval '15 minutes' - now())))::int);
  end if;
  select * into t from transaksi where cabang_id = p_cabang and status = 'selesai' order by created_at desc limit 1;
  if not found or t.created_at < now() - interval '3 minutes' or t.total <= 0 then
    return json_build_object('ada', false, 'alasan', 'tidak_ada');
  end if;
  select coalesce(sum(qty),0) into v_jml from transaksi_item where transaksi_id = t.id and produk_id = v_ori and lower(coalesce(ukuran,'')) = 'besar';
  if v_jml < 1 then return json_build_object('ada', false, 'alasan', 'bukan_ori_besar'); end if;
  if exists (select 1 from stempel_klaim where transaksi_id = t.id and dibatalkan_at is null) then
    return json_build_object('ada', false, 'alasan', 'sudah_diambil');
  end if;
  return json_build_object('ada', true, 'transaksi_id', t.id, 'jumlah', v_jml,
    'jam', to_char(t.created_at at time zone 'Asia/Jakarta', 'HH24.MI'));
end $$;

create or replace function public.stempel_klaim(p_token uuid, p_transaksi uuid) returns json
language plpgsql security definer set search_path to 'public' as $$
declare p record; t record; v_cek json;
begin
  select * into t from transaksi where id = p_transaksi;
  if not found then raise exception 'Pesanan tidak ditemukan.'; end if;
  perform pg_advisory_xact_lock(hashtext('stempel_' || t.cabang_id::text));
  v_cek := stempel_cek(p_token, t.cabang_id);
  if not (v_cek->>'ada')::boolean then
    raise exception '%', case v_cek->>'alasan'
      when 'tunggu' then 'Tunggu ' || ceil((v_cek->>'tunggu_detik')::int / 60.0) || ' menit lagi ya.'
      when 'sudah_diambil' then 'Stempel pesanan ini sudah diambil.'
      when 'belum_daftar' then 'Daftar dulu ya.'
      when 'diblokir' then 'Akun stempel ini diblokir. Hubungi kasir.'
      else 'Pesanan sudah tidak bisa diambil. Scan langsung setelah bayar ya.' end;
  end if;
  if (v_cek->>'transaksi_id')::uuid <> p_transaksi then
    raise exception 'Pesanan sudah berganti. Scan ulang ya.';
  end if;
  select * into p from stempel_pelanggan where token = p_token for update;
  insert into stempel_klaim(pelanggan_id, transaksi_id, cabang_id, jumlah) values (p.id, p_transaksi, t.cabang_id, (v_cek->>'jumlah')::int);
  update stempel_pelanggan set stempel = stempel + (v_cek->>'jumlah')::int, total_cup = total_cup + (v_cek->>'jumlah')::int,
    terakhir_klaim = now() where id = p.id;
  return (json_build_object('tambah', (v_cek->>'jumlah')::int)::jsonb || stempel_info(p.id)::jsonb)::json;
end $$;

-- ---------- untuk kasir / owner / admin ----------
create or replace function public.stempel_klaim_terbaru(p_cabang uuid, p_sejak timestamptz) returns json
language plpgsql security definer set search_path to 'public' as $$
begin
  if not is_pegawai() then raise exception 'Tidak diizinkan'; end if;
  return coalesce((select json_agg(x order by x.created_at) from (
    select k.id, k.jumlah, k.jenis, k.created_at, k.dibatalkan_at, p.nama, p.stempel
      from stempel_klaim k join stempel_pelanggan p on p.id = k.pelanggan_id
     where k.cabang_id = p_cabang and k.created_at > p_sejak and k.jenis = 'scan'
     order by k.created_at desc limit 20) x), '[]'::json);
end $$;

create or replace function public.stempel_cari(p_cari text default '') returns json
language plpgsql security definer set search_path to 'public' as $$
declare v text := lower(btrim(coalesce(p_cari,''))); v_wa text := stempel_wa_normal(p_cari);
begin
  if not is_pegawai() then raise exception 'Tidak diizinkan'; end if;
  return coalesce((select json_agg(x) from (
    select p.id, p.nama, '…' || right(p.wa, 4) wa, p.stempel, p.total_cup, p.terakhir_klaim, p.diblokir,
           (select kode from stempel_hadiah h where h.pelanggan_id = p.id and h.dipakai_at is null and h.berlaku_sampai > now() order by dibuat_at desc limit 1) kode
      from stempel_pelanggan p
     where v = '' or lower(p.nama) like '%' || v || '%' or (length(v_wa) >= 3 and p.wa like '%' || v_wa || '%')
        or exists (select 1 from stempel_hadiah h where h.pelanggan_id = p.id and h.kode = v and h.dipakai_at is null and h.berlaku_sampai > now())
     order by p.terakhir_klaim desc nulls last, p.created_at desc limit 30) x), '[]'::json);
end $$;

create or replace function public.stempel_tambah(p_pelanggan uuid, p_jumlah int, p_cabang uuid) returns json
language plpgsql security definer set search_path to 'public' as $$
declare r record;
begin
  if not is_pegawai() then raise exception 'Tidak diizinkan'; end if;
  if p_jumlah is null or p_jumlah < 1 or p_jumlah > 5 then raise exception 'Jumlah 1–5 stempel.'; end if;
  insert into stempel_klaim(pelanggan_id, cabang_id, jumlah, jenis, dibuat_oleh) values (p_pelanggan, p_cabang, p_jumlah, 'manual', auth.uid());
  update stempel_pelanggan set stempel = stempel + p_jumlah, total_cup = total_cup + p_jumlah where id = p_pelanggan returning * into r;
  insert into log_aktivitas(cabang_id, user_id, aksi, keterangan) values (p_cabang, auth.uid(), 'Stempel manual', '+' || p_jumlah || ' stempel untuk ' || r.nama || ' (sekarang ' || r.stempel || '/10)');
  perform stempel_siapkan_hadiah(p_pelanggan);
  return stempel_info(p_pelanggan);
end $$;

create or replace function public.stempel_batalkan(p_klaim uuid) returns json
language plpgsql security definer set search_path to 'public' as $$
declare k record; r record; v_role text;
begin
  select role into v_role from users where id = auth.uid();
  if v_role is null then raise exception 'Tidak diizinkan'; end if;
  select * into k from stempel_klaim where id = p_klaim for update;
  if not found or k.dibatalkan_at is not null then raise exception 'Klaim tidak ada / sudah dibatalkan.'; end if;
  if v_role = 'kasir' and k.created_at < now() - interval '15 minutes' then raise exception 'Sudah lewat 15 menit, minta Owner/Admin yang membatalkan.'; end if;
  update stempel_klaim set dibatalkan_at = now(), dibatalkan_oleh = auth.uid() where id = p_klaim;
  update stempel_pelanggan set stempel = greatest(stempel - k.jumlah, 0), total_cup = greatest(total_cup - k.jumlah, 0),
    terakhir_klaim = null where id = k.pelanggan_id returning * into r;
  if r.stempel < 10 then
    update stempel_hadiah set berlaku_sampai = now() where pelanggan_id = r.id and dipakai_at is null and berlaku_sampai > now();
  end if;
  insert into log_aktivitas(cabang_id, user_id, aksi, keterangan) values (k.cabang_id, auth.uid(), 'Stempel dibatalkan', k.jumlah || ' stempel milik ' || r.nama || ' dicabut (sekarang ' || r.stempel || '/10)');
  return json_build_object('nama', r.nama, 'stempel', r.stempel);
end $$;

-- tukar kode hadiah: otomatis buat transaksi 1 Original besar GRATIS (stok ikut berkurang, omzet Rp0)
create or replace function public.stempel_tukar(p_kode text, p_cabang uuid) returns json
language plpgsql security definer set search_path to 'public' as $$
declare h record; r record; v_role text; v_tx uuid; v_ori uuid := stempel_produk_ori(); v_harga numeric;
begin
  select role into v_role from users where id = auth.uid();
  if v_role is null or v_role not in ('kasir','owner') then raise exception 'Hanya kasir/owner yang bisa menukar hadiah.'; end if;
  select * into h from stempel_hadiah where kode = btrim(p_kode) and dipakai_at is null and berlaku_sampai > now() for update;
  if not found then raise exception 'Kode hadiah tidak berlaku / sudah dipakai.'; end if;
  select * into r from stempel_pelanggan where id = h.pelanggan_id for update;
  if r.stempel < 10 then raise exception 'Stempel % belum 10.', r.nama; end if;
  select harga_besar into v_harga from produk where id = v_ori;
  insert into transaksi(kasir_id, cabang_id, total, subtotal, diskon, metode_bayar, client_tx_id)
    values (auth.uid(), p_cabang, 0, v_harga, v_harga, 'tunai', 'hadiah-stempel-' || h.id) returning id into v_tx;
  insert into transaksi_item(transaksi_id, produk_id, ukuran, harga_satuan, qty, subtotal) values (v_tx, v_ori, 'besar', v_harga, 1, v_harga);
  update stempel_hadiah set dipakai_at = now(), dipakai_oleh = auth.uid(), transaksi_id = v_tx, cabang_id = p_cabang where id = h.id;
  update stempel_pelanggan set stempel = stempel - 10 where id = r.id returning * into r;
  insert into log_aktivitas(cabang_id, user_id, aksi, keterangan) values (p_cabang, auth.uid(), 'Hadiah stempel ditukar', r.nama || ' dapat 1 Es Teh Original besar GRATIS (kode ' || h.kode || ')');
  return json_build_object('nama', r.nama, 'stempel', r.stempel, 'transaksi_id', v_tx);
end $$;

create or replace function public.stempel_blokir(p_pelanggan uuid, p_blokir boolean) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if not is_admin_or_owner() then raise exception 'Hanya Owner/Admin.'; end if;
  update stempel_pelanggan set diblokir = p_blokir where id = p_pelanggan;
end $$;

-- hak akses
revoke all on function public.stempel_siapkan_hadiah(uuid), public.stempel_info(uuid), public.stempel_produk_ori() from public, anon, authenticated;
revoke all on function public.stempel_daftar(text,text,uuid), public.stempel_pulihkan(text,text), public.stempel_status(uuid),
  public.stempel_cek(uuid,uuid), public.stempel_klaim(uuid,uuid) from public;
grant execute on function public.stempel_daftar(text,text,uuid), public.stempel_pulihkan(text,text), public.stempel_status(uuid),
  public.stempel_cek(uuid,uuid), public.stempel_klaim(uuid,uuid) to anon, authenticated;
revoke all on function public.stempel_klaim_terbaru(uuid,timestamptz), public.stempel_cari(text), public.stempel_tambah(uuid,int,uuid),
  public.stempel_batalkan(uuid), public.stempel_tukar(text,uuid), public.stempel_blokir(uuid,boolean) from public, anon;
grant execute on function public.stempel_klaim_terbaru(uuid,timestamptz), public.stempel_cari(text), public.stempel_tambah(uuid,int,uuid),
  public.stempel_batalkan(uuid), public.stempel_tukar(text,uuid), public.stempel_blokir(uuid,boolean) to authenticated;
