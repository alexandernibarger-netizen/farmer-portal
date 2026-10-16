-- Yes/No buttons on Jarvis's Telegram alerts (Alex, 2026-10-16). Level-up requests, niche lists, refund packages
-- and owed payouts come with buttons; a tap does the same thing as the button in the portal, as Alex.
-- Replying to a teacher question sends the reply as the answer; replying to a level-up, niche or refund
-- sends it back with the reply as the note. Taps reach the telegram-webhook edge function, which passes them
-- to public.telegram_update. Only Alex's chat (Vault telegram_chat_id) is obeyed.

-- Every message that carries buttons, so a tap knows what it is about
create table if not exists ops.telegram_decisions (
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('level', 'niche', 'refund', 'payout', 'question', 'test')),
  ref uuid,
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  choice text);
create index if not exists telegram_decisions_ref on ops.telegram_decisions (kind, ref) where decided_at is null;
revoke all on ops.telegram_decisions from public, anon, authenticated;

-- Like ops.telegram, with buttons under the message (Telegram reply_markup)
create or replace function ops.telegram_markup(msg text, markup jsonb) returns void
language plpgsql security definer set search_path = ops, public as $$
declare tok text; chat text;
begin
  select decrypted_secret into tok from vault.decrypted_secrets where name = 'telegram_bot_token';
  select decrypted_secret into chat from vault.decrypted_secrets where name = 'telegram_chat_id';
  if tok is null or chat is null or msg is null then return; end if;
  perform net.http_post(
    url := 'https://api.telegram.org/bot' || tok || '/sendMessage',
    body := jsonb_strip_nulls(jsonb_build_object('chat_id', chat, 'text', left(msg, 3900),
      'disable_web_page_preview', true, 'reply_markup', markup)));
end;
$$;

-- Sends msg with a Yes and a No button (or, with no labels, just a Ref to reply to). Older open messages
-- about the same thing stop counting, so an old button can never act on a newer submission.
create or replace function ops.ask(msg text, p_kind text, p_ref uuid, yes text default null, no text default null) returns bigint
language plpgsql security definer set search_path = ops, public as $$
declare d bigint;
begin
  if p_ref is not null then
    update ops.telegram_decisions set decided_at = now(), choice = 'superseded'
      where kind = p_kind and ref = p_ref and decided_at is null;
  end if;
  insert into ops.telegram_decisions (kind, ref) values (p_kind, p_ref) returning id into d;
  perform ops.telegram_markup(msg || E'\nRef #' || d,
    case when yes is not null then jsonb_build_object('inline_keyboard', jsonb_build_array(jsonb_build_array(
      jsonb_build_object('text', yes, 'callback_data', 'y:' || d),
      jsonb_build_object('text', no, 'callback_data', 'n:' || d)))) end);
  return d;
end;
$$;

create or replace function ops.on_dashboard_event() returns trigger
language plpgsql security definer set search_path = ops, public as $$
declare msg text; lvl text; site text := E'\nhttps://leadfarminghq.com';
begin
  begin
    if tg_table_name = 'profiles' then
      if tg_op = 'INSERT' and new.role = 'farmer' then
        perform ops.telegram('👤 New signup: ' || coalesce(nullif(btrim(new.full_name), ''), new.email)
          || coalesce(' · ' || new.email, '') || E'\nThey still need to pay to unlock the portal.' || site);
      elsif tg_op = 'UPDATE' then
        if new.niche_submitted_at is distinct from old.niche_submitted_at and new.niche_submitted_at is not null then
          perform ops.ask('🌱 Niche to review: ' || ops.who(new.id) || E'\n' || left(coalesce(new.niche, ''), 500)
            || E'\n\nApprove it, or reply to this message with what to change.' || site,
            'niche', new.id, '✅ Approve', '↩️ Send back');
        elsif new.terms_declined_at is distinct from old.terms_declined_at and new.terms_declined_at is not null then
          perform ops.telegram('⚠️ ' || ops.who(new.id) || ' declined the enrollment terms.' || site);
        end if;
      end if;
    elsif tg_table_name = 'level_requests' and tg_op = 'INSERT' then
      select name into lvl from public.levels where level = new.to_level;
      perform ops.ask('⬆️ Level-up request: ' || ops.who(new.farmer_id) || ' wants Level ' || new.to_level
        || coalesce(' (' || lvl || ')', '')
        || coalesce(E'\n"' || left(nullif(btrim(new.note), ''), 400) || '"', '')
        || coalesce(E'\n📎 ' || nullif(cardinality(new.files), 0) || ' proof file(s), open the portal to see them', '')
        || E'\n\nApprove it, or reply to this message with why not.' || site,
        'level', new.id, '✅ Approve', '❌ Decline');
    elsif tg_table_name = 'teacher_questions' and tg_op = 'INSERT' then
      select name into lvl from public.quizzes where key = new.quiz;
      perform ops.ask('❓ Question from ' || ops.who(new.farmer_id) || coalesce(' about the ' || lvl || ' quiz', '')
        || E':\n"' || left(new.body, 500) || '"'
        || E'\n\nReply to this message with your answer and I''ll send it to them.' || site,
        'question', new.id);
    elsif tg_table_name = 'refund_requests' and tg_op = 'INSERT' then
      perform ops.ask('🔁 Refund package submitted by ' || ops.who(new.farmer_id) || '.'
        || E'\nCheck the proof in Approvals first. Approving only marks it approved; you still refund in Stripe.' || site,
        'refund', new.id, '✅ Approve refund', '❌ Deny');
    elsif tg_table_name = 'recruiter_payouts' and tg_op = 'UPDATE'
          and new.status = 'owed' and old.status is distinct from 'owed' then
      perform ops.ask('💸 You owe ' || ops.money(new.amount) || ' to ' || ops.who(new.recruiter_id)
        || ' for recruiting ' || ops.who(new.recruit_id) || E'.\nTap Yes once you''ve paid them.' || site,
        'payout', new.id, '✅ Yes, I paid it', 'Not yet');
    end if;
  exception when others then
    raise warning 'telegram alert failed: %', sqlerrm;
  end;
  return null;
end;
$$;

-- Makes auth.uid() return Alex for the rest of this transaction, so the portal's own review functions
-- run unchanged and record Alex as the reviewer
create or replace function ops.act_as_admin() returns void
language plpgsql security definer set search_path = ops, public as $$
declare a uuid;
begin
  select id into a from public.profiles where role = 'admin' order by created_at limit 1;
  if a is null then raise exception 'no admin account'; end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', a::text, true);
end;
$$;

-- Carries out one decision. Returns what to show under the message, or raises if it couldn't be done.
create or replace function ops.decide(d ops.telegram_decisions, yes boolean, note text default null) returns text
language plpgsql security definer set search_path = ops, public as $$
declare p public.profiles; n int;
begin
  perform ops.act_as_admin();
  if d.kind = 'level' then
    perform public.review_level_request(d.ref, yes, note);
    return case when yes then '✅ Approved, they''re levelled up' else '❌ Declined' end;
  elsif d.kind = 'niche' then
    select * into p from public.profiles where id = d.ref;
    if p.id is null or p.niche_approved_at is not null or p.niche_note is not null then
      raise exception 'This list was already handled';
    end if;
    perform public.review_niche(d.ref, yes, note);
    return case when yes then '✅ Approved' else '↩️ Sent back' end;
  elsif d.kind = 'refund' then
    perform public.review_refund(d.ref, yes, note);
    return case when yes then '✅ Refund approved. Now refund them in Stripe: https://dashboard.stripe.com/payments' else '❌ Refund denied' end;
  elsif d.kind = 'payout' then
    if not yes then return null; end if;
    update public.recruiter_payouts set status = 'paid', paid_at = now() where id = d.ref and status = 'owed';
    get diagnostics n = row_count;
    if n = 0 then raise exception 'This payout was already handled'; end if;
    return '✅ Marked paid';
  elsif d.kind = 'question' then
    if exists (select 1 from public.teacher_questions where id = d.ref and answer is not null) then
      raise exception 'This question was already answered';
    end if;
    perform public.answer_question(d.ref, note);
    return '✅ Answer sent';
  elsif d.kind = 'test' then
    return case when yes then '👍 You tapped Yes. Buttons work.' else '👎 You tapped No. Buttons work.' end;
  end if;
  raise exception 'unknown kind %', d.kind;
end;
$$;

-- Called by the telegram-webhook edge function with Telegram's secret header and the update.
-- Returns the Telegram API calls to make in reply: {"calls": [{"method": ..., "body": {...}}]}.
create or replace function public.telegram_update(p_secret text, p_update jsonb) returns jsonb
language plpgsql security definer set search_path = ops, public as $$
declare
  chat text; cq jsonb; m jsonb; d ops.telegram_decisions; yes boolean; outcome text; err text;
  calls jsonb := '[]'; did bigint;
begin
  if p_secret is null or p_secret is distinct from
     (select decrypted_secret from vault.decrypted_secrets where name = 'telegram_webhook_secret') then
    raise exception 'bad secret';
  end if;
  select decrypted_secret into chat from vault.decrypted_secrets where name = 'telegram_chat_id';
  cq := p_update -> 'callback_query';
  m := p_update -> 'message';

  if cq is not null then
    if cq -> 'from' ->> 'id' is distinct from chat then
      return jsonb_build_object('calls', jsonb_build_array(jsonb_build_object('method', 'answerCallbackQuery',
        'body', jsonb_build_object('callback_query_id', cq ->> 'id', 'text', 'Only Alex can use these buttons.'))));
    end if;
    yes := split_part(cq ->> 'data', ':', 1) = 'y';
    did := nullif(regexp_replace(split_part(cq ->> 'data', ':', 2), '\D', '', 'g'), '')::bigint;
    select * into d from ops.telegram_decisions where id = did for update;
    if d.id is null then
      err := 'I can''t find what this was about anymore.';
    elsif d.decided_at is not null then
      err := 'Already handled' || case when d.choice not in ('yes', 'no', 'superseded') then ' (' || d.choice || ')'
        when d.choice = 'superseded' then ', they sent a newer one' else '' end || '.';
    else
      begin
        outcome := ops.decide(d, yes);
        if outcome is null then  -- "Not yet": nothing to do, keep the buttons
          return jsonb_build_object('calls', jsonb_build_array(jsonb_build_object('method', 'answerCallbackQuery',
            'body', jsonb_build_object('callback_query_id', cq ->> 'id', 'text', 'OK, I''ll leave it open.'))));
        end if;
        update ops.telegram_decisions set decided_at = now(), choice = case when yes then 'yes' else 'no' end where id = d.id;
      exception when others then
        err := sqlerrm;
        if err ilike '%already%' then
          update ops.telegram_decisions set decided_at = now(), choice = 'done in the portal' where id = d.id;
          err := 'Already handled in the portal.';
        else
          -- keep the buttons so Alex can try again
          return jsonb_build_object('calls', jsonb_build_array(jsonb_build_object('method', 'answerCallbackQuery',
            'body', jsonb_build_object('callback_query_id', cq ->> 'id', 'show_alert', true,
              'text', left('Couldn''t do that: ' || err, 190)))));
        end if;
      end;
    end if;
    calls := jsonb_build_array(
      jsonb_build_object('method', 'answerCallbackQuery',
        'body', jsonb_build_object('callback_query_id', cq ->> 'id', 'text', left(coalesce(outcome, err), 190))),
      jsonb_build_object('method', 'editMessageText', 'body', jsonb_build_object(
        'chat_id', cq -> 'message' -> 'chat' ->> 'id', 'message_id', cq -> 'message' -> 'message_id',
        'disable_web_page_preview', true,
        'text', left(coalesce(cq -> 'message' ->> 'text', ''), 3900) || E'\n\n' || coalesce(outcome, '⚪ ' || err))));
    return jsonb_build_object('calls', calls);
  end if;

  if m is not null and m -> 'chat' ->> 'id' = chat then
    did := (regexp_match(coalesce(m -> 'reply_to_message' ->> 'text', ''), 'Ref #(\d+)'))[1]::bigint;
    if did is null then
      outcome := 'I only take button taps and replies to my alerts here. Everything else is in the portal: https://leadfarminghq.com';
    elsif coalesce(btrim(m ->> 'text'), '') = '' then
      outcome := 'Reply with text, please.';
    else
      select * into d from ops.telegram_decisions where id = did for update;
      if d.id is null or d.kind not in ('question', 'level', 'niche', 'refund') then
        outcome := 'Use the buttons on that message.';
      elsif d.decided_at is not null then
        outcome := 'That one was already handled.';
      else
        begin
          outcome := ops.decide(d, false, btrim(m ->> 'text'));
          outcome := outcome || case when d.kind = 'question' then '.' else ' with your note.' end;
          update ops.telegram_decisions set decided_at = now(), choice = case when d.kind = 'question' then 'answered' else 'no' end
            where id = d.id;
          calls := jsonb_build_array(jsonb_build_object('method', 'editMessageText', 'body', jsonb_build_object(
            'chat_id', chat, 'message_id', m -> 'reply_to_message' -> 'message_id', 'disable_web_page_preview', true,
            'text', left(coalesce(m -> 'reply_to_message' ->> 'text', ''), 3000) || E'\n\n' || outcome
              || E'\n"' || left(btrim(m ->> 'text'), 600) || '"')));
        exception when others then
          outcome := case when sqlerrm ilike '%already%' then 'That one was already handled in the portal.'
            else 'Couldn''t do that: ' || sqlerrm end;
        end;
      end if;
    end if;
    return jsonb_build_object('calls', calls || jsonb_build_array(jsonb_build_object('method', 'sendMessage',
      'body', jsonb_build_object('chat_id', chat, 'text', outcome, 'disable_web_page_preview', true,
        'reply_parameters', jsonb_build_object('message_id', m -> 'message_id')))));
  end if;

  return jsonb_build_object('calls', '[]'::jsonb);
end;
$$;

-- Points the bot at the edge function. Run again after rotating the bot token.
create or replace function ops.telegram_set_webhook() returns bigint
language plpgsql security definer set search_path = ops, public as $$
declare tok text; sec text;
begin
  select decrypted_secret into tok from vault.decrypted_secrets where name = 'telegram_bot_token';
  select decrypted_secret into sec from vault.decrypted_secrets where name = 'telegram_webhook_secret';
  if sec is null then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'telegram_webhook_secret',
      'Telegram sends this in X-Telegram-Bot-Api-Secret-Token');
    select decrypted_secret into sec from vault.decrypted_secrets where name = 'telegram_webhook_secret';
  end if;
  return net.http_post(url := 'https://api.telegram.org/bot' || tok || '/setWebhook',
    body := jsonb_build_object('url', 'https://rkjsfuflfuckqyvaychm.supabase.co/functions/v1/telegram-webhook',
      'secret_token', sec, 'allowed_updates', jsonb_build_array('callback_query', 'message'), 'drop_pending_updates', true));
end;
$$;

revoke execute on all functions in schema ops from public, anon, authenticated;
revoke execute on function public.telegram_update(text, jsonb) from public, anon, authenticated;
grant execute on function public.telegram_update(text, jsonb) to service_role;
