// Jarvis: the phone assistant Alex calls. Vapi answers the call and runs Claude; this function is Jarvis's hands.
//   POST (x-jarvis-key or x-vapi-secret)   Vapi server messages: assistant-request (caller check), tool-calls, end-of-call-report
//   POST /setup (x-jarvis-key)            creates or updates the Vapi assistant and the phone number, from the database (pg_net)
// Shared key with Vapi and the database: ops.jarvis_settings 'secret' (generated in SQL, never typed by anyone).
// Function secrets: JARVIS_PIN, JARVIS_CALLERS (comma-separated phone numbers),
//   VAPI_API_KEY, JARVIS_GITHUB_TOKEN (fine-grained, farmer-portal only), optional TWILIO_ACCOUNT_SID + TWILIO_AUTH_TOKEN.
// Every change (decisions, website changes, merges) needs the PIN again, and website changes are pull requests Alex approves.
// Deploy with verify_jwt off: the shared key is checked here.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const REPO = "alexandernibarger-netizen/farmer-portal";
const OWNER_LOGIN = "alexandernibarger-netizen";
const URL_SELF = "https://rkjsfuflfuckqyvaychm.supabase.co/functions/v1/jarvis";
const VAPI = "https://api.vapi.ai";
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const env = (k: string) => Deno.env.get(k) ?? "";
type Json = Record<string, any>;

const digits = (s: string) => s.replace(/\D/g, "").slice(-10);
const allowedCaller = (n: string) => !!n && env("JARVIS_CALLERS").split(",").map(digits).filter(Boolean).includes(digits(n));
const pinOk = (p: unknown) => !!env("JARVIS_PIN") && String(p ?? "").replace(/\D/g, "") === env("JARVIS_PIN");

async function rpc<T>(fn: string, args: Json): Promise<T> {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data as T;
}
const call = (id: string, caller: string, event: string, data: Json = {}) =>
  rpc<{ verified: boolean; bad_pins: number }>("jarvis_call", { p_call: id, p_caller: caller, p_event: event, p_data: data });
const tool = (name: string, args: Json = {}) => rpc<string>("jarvis_tool", { p_tool: name, p_args: args });

// ---------- GitHub ----------
async function github(method: string, path: string, body?: unknown): Promise<Json> {
  const res = await fetch(`https://api.github.com/repos/${REPO}${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${env("JARVIS_GITHUB_TOKEN")}`,
      Accept: "application/vnd.github+json",
      "User-Agent": "lead-farming-jarvis",
      ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(10000),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`GitHub said ${res.status}: ${data.message ?? "error"}`);
  return data;
}

async function websiteChanges(): Promise<string> {
  const [pulls, issues] = await Promise.all([
    github("GET", "/pulls?state=open&per_page=20") as Promise<any>,
    github("GET", "/issues?state=open&labels=jarvis&per_page=20") as Promise<any>,
  ]);
  const prs = (pulls as Json[]).map((p) => `Pull request ${p.number}: ${p.title}${p.draft ? " (draft)" : ""}`);
  const building = (issues as Json[]).filter((i) => !i.pull_request)
    .filter((i) => !(pulls as Json[]).some((p) => String(p.body ?? "").includes(`#${i.number}`)))
    .map((i) => `Still building, request ${i.number}: ${i.title}`);
  const lines = [...prs, ...building];
  return lines.length ? lines.join("\n") : "No website changes are open right now.";
}

// ---------- Tools ----------
const TOOLS: Json[] = [
  { name: "verify_pin", description: "Check the caller's 4-digit PIN. Call this first, before anything else.",
    parameters: { type: "object", properties: { pin: { type: "string", description: "The digits the caller said" } }, required: ["pin"] } },
  { name: "business_report", description: "This week's business numbers: new paid farmers, revenue, the $30k goal, calls, ads, farmer activity, and what's waiting.",
    parameters: { type: "object", properties: {} } },
  { name: "waiting_on_me", description: "Numbered list of everything waiting on Alex: level-up requests, niche lists, refund packages, teacher questions, owed bonuses.",
    parameters: { type: "object", properties: {} } },
  { name: "idle_farmers", description: "Paying farmers who logged nothing yesterday, with phone numbers and teachers.",
    parameters: { type: "object", properties: {} } },
  { name: "find_farmer", description: "Look up a person in the portal by name or email: level, paid, teacher, niche, phone, last active, contractors and leads.",
    parameters: { type: "object", properties: { name: { type: "string" } }, required: ["name"] } },
  { name: "send_text", description: "Text Alex on Telegram, for anything long, a list, or a link they want to keep.",
    parameters: { type: "object", properties: { message: { type: "string" } }, required: ["message"] } },
  { name: "decide_item", description: "Approve or decline an item from waiting_on_me, by its number. For a teacher question, approve=true and the answer goes in note. Read the item back and get the PIN again first.",
    parameters: { type: "object", properties: {
      item: { type: "integer" }, who: { type: "string", description: "First name of the person on that item, to double-check it's the right one" },
      approve: { type: "boolean" }, note: { type: "string", description: "Reason, feedback, or the answer to send" },
      pin: { type: "string" } }, required: ["item", "who", "approve", "pin"] } },
  { name: "request_website_change", description: "Start a change to the leadfarminghq.com website or portal. Claude builds it and opens a pull request for Alex to approve; it takes a few minutes. Read the request back and get the PIN again first.",
    parameters: { type: "object", properties: {
      title: { type: "string", description: "Short name for the change" },
      details: { type: "string", description: "Everything Alex said about what to change, where, and how it should look or work" },
      pin: { type: "string" } }, required: ["title", "details", "pin"] } },
  { name: "website_changes", description: "Open pull requests and website changes still being built.",
    parameters: { type: "object", properties: {} } },
  { name: "merge_website_change", description: "Merge an open pull request so it goes live on leadfarminghq.com. Say the pull request number and title back and get the PIN again first.",
    parameters: { type: "object", properties: { pr_number: { type: "integer" }, pin: { type: "string" } }, required: ["pr_number", "pin"] } },
];
const NEEDS_PIN = new Set(["decide_item", "request_website_change", "merge_website_change"]);

async function runTool(callId: string, caller: string, name: string, args: Json): Promise<string> {
  let state = await call(callId, caller, "get");
  if (state.bad_pins >= 2) return "Locked: too many wrong PINs on this call. Hang up.";
  if (name === "verify_pin") {
    if (pinOk(args.pin)) {
      await call(callId, caller, "pin_ok");
      return "PIN correct. You're talking to Alex.";
    }
    state = await call(callId, caller, "pin_bad");
    if (state.bad_pins >= 2) {
      await tool("send_text", { message: `⚠️ Two wrong PINs on a call from ${caller || "unknown number"}. Jarvis locked that call.` });
      return "Wrong PIN again. This call is locked. Say goodbye and end the call.";
    }
    return "Wrong PIN. One more try.";
  }
  if (!state.verified) return "Not verified yet. Ask for the PIN and call verify_pin first.";
  if (NEEDS_PIN.has(name) && !pinOk(args.pin)) return "That PIN didn't match, so I did nothing. Ask for the PIN again.";

  switch (name) {
    case "business_report": case "waiting_on_me": case "idle_farmers": case "find_farmer": case "send_text":
      return await tool(name, args);
    case "decide_item":
      return await tool("decide", { item: args.item, who: args.who, approve: args.approve, note: args.note });
    case "request_website_change": {
      const issue = await github("POST", "/issues", {
        title: String(args.title).slice(0, 80),
        body: `${args.details}\n\n_Asked for by Alex on a Jarvis phone call. Claude builds this and opens a pull request for review._`,
        labels: ["jarvis"],
        assignees: [OWNER_LOGIN],
      });
      return `Started. Request ${issue.number} is building now. A pull request usually shows up in 5 to 15 minutes, and GitHub will notify you.`;
    }
    case "website_changes":
      return await websiteChanges();
    case "merge_website_change": {
      const pr = await github("GET", `/pulls/${Number(args.pr_number)}`);
      if (pr.state !== "open") return `Pull request ${pr.number} isn't open, it's ${pr.merged ? "already merged" : pr.state}.`;
      await github("PUT", `/pulls/${pr.number}/merge`, { merge_method: "squash" });
      return `Merged pull request ${pr.number}, "${pr.title}". It's live on leadfarminghq.com in about a minute.`;
    }
  }
  return `I don't have a tool called ${name}.`;
}

// ---------- Vapi setup ----------
const SYSTEM_PROMPT = `You are Jarvis, the phone assistant for Lead Farming HQ, Alex Nibarger's business. You speak on a phone call, so:
- Keep every answer to one to three short sentences unless Alex asks for more. No lists, links, emoji or markdown out loud.
- Round numbers and summarize. For long results, give the headline and offer to text the full version with send_text.
- Dates and times are Central time.

Security, always:
- Your first job on every call is to ask for the PIN and check it with verify_pin. Do nothing else until it passes.
- Before any change (decide_item, request_website_change, merge_website_change), say exactly what you will do, ask "Want me to do that? Say your PIN to confirm," and pass the PIN they say.
- Never say the PIN back. Never guess a PIN.
- Website changes are never pushed live directly. They become a pull request Alex approves, by saying "merge" on a call or on GitHub.
- You cannot move money, issue refunds, or touch Stripe. Approving a refund package only marks it; the refund itself is done by hand in Stripe.
- Nothing about crypto. If asked, say it's outside this line.

The business: Lead Farming HQ trains "farmers" (members who pay $499) to find homeowners who need contractors, send those leads to contractors, and collect referral fees. Farmers move through levels; Alex or a teacher approves each level-up. The portal is at leadfarminghq.com. Teachers are Alex, Vincent and Julian.`;

async function vapi(method: string, path: string, body?: unknown): Promise<Json> {
  const res = await fetch(VAPI + path, {
    method,
    headers: { Authorization: `Bearer ${env("VAPI_API_KEY")}`, "Content-Type": "application/json" },
    body: body !== undefined ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(15000),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`Vapi ${method} ${path} ${res.status}: ${JSON.stringify(data).slice(0, 800)}`);
  return data;
}

const setting = (key: string, value?: string) => rpc<string | null>("jarvis_setting", { p_key: key, p_value: value ?? null });

async function setup(opts: Json): Promise<Json> {
  const server = { url: URL_SELF, headers: { "x-jarvis-key": await sharedKey() } };
  const assistant = {
    name: "Lead Farming Jarvis",
    firstMessage: "Jarvis here. What's your PIN?",
    model: {
      provider: "anthropic",
      model: opts.model ?? (await setting("model")) ?? "claude-sonnet-4-5-20250929",
      temperature: 0.3,
      messages: [{ role: "system", content: SYSTEM_PROMPT }],
      tools: TOOLS.map((f) => ({ type: "function", function: f, server })),
    },
    voice: { provider: "vapi", voiceId: opts.voice ?? (await setting("voice")) ?? "Harry" },
    server,
    serverMessages: ["end-of-call-report"],
    maxDurationSeconds: 1200,
    silenceTimeoutSeconds: 60,
    endCallPhrases: ["goodbye jarvis", "bye jarvis"],
  };
  const out: Json = {};
  let assistantId = await setting("assistant_id");
  if (assistantId) await vapi("PATCH", `/assistant/${assistantId}`, assistant);
  else assistantId = (await vapi("POST", "/assistant", assistant)).id;
  await setting("assistant_id", assistantId!);
  if (opts.model) await setting("model", opts.model);
  if (opts.voice) await setting("voice", opts.voice);
  out.assistant_id = assistantId;

  // The number asks this function who's calling (assistant-request) before it hands over the assistant
  const numberCfg = { name: "Jarvis", assistantId: null, server };
  let phoneId = await setting("phone_id");
  if (phoneId) {
    out.phone = await vapi("PATCH", `/phone-number/${phoneId}`, numberCfg);
  } else if (env("TWILIO_ACCOUNT_SID") && env("TWILIO_AUTH_TOKEN")) {
    const sid = env("TWILIO_ACCOUNT_SID");
    const list = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${sid}/IncomingPhoneNumbers.json`, {
      headers: { Authorization: "Basic " + btoa(`${sid}:${env("TWILIO_AUTH_TOKEN")}`) },
    }).then((r) => r.json());
    const number = list.incoming_phone_numbers?.[0]?.phone_number;
    if (!number) throw new Error("No phone number found on the Twilio account. Buy one first.");
    out.phone = await vapi("POST", "/phone-number", {
      ...numberCfg, provider: "twilio", number, twilioAccountSid: sid, twilioAuthToken: env("TWILIO_AUTH_TOKEN"),
    });
  } else {
    out.phone = await vapi("POST", "/phone-number", {
      ...numberCfg, provider: "vapi", ...(opts.area_code ? { numberDesiredAreaCode: String(opts.area_code) } : {}),
    });
  }
  if (out.phone?.id) await setting("phone_id", out.phone.id);
  if (out.phone?.number) await setting("phone_number", out.phone.number);

  // The label that starts the GitHub build workflow
  await github("POST", "/labels", { name: "jarvis", color: "5b8c3a", description: "Website change asked for on a Jarvis call" })
    .catch((e) => (out.label = String(e)));
  return out;
}

// ---------- Server ----------
let cachedKey = "";
async function sharedKey(): Promise<string> {
  return cachedKey ||= (await setting("secret")) ?? "";
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const secret = await sharedKey();
  const key = req.headers.get("x-jarvis-key") ?? req.headers.get("x-vapi-secret") ?? "";
  if (!secret || key !== secret) return new Response("Unauthorized", { status: 401 });

  const body = await req.json().catch(() => ({}));
  if (new URL(req.url).pathname.endsWith("/setup")) {
    try {
      return json({ ok: true, ...(await setup(body)) });
    } catch (e) {
      return json({ ok: false, error: String(e) }, 500);
    }
  }

  const m: Json = body.message ?? {};
  const callId: string = m.call?.id ?? "unknown";
  const caller: string = m.call?.customer?.number ?? m.customer?.number ?? "";

  if (m.type === "assistant-request") {
    if (!allowedCaller(caller)) {
      await tool("send_text", { message: `📵 Someone called the Jarvis line from ${caller || "a hidden number"}. Not on your list, so it was turned away.` }).catch(() => {});
      return json({ error: "Sorry, this line isn't taking calls." });
    }
    return json({ assistantId: await setting("assistant_id") });
  }

  if (m.type === "tool-calls") {
    const list: Json[] = m.toolCallList ?? (m.toolWithToolCallList ?? []).map((t: Json) => t.toolCall);
    const results = [];
    for (const tc of list) {
      const name = tc.function?.name ?? tc.name;
      let args = tc.function?.arguments ?? tc.arguments ?? {};
      if (typeof args === "string") args = JSON.parse(args || "{}");
      let result: string;
      try {
        result = allowedCaller(caller) ? await runTool(callId, caller, name, args) : "This caller isn't allowed. End the call.";
      } catch (e) {
        result = `That didn't work: ${String((e as Error).message ?? e).slice(0, 300)}`;
      }
      const { pin: _pin, ...logged } = args;
      await call(callId, caller, "log", { tool: name, args: logged, result }).catch((e) => console.warn("log failed", e));
      results.push({ toolCallId: tc.id, result: result.slice(0, 3500) });
    }
    return json({ results });
  }

  if (m.type === "end-of-call-report") {
    const summary: string = m.analysis?.summary ?? m.summary ?? "";
    const transcript: string = m.artifact?.transcript ?? m.transcript ?? "";
    await call(callId, caller, "end", { summary, transcript });
    const mins = Math.max(1, Math.round(Number(m.durationSeconds ?? m.call?.duration ?? 0) / 60));
    if (allowedCaller(caller)) await tool("send_text", { message: `Call ended (about ${mins} min). ${summary || "No summary."}` }).catch(() => {});
    return json({ ok: true });
  }

  return json({ ok: true });
});
