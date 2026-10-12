-- 2026-10-12: pesanan online (Shopee/Grab) dicatat metode_bayar = 'online'
-- (harga outlet, stok berkurang, TIDAK masuk saldo kas laci, tidak ikut program stempel). Sudah dijalankan.
CREATE OR REPLACE FUNCTION public.paksa_metode_tunai()
 RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public'
AS $function$
begin
  if coalesce(new.metode_bayar, '') <> 'online' then
    new.metode_bayar := 'tunai';
  end if;
  return new;
end $function$;
-- stempel_cek: transaksi terakhir yang dicek mengabaikan metode_bayar = 'online'
-- (lihat migrasi Supabase "stempel_cek_abaikan_online")
