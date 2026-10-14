-- 2026-10-15 · Admin (Boss Puspita) boleh pakai halaman Kasir (POS): simpan transaksi & tukar hadiah stempel
-- Admin dicek terdaftar di cabangnya, sama seperti kasir.
do $$
declare d text;
begin
  d := pg_get_functiondef('public.simpan_transaksi(uuid,numeric,numeric,numeric,text,jsonb,timestamptz,boolean,uuid,text)'::regprocedure);
  if position($q$v_role not in ('kasir', 'owner')$q$ in d) = 0 then raise exception 'pola role simpan_transaksi tidak ketemu'; end if;
  d := replace(d, $q$v_role not in ('kasir', 'owner')$q$, $q$v_role not in ('kasir', 'owner', 'admin')$q$);
  d := replace(d, $q$if v_role = 'kasir' and not exists (select 1 from user_cabang$q$, $q$if v_role in ('kasir', 'admin') and not exists (select 1 from user_cabang$q$);
  execute d;

  select pg_get_functiondef(p.oid) into d from pg_proc p where p.proname = 'stempel_tukar' and p.pronamespace = 'public'::regnamespace;
  if d !~ $q$in \('kasir', ?'owner'\)$q$ then raise exception 'pola role stempel_tukar tidak ketemu'; end if;
  d := regexp_replace(d, $q$in \('kasir', ?'owner'\)$q$, $q$in ('kasir', 'owner', 'admin')$q$, 'g');
  execute d;
end $$;
