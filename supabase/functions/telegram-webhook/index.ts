// Telegram webhook for LF Jarvis: Alex's taps on Yes/No buttons and replies to alerts.
// The database decides what each tap does (public.telegram_update) and hands back the Telegram calls to make.
// Uses the TELEGRAM_BOT_TOKEN function secret (same value as the Vault telegram_bot_token).
// Deployed with JWT verification off: Telegram can't send a Supabase token, so its secret header is the check.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const token = Deno.env.get("TELEGRAM_BOT_TOKEN");
  if (!token) return new Response("TELEGRAM_BOT_TOKEN is not set", { status: 500 });
  let update;
  try { update = await req.json(); } catch { return new Response("Bad JSON", { status: 400 }); }

  const { data, error } = await sb.rpc("telegram_update", {
    p_secret: req.headers.get("x-telegram-bot-api-secret-token"),
    p_update: update,
  });
  if (error) {
    console.warn("telegram_update failed", error.message);
    // A wrong secret means the caller isn't Telegram. Anything else is ours, and a Telegram retry wouldn't help.
    if (error.message.includes("bad secret")) return new Response("Forbidden", { status: 401 });
    return new Response("ok");
  }

  for (const call of data?.calls ?? []) {
    const res = await fetch(`https://api.telegram.org/bot${token}/${call.method}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(call.body),
    });
    if (!res.ok) console.warn("Telegram", call.method, res.status, await res.text());
  }
  return new Response("ok");
});
