// Lead Farming Discord bot. One function, four doors:
//   GET  ?code=&state=           the "Join the Discord" sign-in comes back here: link the account, add them to the server
//   POST x-signature-ed25519     Discord slash commands (/progress, /portal)
//   POST x-ops-key               the database: setup, sync roles, DM an alert, level-up shout-outs, the daily behind board, announcements
// Function secrets (Supabase dashboard): DISCORD_BOT_TOKEN, DISCORD_CLIENT_SECRET.
// Table public.discord_config holds client_id, public_key, guild_id, plus the role and channel ids that setup creates.
// Deploy with verify_jwt off: every door checks its own credentials.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const API = "https://discord.com/api/v10";
const PORTAL = "https://leadfarminghq.com/app/";
const REDIRECT = "https://rkjsfuflfuckqyvaychm.supabase.co/functions/v1/discord";
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

// ---------- Discord REST ----------
type Json = Record<string, unknown>;
async function discord(method: string, path: string, body?: unknown, auth = `Bot ${Deno.env.get("DISCORD_BOT_TOKEN")}`): Promise<Response> {
  for (let attempt = 0; ; attempt++) {
    const res = await fetch(API + path, {
      method,
      headers: { Authorization: auth, ...(body !== undefined ? { "Content-Type": "application/json" } : {}) },
      body: body !== undefined ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(8000),
    });
    if (res.status === 429 && attempt < 2) {
      const wait = Number((await res.json().catch(() => ({})) as Json).retry_after ?? 1);
      await new Promise((r) => setTimeout(r, Math.min(wait, 5) * 1000));
      continue;
    }
    if (!res.ok && res.status !== 404) console.warn(`Discord ${method} ${path}: ${res.status}`, await res.clone().text());
    return res;
  }
}

async function config(): Promise<Record<string, string>> {
  const { data } = await db.from("discord_config").select("key, value");
  return Object.fromEntries((data ?? []).map((r) => [r.key, r.value]));
}
async function setConfig(key: string, value: string) {
  await db.from("discord_config").upsert({ key, value });
}

// ---------- roles ----------
const ROLES: [string, string, number][] = [
  ["role:farmer", "Farmer", 0x58cc02],
  ["role:level1", "Level 1", 0x8bc34a],
  ["role:level2", "Level 2", 0x2e9cca],
  ["role:level3", "Level 3", 0x8e44ad],
  ["role:teacher", "Teacher", 0xf5b700],
  ["role:founder", "Founder", 0xe67e22],
  // milestones, earned in the portal and kept for good
  ["role:signed", "Contractor Signed", 0x1abc9c],
  ["role:fee", "First Fee", 0x2ecc71],
  ["role:recruiter", "Recruiter", 0xe91e63],
  ["role:finisher", "90-Day Finisher", 0xf1c40f],
];
const MILESTONES: Record<string, string> = {
  "role:signed": "signed their first contractor",
  "role:fee": "collected their first referral fee",
  "role:recruiter": "brought a new farmer into the program",
  "role:finisher": "hit every 90-day goal",
};

type Member = {
  farmer_id: string; discord_id: string | null; name: string; farmer: boolean; level: number; teacher: boolean; admin: boolean;
  signed: boolean; fee: boolean; recruiter: boolean; finisher: boolean;
};

function wantedRoles(m: Member, cfg: Record<string, string>): string[] {
  const keys: string[] = [];
  if (m.farmer) keys.push("role:farmer");
  if (m.farmer && m.level >= 1) keys.push(`role:level${Math.min(m.level, 3)}`);
  if (m.teacher) keys.push("role:teacher");
  if (m.admin) keys.push("role:founder");
  if (m.farmer && m.signed) keys.push("role:signed");
  if (m.farmer && m.fee) keys.push("role:fee");
  if (m.farmer && m.recruiter) keys.push("role:recruiter");
  if (m.farmer && m.finisher) keys.push("role:finisher");
  return keys.map((k) => cfg[k]).filter(Boolean);
}

// Give someone exactly the roles their portal account earns. Roles Alex hands out by hand are left alone.
async function sync(farmerId: string) {
  const { data: m } = await db.rpc("discord_member", { f: farmerId });
  if (!m?.discord_id) return "not linked";
  const cfg = await config();
  const res = await discord("GET", `/guilds/${cfg.guild_id}/members/${m.discord_id}`);
  if (!res.ok) return "not in the server";
  const cur = await res.json();
  const have = new Set<string>(cur.roles ?? []);
  const want = new Set(wantedRoles(m, cfg));
  const earned: string[] = [];
  for (const [key] of ROLES) {
    const id = cfg[key];
    if (!id) continue;
    if (want.has(id) && !have.has(id)) {
      const r = await discord("PUT", `/guilds/${cfg.guild_id}/members/${m.discord_id}/roles/${id}`);
      if (r.ok && MILESTONES[key]) earned.push(key);
    }
    if (!want.has(id) && have.has(id)) await discord("DELETE", `/guilds/${cfg.guild_id}/members/${m.discord_id}/roles/${id}`);
  }
  // nickname = portal name, so the member list reads like the Farmers page (the server owner can't be renamed)
  const nick = m.name.slice(0, 32);
  if (!m.admin && cur.nick !== nick) await discord("PATCH", `/guilds/${cfg.guild_id}/members/${m.discord_id}`, { nick });
  if (earned.length && cfg["channel:wins"]) {
    await post(cfg["channel:wins"], earned.map((k) => `🏅 <@${m.discord_id}> just ${MILESTONES[k]} and earned **${ROLES.find((r) => r[0] === k)![1]}**!`), [m.discord_id]);
  }
  return "synced";
}

// ---------- messages ----------
async function dm(farmerId: string, text: string) {
  const { data: link } = await db.from("discord_links").select("discord_id").eq("farmer_id", farmerId).maybeSingle();
  if (!link) return "not linked";
  const ch = await discord("POST", "/users/@me/channels", { recipient_id: link.discord_id });
  if (!ch.ok) return "no dm channel";
  const { id } = await ch.json();
  const res = await discord("POST", `/channels/${id}/messages`, {
    content: `🔔 ${text}\n${PORTAL}`.slice(0, 2000),
    allowed_mentions: { parse: [] },
  });
  return res.ok ? "sent" : "dms closed"; // 50007: they turned off DMs from server members
}

async function post(channelId: string, lines: string[], users: string[] = []) {
  // Discord caps a message at 2000 characters, so long boards go out in parts
  let chunk = "";
  const send = (content: string) =>
    discord("POST", `/channels/${channelId}/messages`, { content, allowed_mentions: { parse: [], users: [...new Set(users)].slice(0, 100) } });
  for (const line of lines) {
    if (chunk && chunk.length + line.length + 1 > 1900) { await send(chunk); chunk = ""; }
    chunk += (chunk ? "\n" : "") + line.slice(0, 1900);
  }
  if (chunk) await send(chunk);
}

type BoardRow = { name: string; discord_id: string | null; day: number; reasons: string[]; teacher: string | null; teacher_discord: string | null };
async function board(farmers: BoardRow[]) {
  const cfg = await config();
  const ch = cfg["channel:behind-board"];
  if (!ch) return "no board channel";
  const date = new Date().toLocaleDateString("en-US", { timeZone: "America/Chicago", weekday: "short", month: "short", day: "numeric" });
  if (!farmers.length) { await post(ch, [`🌾 **Behind board · ${date}**`, "✅ Nobody is behind today."]); return "posted"; }
  const lines = [`🌾 **Behind board · ${date}**`, `${farmers.length} farmer${farmers.length > 1 ? "s need" : " needs"} a check-in. Each one was also sent a portal alert${farmers.some((f) => f.discord_id) ? " and a Discord DM" : ""}.`, ""];
  for (const f of farmers) {
    lines.push(`• **${f.name}** ${f.discord_id ? `<@${f.discord_id}>` : "(not on Discord)"} · day ${f.day}`
      + (f.teacher ? ` · teacher ${f.teacher_discord ? `<@${f.teacher_discord}>` : f.teacher}` : " · no teacher yet"));
    for (const r of f.reasons ?? []) lines.push(`  ↳ ${r}`);
  }
  lines.push("", `Hand someone to a teacher from Home in the portal: ${PORTAL}`);
  // ping only the teachers, never the farmers being talked about
  await post(ch, lines, farmers.map((f) => f.teacher_discord).filter(Boolean) as string[]);
  return "posted";
}

// A one-off post from Alex to a channel (by config key). @everyone only when asked; named people get pinged.
async function announce(channel: string, text: string, everyone: boolean, users: string[] = []) {
  const cfg = await config();
  const id = cfg[`channel:${channel}`];
  if (!id) return `no #${channel} channel`;
  const res = await discord("POST", `/channels/${id}/messages`, {
    content: text.slice(0, 2000), allowed_mentions: { parse: everyone ? ["everyone"] : [], users: users.slice(0, 100) },
  });
  return res.ok ? "posted" : `failed ${res.status}`;
}

async function levelup(farmerId: string, level: number, name: string | null) {
  const cfg = await config();
  const { data: link } = await db.from("discord_links").select("discord_id").eq("farmer_id", farmerId).maybeSingle();
  if (!link || !cfg["channel:wins"]) return "skipped";
  await post(cfg["channel:wins"], [`🎉 <@${link.discord_id}> just reached **Level ${level}${name ? `, ${name}` : ""}**! Congrats!`], [link.discord_id]);
  return "posted";
}

// ---------- one-time setup: roles, channels, slash commands ----------
const VIEW = 1 << 10, SEND = 1 << 11, HISTORY = 1 << 16, REACT = 1 << 6, EMBED = 1 << 14, ATTACH = 1 << 15;
const TALK = VIEW | SEND | HISTORY | REACT | EMBED | ATTACH;
const READ = VIEW | HISTORY | REACT;
const FARMERS = ["role:farmer", "role:teacher"];
// [config key, name, category, topic, who can talk, who can only read]
// Channel type 2 = voice: people there connect and speak with the server's default permissions once they can see it.
const CHANNELS: [string, string, string, string, string[], string[], number?][] = [
  ["start-here", "start-here", "LEAD FARMING", "How this server works. Read this first.", [], FARMERS],
  ["announcements", "announcements", "LEAD FARMING", "News from Alex. Only Alex posts here.", [], FARMERS],
  ["introductions", "introductions", "LEAD FARMING", "Say hi: your name, your town, and your 15 trades.", FARMERS, []],
  ["general", "general", "LEAD FARMING", "Talk shop with the other farmers.", FARMERS, []],
  ["wins", "wins", "LEAD FARMING", "Signed a contractor? Closed a lead? Got paid? Post it here. Level-ups and milestones post here on their own.", FARMERS, []],
  ["questions", "questions", "LEAD FARMING", "Stuck? Ask here and a teacher or another farmer will help.", FARMERS, []],
  ["scripts-and-templates", "scripts-and-templates", "THE PLAYBOOK", "Call scripts, texts and comment templates from the teachers.", ["role:teacher"], ["role:farmer"]],
  ["contractor-outreach", "contractor-outreach", "THE PLAYBOOK", "Steps 1 to 3: finding contractors, calls, and getting terms agreed.", FARMERS, []],
  ["neighbor-leads", "neighbor-leads", "THE PLAYBOOK", "Step 4 on: finding homeowner jobs on Nextdoor and Facebook.", FARMERS, []],
  ["daily-check-in", "daily-check-in", "THE PLAYBOOK", "Post your numbers every day: contractors added, calls, comments, leads.", FARMERS, []],
  ["Office Hours", "Office Hours", "VOICE", "", FARMERS, [], 2],
  ["Co-working", "Co-working", "VOICE", "", FARMERS, [], 2],
  ["level-2-lounge", "level-2-lounge", "LEVEL LOUNGES", "For Level 2 and up: leads, fees and reciprocal deals.", ["role:level2", "role:level3", "role:teacher"], []],
  ["level-3-lounge", "level-3-lounge", "LEVEL LOUNGES", "For Level 3: anchors and upsells.", ["role:level3", "role:teacher"], []],
  ["teachers", "teachers", "STAFF", "Alex and the teachers.", ["role:teacher"], []],
  ["behind-board", "behind-board", "STAFF", "Every day after the nudges go out: who is behind and why.", ["role:teacher"], []],
];

function startHere(cfg: Record<string, string>): string[] {
  const ch = (k: string) => (cfg[`channel:${k}`] ? `<#${cfg[`channel:${k}`]}>` : `#${k}`);
  return [
    "🌾 **Welcome to Lead Farming HQ**",
    "This server is for enrolled farmers, the teachers and Alex. You got in through the portal, so your roles follow your portal account.",
    "",
    "**How it works**",
    `• ${ch("announcements")}: news from Alex. Turn on notifications for this one.`,
    `• ${ch("introductions")}: say hi, where you farm and your 15 trades.`,
    `• ${ch("daily-check-in")}: post your numbers every day. Five days a week keeps you on track.`,
    `• ${ch("questions")}: stuck? Ask. A teacher or another farmer will answer.`,
    `• ${ch("wins")}: level-ups and milestones post here on their own. Add your own wins too.`,
    `• ${ch("scripts-and-templates")}: scripts and templates from the teachers.`,
    "",
    "**Roles**",
    "Your Level role and lounge unlock as you level up in the portal. Milestone roles (Contractor Signed, First Fee, Recruiter, 90-Day Finisher) come on their own when the portal sees you hit them.",
    "",
    "**Alerts**",
    "Portal alerts also come to your Discord DMs, like a 90-day date coming up or a level approved. Type **/progress** in any channel to see your 90-day numbers.",
    "",
    "Log your work in the portal: https://leadfarminghq.com/app/",
  ];
}

const COMMANDS = [
  { name: "progress", description: "Your 90-day progress, and anything you're behind on", type: 1 },
  { name: "portal", description: "A link to the Lead Farming portal", type: 1 },
];

async function setup() {
  let cfg = await config();
  if (!cfg.guild_id) {
    // no server id saved yet: use the one server the bot was added to
    const res = await discord("GET", "/users/@me/guilds");
    const guilds: Json[] = res.ok ? await res.json() : [];
    if (guilds.length !== 1) return { error: `the bot is in ${guilds.length} servers; save guild_id in discord_config` };
    await setConfig("guild_id", String(guilds[0].id));
    cfg = await config();
  }
  const g = cfg.guild_id, app = cfg.client_id;
  if (!g || !app) return { error: "guild_id and client_id must be in discord_config first" };
  const done: string[] = [];

  const roles: Json[] = await (await discord("GET", `/guilds/${g}/roles`)).json();
  for (const [key, name, color] of ROLES) {
    const found = roles.find((r) => r.id === cfg[key]) ?? roles.find((r) => r.name === name);
    if (found) { await setConfig(key, String(found.id)); continue; }
    const res = await discord("POST", `/guilds/${g}/roles`, { name, color, hoist: key === "role:teacher" || key.startsWith("role:level"), mentionable: true });
    if (!res.ok) return { error: `couldn't create role ${name}: ${res.status} ${await res.text()}` };
    await setConfig(key, String((await res.json()).id));
    done.push(`role ${name}`);
  }
  cfg = await config();

  const chans: Json[] = await (await discord("GET", `/guilds/${g}/channels`)).json();
  const cats = new Map<string, string>();
  for (const cat of new Set(CHANNELS.map((c) => c[2]))) {
    const found = chans.find((c) => c.type === 4 && String(c.name).toUpperCase() === cat);
    if (found) { cats.set(cat, String(found.id)); continue; }
    const res = await discord("POST", `/guilds/${g}/channels`, { name: cat, type: 4 });
    if (!res.ok) return { error: `couldn't create category ${cat}: ${res.status} ${await res.text()}` };
    cats.set(cat, String((await res.json()).id));
    done.push(`category ${cat}`);
  }
  for (const [key, name, cat, topic, talk, read, type = 0] of CHANNELS) {
    const found = chans.find((c) => c.id === cfg[`channel:${key}`]) ?? chans.find((c) => c.type === type && c.name === name);
    if (found) { await setConfig(`channel:${key}`, String(found.id)); continue; }
    // nobody sees anything until the portal gives them a role; the bot always sees its channels
    const overwrites = [
      { id: g, type: 0, allow: "0", deny: String(VIEW) },
      { id: app, type: 1, allow: String(type === 2 ? VIEW : TALK), deny: "0" },
      ...talk.map((k) => ({ id: cfg[k], type: 0, allow: String(type === 2 ? VIEW : TALK), deny: "0" })),
      ...read.map((k) => ({ id: cfg[k], type: 0, allow: String(READ), deny: String(SEND) })),
    ];
    const res = await discord("POST", `/guilds/${g}/channels`, {
      name, type, parent_id: cats.get(cat), permission_overwrites: overwrites, ...(topic ? { topic } : {}), ...(key === "start-here" ? { position: 0 } : {}),
    });
    if (!res.ok) return { error: `couldn't create #${name}: ${res.status} ${await res.text()}` };
    const id = String((await res.json()).id);
    await setConfig(`channel:${key}`, id);
    if (key === "start-here") { cfg = await config(); await post(id, startHere(cfg)); }
    done.push(`#${name}`);
  }

  const cmd = await discord("PUT", `/applications/${app}/guilds/${g}/commands`, COMMANDS);
  if (!cmd.ok) return { error: `couldn't register commands: ${cmd.status} ${await cmd.text()}` };
  done.push("slash commands");
  return { ok: true, created: done };
}

// ---------- slash commands ----------
const hex = (s: string) => new Uint8Array((s.match(/../g) ?? []).map((b) => parseInt(b, 16)));
async function validInteraction(req: Request, body: string, publicKey: string): Promise<boolean> {
  const sig = req.headers.get("x-signature-ed25519"), ts = req.headers.get("x-signature-timestamp");
  if (!sig || !ts || !publicKey) return false;
  try {
    const key = await crypto.subtle.importKey("raw", hex(publicKey), { name: "Ed25519" }, false, ["verify"]);
    return await crypto.subtle.verify({ name: "Ed25519" }, key, hex(sig), new TextEncoder().encode(ts + body));
  } catch {
    return false;
  }
}

type Step = { n: number; name: string; quota: string; deadline: number; met: boolean; progress: string };
async function progressText(discordId: string): Promise<string> {
  const { data } = await db.rpc("discord_progress", { did: discordId });
  if (!data) return `Your Discord isn't linked to a portal account yet. Open Settings in the portal and press **Join the Discord**: ${PORTAL}`;
  const pr = data.progress;
  if (!pr?.enrolled) return `Hi ${data.name.split(" ")[0]}! Your 90 days start when your enrollment is paid. ${PORTAL}`;
  const day = Math.min(pr.day, 90);
  const steps: Step[] = pr.steps ?? [];
  const lines = [`**${data.name}** · Level ${data.level} · day ${day} of 90`, ""];
  for (const s of steps) {
    const icon = s.met ? "✅" : s.deadline < pr.day ? "⚠️" : "⏳";
    lines.push(`${icon} Step ${s.n}, ${s.name}: ${s.progress}${s.met ? "" : ` (due day ${s.deadline})`}`);
  }
  // missed steps are already flagged above; this adds "no contractors yet" and "nothing logged for N days"
  const other = (data.reasons ?? []).filter((r: Json) => r.kind !== "behind").map((r: Json) => `⚠️ ${r.text}`);
  if (other.length) lines.push("", ...other);
  lines.push("", `Log today's work in the portal: ${PORTAL}`);
  return lines.join("\n").slice(0, 2000);
}

async function interaction(body: Json): Promise<Json> {
  if (body.type === 1) return { type: 1 };
  const name = (body.data as Json)?.name;
  const user = ((body.member as Json)?.user ?? body.user) as Json;
  let content = "I don't know that one yet. Try /progress.";
  if (name === "progress") content = await progressText(String(user.id));
  if (name === "portal") content = `The Lead Farming portal: ${PORTAL}`;
  return { type: 4, data: { content, flags: 64, allowed_mentions: { parse: [] } } }; // 64 = only they see it
}

// ---------- "Join the Discord" sign-in ----------
const back = (result: string) => Response.redirect(`${PORTAL}?discord=${result}`, 303);
async function oauth(url: URL): Promise<Response> {
  const state = url.searchParams.get("state"), code = url.searchParams.get("code");
  if (!state) return back("cancelled");
  const { data: st } = await db.from("discord_states").delete().eq("nonce", state).select().maybeSingle();
  if (!st || Date.now() - new Date(st.created_at).getTime() > 3600_000) return back("expired");
  if (!code) return back("cancelled");
  const cfg = await config();

  const tok = await fetch(`${API}/oauth2/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: cfg.client_id, client_secret: Deno.env.get("DISCORD_CLIENT_SECRET") ?? "", grant_type: "authorization_code", code, redirect_uri: REDIRECT }),
  });
  if (!tok.ok) { console.warn("token exchange failed", tok.status, await tok.text()); return back("failed"); }
  const { access_token } = await tok.json();
  const me = await discord("GET", "/users/@me", undefined, `Bearer ${access_token}`);
  if (!me.ok) return back("failed");
  const du = await me.json();

  const { data: other } = await db.from("discord_links").select("farmer_id").eq("discord_id", du.id).maybeSingle();
  if (other && other.farmer_id !== st.farmer_id) return back("taken");
  await db.from("discord_links").upsert({ farmer_id: st.farmer_id, discord_id: du.id, discord_name: du.global_name || du.username, linked_at: new Date().toISOString() });

  const { data: m } = await db.rpc("discord_member", { f: st.farmer_id });
  const join = await discord("PUT", `/guilds/${cfg.guild_id}/members/${du.id}`, {
    access_token, roles: wantedRoles(m, cfg), ...(m.admin ? {} : { nick: String(m.name).slice(0, 32) }),
  });
  if (!join.ok) return back("failed");
  await sync(st.farmer_id); // already a member (204): the roles above were ignored, so set them now
  if (join.status === 201 && cfg["channel:general"]) {
    await post(cfg["channel:general"], [`👋 Welcome <@${du.id}>! Say hi, and post your first win in <#${cfg["channel:wins"]}> when it happens.`], [du.id]);
  }
  return back("linked");
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  try {
    if (req.method === "GET") return await oauth(url);
    if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
    const raw = await req.text();

    if (req.headers.has("x-signature-ed25519")) {
      const cfg = await config();
      if (!(await validInteraction(req, raw, cfg.public_key))) return new Response("invalid request signature", { status: 401 });
      return Response.json(await interaction(JSON.parse(raw)));
    }

    const { data: ok } = await db.rpc("discord_ops_ok", { k: req.headers.get("x-ops-key") });
    if (!ok) return new Response("Unauthorized", { status: 401 });
    const body = JSON.parse(raw);
    let result: unknown;
    if (body.action === "setup") result = await setup();
    else if (body.action === "sync") result = await sync(body.farmer_id);
    else if (body.action === "dm") result = await dm(body.farmer_id, String(body.text ?? ""));
    else if (body.action === "board") result = await board(body.farmers ?? []);
    else if (body.action === "announce") result = await announce(String(body.channel ?? "announcements"), String(body.text ?? ""), !!body.everyone, body.users ?? []);
    else if (body.action === "levelup") result = await levelup(body.farmer_id, Number(body.level), body.name ?? null);
    else if (body.action === "sync_all") {
      // answer right away and keep going in the background: the database only waits 10 seconds
      const { data } = await db.from("discord_links").select("farmer_id");
      EdgeRuntime.waitUntil((async () => { for (const r of data ?? []) await sync(r.farmer_id).catch(console.error); })());
      result = `syncing ${data?.length ?? 0}`;
    } else return new Response("unknown action", { status: 400 });
    return Response.json({ result });
  } catch (e) {
    console.error(e);
    return req.method === "GET" ? back("failed") : new Response("error", { status: 500 });
  }
});
