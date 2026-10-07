// Stripe webhook: when a farmer finishes the $500 Payment Link checkout, mark their enrollment paid.
// The portal opens the Payment Link with ?client_reference_id=<farmer's user id>.
// Requires the STRIPE_WEBHOOK_SECRET function secret (whsec_...).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const enc = new TextEncoder();
const TOLERANCE_SECONDS = 300;

async function validSignature(payload: string, header: string, secret: string): Promise<boolean> {
  const parts = Object.fromEntries(header.split(",").map((kv) => kv.split("=", 2)) as [string, string][]);
  const t = Number(parts.t);
  const sigs = header.split(",").filter((kv) => kv.startsWith("v1=")).map((kv) => kv.slice(3));
  if (!t || !sigs.length || Math.abs(Date.now() / 1000 - t) > TOLERANCE_SECONDS) return false;
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(`${t}.${payload}`)));
  const expected = Array.from(mac, (b) => b.toString(16).padStart(2, "0")).join("");
  return sigs.some((s) => s.length === expected.length && [...s].every((c, i) => c === expected[i]));
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const secret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
  if (!secret) return new Response("Webhook secret not configured", { status: 500 });

  const payload = await req.text();
  if (!(await validSignature(payload, req.headers.get("stripe-signature") ?? "", secret))) {
    return new Response("Invalid signature", { status: 400 });
  }

  const event = JSON.parse(payload);
  if (event.type !== "checkout.session.completed") return new Response("ignored", { status: 200 });

  const session = event.data.object;
  const ref: string | null = session.client_reference_id;
  const farmerId = ref && /^[0-9a-f-]{36}$/i.test(ref) ? ref : null;
  const email: string | null = session.customer_details?.email ?? null;
  if (session.payment_status !== "paid") return new Response("not paid", { status: 200 });

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  let q = db.from("profiles").update({ enrollment_paid: true });
  q = farmerId ? q.eq("id", farmerId) : q.eq("email", (email ?? "").toLowerCase());
  const { data, error } = await q.select("id");
  if (error) return new Response(error.message, { status: 500 });
  if (!data?.length) console.warn("No farmer matched checkout", session.id, farmerId, email);
  return new Response(JSON.stringify({ updated: data?.length ?? 0 }), { headers: { "Content-Type": "application/json" } });
});
