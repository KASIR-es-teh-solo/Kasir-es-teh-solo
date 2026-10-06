// Asisten Nota — membaca foto/ketikan nota belanja lalu MENGUSULKAN daftar pembelian.
// Fungsi ini TIDAK menyimpan apa pun ke database pembelian: hasilnya dicek & disimpan sendiri oleh admin/owner di aplikasi.
// Butuh secret ANTHROPIC_API_KEY (Supabase Dashboard > Edge Functions > Secrets).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const jawab = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { ...cors, "Content-Type": "application/json" } });

const MODEL = "claude-haiku-4-5-20251001";
const BATAS_HARIAN = 40;            // pengaman saldo: maksimal 40 kali baca per hari (semua user)
const MAKS_GAMBAR = 4_500_000;      // ± 3,3 MB gambar asli (base64)

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const auth = req.headers.get("Authorization");
    if (!auth) return jawab({ error: "Tidak ada token otorisasi." }, 401);
    const url = Deno.env.get("SUPABASE_URL")!;
    const caller = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
    const { data: u } = await caller.auth.getUser();
    if (!u?.user) return jawab({ error: "Sesi tidak valid, silakan login ulang." }, 401);
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: prof } = await admin.from("users").select("role").eq("id", u.user.id).single();
    if (!prof || !["owner", "admin"].includes(prof.role)) return jawab({ error: "Hanya Owner/Admin yang boleh memakai Asisten Nota." }, 403);

    const key = Deno.env.get("ANTHROPIC_API_KEY");
    if (!key) return jawab({ error: "Kunci API Claude belum dipasang. Minta Owner/Mey memasang ANTHROPIC_API_KEY." }, 503);

    const awalHari = new Date(Date.now() + 7 * 3600e3); awalHari.setUTCHours(0, 0, 0, 0);
    const sejak = new Date(awalHari.getTime() - 7 * 3600e3).toISOString();
    const { count } = await admin.from("asisten_nota_pakai").select("id", { count: "exact", head: true }).gte("created_at", sejak);
    if ((count ?? 0) >= BATAS_HARIAN) return jawab({ error: `Batas harian Asisten Nota (${BATAS_HARIAN}x) sudah tercapai. Coba lagi besok atau catat manual.` }, 429);

    const body = await req.json().catch(() => ({}));
    const teks = String(body?.teks || "").slice(0, 3000).trim();
    const gambar = typeof body?.gambar === "string" ? body.gambar : "";
    const mediaType = ["image/jpeg", "image/png", "image/webp"].includes(body?.media_type) ? body.media_type : "image/jpeg";
    if (!teks && !gambar) return jawab({ error: "Kirim foto nota atau ketik isi belanjaannya." }, 400);
    if (gambar.length > MAKS_GAMBAR) return jawab({ error: "Foto terlalu besar." }, 413);

    const { data: bahan } = await admin.from("bahan_baku").select("id, nama, satuan, satuan_beli, konversi").order("nama");
    const daftar = (bahan || []).map((b) => {
      const sat = b.satuan_beli || b.satuan;
      return `- id=${b.id} | ${b.nama} | jumlah ditulis dalam: ${sat}` + (b.konversi ? ` (1 ${sat} = ${b.konversi} ${b.satuan})` : "");
    }).join("\n");

    const instruksi = `Kamu membantu outlet es teh mencatat nota belanja bahan baku.
Daftar bahan baku yang ada di sistem:
${daftar}

Tugas: baca nota (foto dan/atau teks), lalu cocokkan setiap baris belanja ke SATU bahan di daftar.
Aturan:
- "BR ..." / "bubuk ..." = bubuk rasa. "Black cookies and cream" = Oreo (Cho Cho Oreo). "Coffe caramel" = bubuk Caramel.
- "jumlah" HARUS dalam satuan yang tertulis di daftar. Ubah berat: 1KG = 1000 gram, 500GR = 500 gram. Kalau berat tidak tertulis dan satuan gram, tebak dari kemasan sejenis lalu isi "ragu": true.
- "total" = harga total baris itu dalam rupiah (angka bulat, tanpa titik).
- Kalau tidak ada bahan yang cocok, isi bahan_baku_id = null.
- Jangan mengarang baris yang tidak ada di nota.
Balas HANYA JSON tanpa teks lain, format:
{"items":[{"teks_nota":"...","bahan_baku_id":"... atau null","jumlah":0,"total":0,"ragu":false}],"total_nota":0,"catatan":"..."}`;

    const konten: unknown[] = [];
    if (gambar) konten.push({ type: "image", source: { type: "base64", media_type: mediaType, data: gambar } });
    konten.push({ type: "text", text: instruksi + (teks ? `\n\nIsi nota yang diketik:\n${teks}` : "") });

    const r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({ model: MODEL, max_tokens: 1500, messages: [{ role: "user", content: konten }] }),
    });
    const hasil = await r.json();
    await admin.from("asisten_nota_pakai").insert({
      user_id: u.user.id, berhasil: r.ok,
      token_masuk: hasil?.usage?.input_tokens ?? null, token_keluar: hasil?.usage?.output_tokens ?? null,
    });
    if (!r.ok) {
      const pesan = hasil?.error?.message || "Gagal menghubungi AI.";
      const habis = /credit|balance|billing/i.test(pesan);
      return jawab({ error: habis ? "Saldo kunci API Claude habis. Minta Owner mengisi saldo." : "AI gagal membaca: " + pesan }, 502);
    }
    const out = (hasil.content || []).map((c: { text?: string }) => c.text || "").join("");
    const m = out.match(/\{[\s\S]*\}/);
    if (!m) return jawab({ error: "AI tidak bisa membaca nota. Coba foto lebih jelas atau ketik manual." }, 422);
    let data: { items?: unknown[]; total_nota?: number; catatan?: string };
    try { data = JSON.parse(m[0]); } catch { return jawab({ error: "Hasil AI tidak terbaca. Coba lagi." }, 422); }

    const idValid = new Set((bahan || []).map((b) => b.id));
    const items = (Array.isArray(data.items) ? data.items : []).slice(0, 40).map((it: any) => ({
      teks_nota: String(it?.teks_nota || "").slice(0, 120),
      bahan_baku_id: idValid.has(it?.bahan_baku_id) ? it.bahan_baku_id : null,
      jumlah: Math.max(0, Number(it?.jumlah) || 0),
      total: Math.max(0, Math.round(Number(it?.total) || 0)),
      ragu: !!it?.ragu || !idValid.has(it?.bahan_baku_id),
    }));
    return jawab({ items, total_nota: Math.round(Number(data.total_nota) || 0), catatan: String(data.catatan || "").slice(0, 300) });
  } catch (e) {
    return jawab({ error: (e as Error)?.message || "Terjadi kesalahan pada server." }, 500);
  }
});
