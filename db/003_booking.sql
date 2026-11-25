-- AI Fronter: appointment booking.
-- The AI agent never touches tables directly. It calls these functions as tools, always with its
-- own conversation id, so it can only see and book for the business and customer it is talking to.

-- Free slots for a business, in its own time zone.
create or replace function available_slots(p_tenant uuid, p_from date, p_days int default 1)
returns table (slot_start timestamptz, slot text, label text, spots_left int)
language sql stable as $$
  with t as (
    select * from tenants where id = p_tenant and is_active
  ),
  days as (
    select d::date as day
    from t, generate_series(p_from, p_from + greatest(least(p_days, 31), 1) - 1, interval '1 day') d
  ),
  raw as (
    select s as slot_start, s + make_interval(mins => t.slot_minutes) as slot_end, t.*
    from t
    join days on true
    join business_hours h on h.tenant_id = t.id and h.weekday = extract(dow from days.day)
    cross join lateral generate_series(
      (days.day + h.opens) at time zone t.timezone,
      (days.day + h.closes) at time zone t.timezone - make_interval(mins => t.slot_minutes),
      make_interval(mins => t.slot_minutes)) s
  )
  select r.slot_start,
         to_char(r.slot_start at time zone r.timezone, 'YYYY-MM-DD HH24:MI'),
         to_char(r.slot_start at time zone r.timezone, 'Dy DD Mon, HH24:MI'),
         r.slot_capacity - (select count(*)::int from appointments a
                             where a.tenant_id = r.id and a.status = 'booked'
                               and a.starts_at < r.slot_end and a.ends_at > r.slot_start)
  from raw r
  where r.slot_start >= now() + make_interval(mins => r.min_notice_minutes)
    and r.slot_start <  now() + make_interval(days => r.max_days_ahead)
    and not exists (select 1 from closures c
                     where c.tenant_id = r.id and c.starts_at < r.slot_end and c.ends_at > r.slot_start)
    and r.slot_capacity > (select count(*) from appointments a
                            where a.tenant_id = r.id and a.status = 'booked'
                              and a.starts_at < r.slot_end and a.ends_at > r.slot_start)
  order by r.slot_start
$$;

-- Internal: conversation → tenant + contact.
create or replace function conv_context(p_conversation uuid)
returns table (tenant_id uuid, contact_id uuid, tz text, label text, address text)
language sql stable as $$
  select c.tenant_id, c.contact_id, t.timezone, coalesce(p.appointment_label, 'appointment'), t.address
  from conversations c
  join tenants t on t.id = c.tenant_id
  left join personas p on p.tenant_id = c.tenant_id
  where c.id = p_conversation
$$;

-- Tool: check_availability. p_date = 'YYYY-MM-DD' (blank = from today). Returns text for the AI.
create or replace function check_availability(p_conversation uuid, p_date text default null)
returns text language plpgsql stable as $$
declare
  ctx   record;
  v_day date;
  v_out text;
  v_next text;
begin
  select * into ctx from conv_context(p_conversation);
  if ctx.tenant_id is null then return 'ERROR: unknown conversation.'; end if;

  begin
    v_day := nullif(trim(p_date), '')::date;
  exception when others then
    v_day := null;
  end;

  if v_day is null then
    -- No (valid) date: show the next 3 days that have free slots.
    select string_agg(day_line, E'\n') into v_out from (
      select left(slot, 10) || ' (' || to_char(min(slot_start) at time zone ctx.tz, 'Dy') || '): '
             || string_agg(right(slot, 5), ', ' order by slot_start) as day_line
      from available_slots(ctx.tenant_id, (now() at time zone ctx.tz)::date, 31)
      group by left(slot, 10)
      order by left(slot, 10)
      limit 3) x;
    return coalesce('Free times (' || ctx.tz || E', slot value = date + time):\n' || v_out,
                    'No free times in the coming weeks. Offer a call back from the team.');
  end if;

  select string_agg(right(slot, 5), ', ' order by slot_start) into v_out
  from available_slots(ctx.tenant_id, v_day, 1);

  if v_out is not null then
    return 'Free times on ' || to_char(v_day, 'Dy YYYY-MM-DD') || ' (' || ctx.tz || '): ' || v_out
           || '. To book, use slot value "' || v_day || ' HH:MM".';
  end if;

  select string_agg(slot, ', ') into v_next from (
    select slot from available_slots(ctx.tenant_id, v_day + 1, 14) order by slot_start limit 4) x;
  return 'No free times on ' || to_char(v_day, 'Dy YYYY-MM-DD') || ' (closed, fully booked or too soon).'
         || coalesce(' Next free slots: ' || v_next || '.', ' No free times in the next two weeks either.');
end;
$$;

-- Tool: book_appointment. p_slot = 'YYYY-MM-DD HH:MM' in the business's time zone.
create or replace function book_appointment(p_conversation uuid, p_slot text, p_name text,
                                            p_service text default null, p_notes text default null)
returns text language plpgsql as $$
declare
  ctx      record;
  v_start  timestamptz;
  v_end    timestamptz;
  v_slot   record;
  v_phone  text;
  v_exist  record;
  v_id     uuid;
  v_when   text;
begin
  select * into ctx from conv_context(p_conversation);
  if ctx.tenant_id is null then return 'ERROR: unknown conversation.'; end if;

  begin
    v_start := (trim(p_slot)::timestamp) at time zone ctx.tz;
  exception when others then
    return 'ERROR: slot must look like 2026-12-01 15:00. Call check_availability first.';
  end;

  -- One booking at a time per business, so two customers cannot take the last spot together.
  perform pg_advisory_xact_lock(hashtext('fronter-booking-' || ctx.tenant_id::text));

  select * into v_slot from available_slots(ctx.tenant_id, (v_start at time zone ctx.tz)::date, 1) s
  where s.slot_start = v_start;
  if not found then
    return 'NOT BOOKED: ' || trim(p_slot) || ' is not a free time. '
           || check_availability(p_conversation, ((v_start at time zone ctx.tz)::date)::text);
  end if;

  select a.id, a.starts_at into v_exist from appointments a
  where a.contact_id = ctx.contact_id and a.status = 'booked' and a.starts_at > now()
  order by a.starts_at limit 1;
  if found then
    return 'NOT BOOKED: this customer already has a booking on '
           || to_char(v_exist.starts_at at time zone ctx.tz, 'Dy DD Mon YYYY, HH24:MI')
           || '. Ask whether to move it (cancel_appointment, then book_appointment) or keep it.';
  end if;

  select coalesce(c.phone, split_part(c.external_id, '@', 1)) into v_phone
  from contacts c where c.id = ctx.contact_id;

  v_end := v_start + make_interval(mins => (select slot_minutes from tenants where id = ctx.tenant_id));

  insert into appointments (tenant_id, contact_id, conversation_id, service, customer_name,
                            customer_phone, notes, starts_at, ends_at)
  values (ctx.tenant_id, ctx.contact_id, p_conversation, nullif(trim(p_service), ''),
          nullif(trim(p_name), ''), v_phone, nullif(trim(p_notes), ''), v_start, v_end)
  returning id into v_id;

  update contacts set display_name = coalesce(nullif(trim(p_name), ''), display_name)
  where id = ctx.contact_id;

  insert into leads (tenant_id, contact_id, conversation_id, status)
  values (ctx.tenant_id, ctx.contact_id, p_conversation, 'booked')
  on conflict (conversation_id) do update set status = 'booked', updated_at = now();

  v_when := to_char(v_start at time zone ctx.tz, 'FMDay DD FMMonth YYYY, HH24:MI');

  insert into owner_notifications (tenant_id, body)
  values (ctx.tenant_id,
          'New ' || ctx.label || ' booked: ' || v_when
          || E'\nName: ' || coalesce(nullif(trim(p_name), ''), '-')
          || E'\nPhone: +' || coalesce(v_phone, '-')
          || coalesce(E'\nFor: ' || nullif(trim(p_service), ''), '')
          || coalesce(E'\nNotes: ' || nullif(trim(p_notes), ''), ''));

  return 'BOOKED: ' || ctx.label || ' on ' || v_when || ' (' || ctx.tz || ')'
         || coalesce(' at ' || ctx.address, '') || '. Reference ' || left(v_id::text, 8) || '.';
end;
$$;

-- Tool: my_appointments. The customer's upcoming bookings.
create or replace function my_appointments(p_conversation uuid)
returns text language sql stable as $$
  select coalesce(
    'Upcoming bookings: ' || string_agg(
       to_char(a.starts_at at time zone ctx.tz, 'FMDay DD FMMonth YYYY, HH24:MI')
       || coalesce(' (' || a.service || ')', '') || ', ref ' || left(a.id::text, 8), '; ' order by a.starts_at),
    'This customer has no upcoming bookings.')
  from conv_context(p_conversation) ctx
  left join appointments a on a.contact_id = ctx.contact_id and a.status = 'booked' and a.starts_at > now()
$$;

-- Tool: cancel_appointment. Cancels the customer's next upcoming booking.
create or replace function cancel_appointment(p_conversation uuid, p_reason text default null)
returns text language plpgsql as $$
declare
  ctx  record;
  v_ap record;
begin
  select * into ctx from conv_context(p_conversation);
  if ctx.tenant_id is null then return 'ERROR: unknown conversation.'; end if;

  update appointments a
     set status = 'cancelled', updated_at = now(),
         notes = concat_ws(' | ', a.notes, 'Cancelled: ' || nullif(trim(p_reason), ''))
   where a.id = (select id from appointments
                  where contact_id = ctx.contact_id and status = 'booked' and starts_at > now()
                  order by starts_at limit 1)
  returning a.* into v_ap;

  if v_ap.id is null then return 'Nothing to cancel: this customer has no upcoming bookings.'; end if;

  insert into owner_notifications (tenant_id, body)
  values (ctx.tenant_id,
          'Cancelled ' || ctx.label || ': '
          || to_char(v_ap.starts_at at time zone ctx.tz, 'FMDay DD FMMonth YYYY, HH24:MI')
          || E'\nName: ' || coalesce(v_ap.customer_name, '-')
          || E'\nPhone: +' || coalesce(v_ap.customer_phone, '-')
          || coalesce(E'\nReason: ' || nullif(trim(p_reason), ''), ''));

  update leads set status = 'qualified', updated_at = now()
   where conversation_id = p_conversation and status = 'booked';

  return 'CANCELLED: ' || to_char(v_ap.starts_at at time zone ctx.tz, 'FMDay DD FMMonth YYYY, HH24:MI') || '.';
end;
$$;

-- Tool: save_lead. Keeps what the AI learned (budget, needs, timeline...) for the owner.
create or replace function save_lead(p_conversation uuid, p_summary text,
                                     p_details text default null, p_status text default 'qualified')
returns text language plpgsql as $$
declare
  ctx       record;
  v_answers jsonb;
  v_status  text := case when p_status in ('new','qualified','lost') then p_status else 'qualified' end;
begin
  select * into ctx from conv_context(p_conversation);
  if ctx.tenant_id is null then return 'ERROR: unknown conversation.'; end if;

  begin
    v_answers := nullif(trim(p_details), '')::jsonb;
    if jsonb_typeof(v_answers) <> 'object' then v_answers := jsonb_build_object('details', p_details); end if;
  exception when others then
    v_answers := jsonb_build_object('details', p_details);
  end;

  insert into leads (tenant_id, contact_id, conversation_id, summary, answers, status)
  values (ctx.tenant_id, ctx.contact_id, p_conversation, p_summary, coalesce(v_answers, '{}'), v_status)
  on conflict (conversation_id) do update
    set summary    = coalesce(excluded.summary, leads.summary),
        answers    = leads.answers || excluded.answers,
        -- a booked lead stays booked
        status     = case when leads.status = 'booked' then 'booked' else excluded.status end,
        updated_at = now();
  return 'Lead saved.';
end;
$$;
