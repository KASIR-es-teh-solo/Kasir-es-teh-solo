-- 2026-11-21: tanggal uji coba SO per cabang (selain Jumat), tanpa mengubah jadwal Jumat.
-- cabang.opname_uji = tanggal uji; opname_hari_so() = Jumat ATAU tanggal uji.
-- Dipakai di kasir_opname_status (v_jumat), kasir_opname_kirim (cek hari), meyadmin_opname_ambil (belum_kirim).
alter table public.cabang add column if not exists opname_uji date;
create or replace function public.opname_hari_so(p_cabang uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select extract(isodow from opname_wib()) = 5 or opname_wib()::date = (select opname_uji from cabang where id = p_cabang) $$;
do $$
declare d text;
begin
  d := pg_get_functiondef('public.kasir_opname_status(uuid)'::regprocedure);
  execute replace(d, 'v_jumat := extract(isodow from w) = 5;', 'v_jumat := opname_hari_so(p_cabang);');
  d := pg_get_functiondef('public.kasir_opname_kirim(uuid,jsonb)'::regprocedure);
  execute replace(d, 'if extract(isodow from w) <> 5 then', 'if not opname_hari_so(p_cabang) then');
  d := pg_get_functiondef('public.meyadmin_opname_ambil(text)'::regprocedure);
  execute replace(d, 'where extract(isodow from opname_wib()) = 5 and', 'where opname_hari_so(c.id) and');
end $$;
-- uji coba Sabtu 21 Nov 2026 cabang Pusat Dermo (permintaan Boss)
update public.cabang set opname_uji = date '2026-11-21' where id = '199e77b5-f52e-4534-9656-3a0d8fceddfd';
