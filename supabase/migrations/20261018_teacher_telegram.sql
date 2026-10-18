-- ---------- Telegram: students with a teacher don't ping Alex (20261018_teacher_telegram.sql) ----------
-- Level-ups, questions and 15-model lists from a teacher's students are the teacher's job (Approvals tab),
-- so Alex's Telegram only gets the ones from farmers with no teacher. Everything else is unchanged.
do $$ declare d text; a text := E'  begin\n    if tg_table_name = ''profiles'' then'; begin
  d := pg_get_functiondef('ops.on_dashboard_event()'::regprocedure);
  if position(a in d) = 0 then raise exception 'ops.on_dashboard_event changed; update this migration'; end if;
  if position('teacher_of' in d) > 0 then return; end if;
  execute replace(d, a, E'  begin\n'
    || E'    -- a teacher''s student: the teacher handles it in the portal\n'
    || E'    if tg_table_name in (''level_requests'', ''teacher_questions'') then\n'
    || E'      if public.teacher_of(new.farmer_id) is not null then return null; end if;\n'
    || E'    elsif tg_table_name = ''profiles'' and tg_op = ''UPDATE'' then\n'
    || E'      if new.niche_submitted_at is distinct from old.niche_submitted_at and public.teacher_of(new.id) is not null then return null; end if;\n'
    || E'    end if;\n'
    || E'    if tg_table_name = ''profiles'' then');
end $$;
