-- AI Fronter: system prompt, inbound and logging functions.
-- n8n calls fronter_inbound() and fronter_log(); the avatar API calls avatar_inbound() and fronter_log().

-- Opening hours as one readable line, e.g. "Mon 10:00-19:00; Tue 10:00-19:00; ...; Sun closed".
create or replace function hours_text(p_tenant uuid)
returns text language sql stable as $$
  select string_agg(
           d.label || ' ' || coalesce(
             (select string_agg(to_char(h.opens,'HH24:MI') || '-' || to_char(h.closes,'HH24:MI'), ', ' order by h.opens)
                from business_hours h where h.tenant_id = p_tenant and h.weekday = d.dow),
             'closed'),
           '; ' order by d.ord)
  from (values (1,'Mon',1),(2,'Tue',2),(3,'Wed',3),(4,'Thu',4),(5,'Fri',5),(6,'Sat',6),(0,'Sun',7)) as d(dow,label,ord)
$$;

-- Builds the system prompt from the database, so WhatsApp and the avatar always get the same instructions.
create or replace function persona_prompt(p_tenant uuid, p_channel text)
returns text language sql stable as $$
  select
    'You are ' || p.name || ', working as ' || p.role || ' at ' || t.business_name || E'.\n'
    || case when p_channel = 'web_avatar'
         then E'You are speaking out loud to a visitor through a live avatar.\n'
         else E'You are the front desk of the business on WhatsApp and handle incoming customer messages.\n' end
    || E'Current date and time at the business: '
    || to_char(now() at time zone t.timezone, 'FMDay DD FMMonth YYYY, HH24:MI')
    || ' (' || t.timezone || E').\n'

    || E'\nLANGUAGE & TONE:\n'
    || '- Default language: ' || t.language || E'. If the customer writes in another language, reply in their language.\n'
    || '- ' || p.tone_guidelines || E'\n'
    || case when p_channel = 'web_avatar'
         then E'- Spoken replies: 1 to 2 short sentences. No emojis, no lists, no URLs read aloud.\n'
         else E'- Keep messages short: 2 to 4 lines, natural WhatsApp style. Ask one question at a time.\n' end
    || '- Prices are in ' || t.currency || E' unless the knowledge base says otherwise.\n'

    || E'\nBUSINESS INFORMATION:\n'
    || 'Business: ' || t.business_name
    || coalesce(E'\nAddress: ' || t.address, '')
    || coalesce(E'\nPhone: '   || t.phone, '')
    || E'\nOpening hours: ' || coalesce(hours_text(t.id), 'not set') || E'\n'
    || coalesce((
         select string_agg('[' || k.category || '] ' || k.title || ': ' || k.content, E'\n'
                           order by k.category, k.sort_order)
         from knowledge_items k
         where k.tenant_id = t.id and k.is_active), '(no other information yet)')

    || E'\n\nQUALIFICATION GOALS (ask naturally, one at a time, never all at once):\n'
    || p.qualification_questions
    || case when p_channel = 'whatsapp' then
         E'\nWhen you learn the answers, call the save_lead tool with a short summary.' else '' end

    || E'\n\nBOOKING (' || p.appointment_label || E'):\n'
    || case
         when t.booking_mode = 'calendar' and p_channel = 'whatsapp' then
              E'You can book a ' || p.appointment_label || E' yourself with your tools:\n'
           || E'1. Find out what it is for and the customer''s name.\n'
           || E'2. Call check_availability for the day the customer wants (date as YYYY-MM-DD; work out "tomorrow", "Saturday" etc. from the current date above).\n'
           || E'3. Offer two or three of the free times. Never invent a time that the tool did not return.\n'
           || E'4. When the customer picks one, call book_appointment with the exact slot value (YYYY-MM-DD HH:MM).\n'
           || E'5. Confirm only after the tool answers BOOKED, and repeat the day, time and address.\n'
           || E'To see or cancel the customer''s booking use my_appointments and cancel_appointment. To change a booking, cancel it and book the new time.'
         when t.booking_mode = 'calendar' then
              'When the visitor is ready, say the ' || p.appointment_label || ' can be booked on screen or on WhatsApp.'
         when t.booking_mode = 'link' and p.booking_link is not null and p_channel = 'web_avatar' then
              'When the visitor is ready, say the booking link is shown on screen.'
         when t.booking_mode = 'link' and p.booking_link is not null then
              'When the customer is ready, share this booking link: ' || p.booking_link
         else 'Offer that a team member will call back, and ask for a good time to call.'
       end

    || E'\n\nSTRICT RULES:\n'
    || E'- Only quote prices, services, availability and timings given above or returned by your tools.\n'
    || E'- If the answer is not in the information above, say a team member will confirm and ask for a good time to call.\n'
    || E'- Never promise discounts, legal outcomes or anything the business has not stated.\n'
    || '- If the customer sincerely asks whether you are a human, say you are ' || p.name
    || ', the AI assistant of ' || t.business_name || '.'
  from tenants t
  join personas p on p.tenant_id = t.id
  where t.id = p_tenant and t.is_active
$$;

-- Finds or creates the contact and its open conversation, and returns the system prompt.
create or replace function fronter_open(p_tenant uuid, p_channel text, p_external text, p_name text, p_phone text default null)
returns table (tenant_id uuid, conversation_id uuid, conv_status text, system_prompt text, stt_language text)
language plpgsql as $$
#variable_conflict use_column
declare
  v_contact uuid;
  v_conv    uuid;
  v_status  text;
begin
  insert into contacts as c (tenant_id, channel_type, external_id, display_name, phone)
  values (p_tenant, p_channel, p_external, nullif(p_name, ''), nullif(p_phone, ''))
  on conflict (tenant_id, channel_type, external_id)
  do update set display_name = coalesce(excluded.display_name, c.display_name),
                phone        = coalesce(excluded.phone, c.phone)
  returning c.id into v_contact;

  select cv.id, cv.status into v_conv, v_status
  from conversations cv
  where cv.contact_id = v_contact and cv.status <> 'closed';

  if v_conv is null then
    insert into conversations (tenant_id, contact_id, channel_type)
    values (p_tenant, v_contact, p_channel)
    returning id, status into v_conv, v_status;
  else
    update conversations set last_message_at = now() where id = v_conv;
  end if;

  return query select p_tenant, v_conv, v_status, persona_prompt(p_tenant, p_channel),
                      (select t.stt_language from tenants t where t.id = p_tenant);
end;
$$;

-- Called by n8n: the Evolution instance name tells us which business the message is for.
create or replace function fronter_inbound(p_instance text, p_jid text, p_name text, p_phone text default null)
returns table (tenant_id uuid, conversation_id uuid, conv_status text, system_prompt text, stt_language text)
language sql as $$
  select f.*
  from channels ch
  join tenants t on t.id = ch.tenant_id and t.is_active
  cross join lateral fronter_open(ch.tenant_id, 'whatsapp', p_jid, p_name, p_phone) f
  where ch.type = 'whatsapp' and ch.evolution_instance = p_instance and ch.is_active
$$;

-- Called by the avatar API: the public slug tells us which business it is.
create or replace function avatar_inbound(p_slug text, p_session text)
returns table (tenant_id uuid, conversation_id uuid, conv_status text, system_prompt text, stt_language text)
language sql as $$
  select f.*
  from channels ch
  join tenants t on t.id = ch.tenant_id and t.is_active
  cross join lateral fronter_open(ch.tenant_id, 'web_avatar', p_session, null, null) f
  where ch.type = 'web_avatar' and ch.public_slug = p_slug and ch.is_active
$$;

create or replace function fronter_log(p_conversation uuid, p_role text, p_content text, p_media text default 'text')
returns void language sql as $$
  insert into messages (conversation_id, tenant_id, role, content, media_type)
  select c.id, c.tenant_id, p_role, coalesce(nullif(p_content, ''), '(empty)'),
         case when p_media in ('text','audio','image','other') then p_media else 'other' end
  from conversations c where c.id = p_conversation;
$$;

-- Owner notices waiting to be sent; marks them sent in the same step.
create or replace function take_owner_notifications(p_tenant uuid)
returns table (owner_number text, body text)
language sql as $$
  with picked as (
    update owner_notifications n set sent_at = now()
    from tenants t
    where n.tenant_id = p_tenant and n.sent_at is null
      and t.id = n.tenant_id and coalesce(t.owner_whatsapp, '') <> ''
    returning t.owner_whatsapp, n.body, n.id
  )
  select owner_whatsapp, body from picked order by id
$$;
