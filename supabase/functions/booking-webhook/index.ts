// Cal.com webhook: records each booking, reschedule and cancellation of a call with Alex.
// The database turns each one into a Telegram alert (ops.on_call_event).
// Requires the CAL_WEBHOOK_SECRET function secret, the same value as the webhook's secret in Cal.com.
// Deployed with JWT verification off: Cal.com can't send a Supabase token, so the signature is the check.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const enc = new TextEncoder();
const EVENTS = ["BOOKING_CREATED", "BOOKING_RESCHEDULED", "BOOKING_CANCELLED"];

// Cal.com signs the raw body: X-Cal-Signature-256 = hex HMAC-SHA256(secret, body)
async function validSignature(payload: string, header: string, secret: string): Promise<boolean> {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(payload)));
  const expected = Array.from(mac, (b) => b.toString(16).padStart(2, "0")).join("");
  const got = header.trim().toLowerCase();
  return got.length === expected.length && [...got].every((c, i) => c === expected[i]);
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const secret = Deno.env.get("CAL_WEBHOOK_SECRET");
  if (!secret) return new Response("CAL_WEBHOOK_SECRET is not set", { status: 500 });
  const body = await req.text();
  if (!(await validSignature(body, req.headers.get("x-cal-signature-256") || "", secret))) {
    return new Response("Invalid signature", { status: 400 });
  }
  let evt;
  try { evt = JSON.parse(body); } catch { return new Response("Bad JSON", { status: 400 }); }
  const kind = evt.triggerEvent;
  if (!EVENTS.includes(kind)) return new Response("Ignored", { status: 200 });  // Cal.com's "Ping test" lands here too
  const p = evt.payload || {};
  const who = (p.attendees || [])[0] || {};
  const email = who.email || p.responses?.email?.value || p.responses?.email;
  if (!p.uid || !email) return new Response("No booking id or email", { status: 200 });
  const notes = [p.description, p.additionalNotes, p.responses?.notes?.value].find((x) => typeof x === "string" && x.trim()) || "";

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { error } = await sb.rpc("record_booking", {
    p_event: kind, p_uid: p.uid, p_email: email, p_name: who.name || p.responses?.name?.value || "",
    p_start: p.startTime || null, p_notes: notes, p_old_uid: p.rescheduleUid || p.rescheduledFromUid || null,
  });
  if (error) {
    console.error("record_booking failed", error);
    return new Response("Couldn't record the booking", { status: 500 });  // Cal.com retries
  }
  return new Response("OK", { status: 200 });
});
