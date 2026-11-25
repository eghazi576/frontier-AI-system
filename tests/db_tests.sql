-- Database tests. Run with tests/run_db_tests.sh (needs a local PostgreSQL 15+).
\set ON_ERROR_STOP 1
\pset pager off

create or replace function pg_temp.ok(cond boolean, msg text) returns void language plpgsql as $$
begin
  if cond is not true then raise exception 'FAIL: %', msg; end if;
  raise notice 'ok - %', msg;
end $$;

-- 1. Prompt is built and carries per-business settings
select pg_temp.ok(persona_prompt(id, 'whatsapp') like '%Roman Urdu%' and persona_prompt(id, 'whatsapp') like '%(Asia/Karachi)%'
                  and persona_prompt(id, 'whatsapp') like '%PKR%' and persona_prompt(id, 'whatsapp') like '%Bahria Town Phase 8%'
                  and persona_prompt(id, 'whatsapp') like '%Mon 10:00-19:00%Sun closed%'
                  and persona_prompt(id, 'whatsapp') like '%book_appointment%',
                  'Bahria prompt has language, time zone, currency, knowledge, hours, booking tools')
from tenants where slug = 'bahria-prime';
select pg_temp.ok(persona_prompt(id, 'whatsapp') like '%English; switch to Turkish%' and persona_prompt(id, 'whatsapp') like '%(Europe/Istanbul)%'
                  and persona_prompt(id, 'whatsapp') like '%TRY%' and persona_prompt(id, 'whatsapp') like '%Sat 10:00-15:00%',
                  'Istanbul prompt uses its own language, time zone, currency and hours')
from tenants where slug = 'bosphorus-homes';

-- 2. Inbound: unknown instance gives no row; known instance opens one conversation and reuses it
select pg_temp.ok((select count(*) from fronter_inbound('nope', '1@s.whatsapp.net', 'x')) = 0, 'unknown instance returns nothing');
create temp table c1 as select * from fronter_inbound('fronter_realestate', '923335555555@s.whatsapp.net', 'Ali', '923335555555');
create temp table c2 as select * from fronter_inbound('fronter_realestate', '923335555555@s.whatsapp.net', '', null);
select pg_temp.ok((select conversation_id from c1) = (select conversation_id from c2) and (select conv_status from c1) = 'ai',
                  'same customer reuses the open conversation, status ai');
select pg_temp.ok((select display_name from contacts where external_id = '923335555555@s.whatsapp.net') = 'Ali',
                  'blank name does not wipe the saved name');
create temp table c3 as select * from fronter_inbound('fronter_clinic', '923335555555@s.whatsapp.net', 'Ali');
select pg_temp.ok((select conversation_id from c3) <> (select conversation_id from c1), 'same customer at another business is a separate conversation');

-- 3. Logging
select fronter_log((select conversation_id from c1), 'user', 'Salam, plot ka rate?', 'text');
select fronter_log((select conversation_id from c1), 'assistant', '', 'weird');
select pg_temp.ok((select count(*) from messages where conversation_id = (select conversation_id from c1)) = 2, 'messages logged');

-- 4. Availability respects hours, slot size, notice and time zone
do $$
declare v_t uuid; v_next date; v_sun date; n int;
begin
  select id into v_t from tenants where slug = 'bahria-prime';
  v_next := (now() at time zone 'Asia/Karachi')::date + 2;
  while extract(dow from v_next) = 0 loop v_next := v_next + 1; end loop;
  select count(*) into n from available_slots(v_t, v_next, 1);
  perform pg_temp.ok(n = 9, 'open weekday has 9 one-hour slots 10:00-18:00 (got ' || n || ')');
  perform pg_temp.ok((select min(slot) from available_slots(v_t, v_next, 1)) = v_next || ' 10:00', 'first slot is 10:00 local');
  perform pg_temp.ok((select min(slot_start) from available_slots(v_t, v_next, 1)) = (v_next + time '10:00') at time zone 'Asia/Karachi',
                     'slot time stored in UTC matches 10:00 Karachi');
  v_sun := v_next; while extract(dow from v_sun) <> 0 loop v_sun := v_sun + 1; end loop;
  perform pg_temp.ok((select count(*) from available_slots(v_t, v_sun, 1)) = 0, 'Sunday closed');
  perform pg_temp.ok((select count(*) from available_slots(v_t, (now() at time zone 'Asia/Karachi')::date - 1, 1)) = 0, 'no slots in the past');
  perform pg_temp.ok(check_availability((select conversation_id from c1), v_sun::text) like 'No free times on%Next free slots:%',
                     'closed day suggests next free slots');
  perform pg_temp.ok(check_availability((select conversation_id from c1), 'garbage') like 'Free times (Asia/Karachi%',
                     'bad date falls back to the next days');
end $$;

-- 5. Booking: capacity, double booking, wrong slot, cancel, owner notice, lead status
do $$
declare v_day date; v_slot text; r text;
  conv_a uuid := (select conversation_id from c1);
  conv_b uuid; conv_c uuid;
begin
  v_day := (now() at time zone 'Asia/Karachi')::date + 3;
  while extract(dow from v_day) = 0 loop v_day := v_day + 1; end loop;
  v_slot := v_day || ' 11:00';

  select conversation_id into conv_b from fronter_inbound('fronter_realestate', '923336666666@s.whatsapp.net', 'Bilal');
  select conversation_id into conv_c from fronter_inbound('fronter_realestate', '923337777777@s.whatsapp.net', 'Chand');

  r := book_appointment(conv_a, v_day || ' 11:30', 'Ali', 'Phase 8', null);
  perform pg_temp.ok(r like 'NOT BOOKED:%is not a free time%', 'off-grid time refused');
  r := book_appointment(conv_a, 'tomorrow 3pm', 'Ali', null, null);
  perform pg_temp.ok(r like 'ERROR: slot must look like%', 'unparseable slot refused');

  r := book_appointment(conv_a, v_slot, 'Ali Khan', 'Site visit Phase 8', 'Budget 1.5 Cr');
  perform pg_temp.ok(r like 'BOOKED: site visit on %11:00 (Asia/Karachi) at Office 12%', 'customer A booked: ' || r);
  r := book_appointment(conv_a, v_day || ' 12:00', 'Ali Khan', null, null);
  perform pg_temp.ok(r like 'NOT BOOKED: this customer already has a booking%', 'one upcoming booking per customer');

  r := book_appointment(conv_b, v_slot, 'Bilal', null, null);
  perform pg_temp.ok(r like 'BOOKED:%', 'capacity 2: customer B takes the second spot');
  r := book_appointment(conv_c, v_slot, 'Chand', null, null);
  perform pg_temp.ok(r like 'NOT BOOKED:%', 'slot full for customer C');
  perform pg_temp.ok(check_availability(conv_c, v_day::text) not like '%11:00%', 'full slot no longer offered');

  perform pg_temp.ok((select customer_phone from appointments where conversation_id = conv_a) = '923335555555', 'phone saved from WhatsApp');
  perform pg_temp.ok((select status from leads where conversation_id = conv_a) = 'booked', 'lead marked booked');
  perform pg_temp.ok(my_appointments(conv_a) like 'Upcoming bookings:%11:00 (Site visit Phase 8)%', 'my_appointments lists it');

  perform pg_temp.ok(save_lead(conv_a, 'Wants 10 marla', '{"budget":"1.5 Cr"}', 'qualified') = 'Lead saved.', 'save_lead ok');
  perform pg_temp.ok((select status from leads where conversation_id = conv_a) = 'booked', 'save_lead keeps booked status');
  perform save_lead(conv_c, 'Just looking', 'not json, budget 50 lakh', 'whatever');
  perform pg_temp.ok((select answers->>'details' from leads where conversation_id = conv_c) = 'not json, budget 50 lakh'
                     and (select status from leads where conversation_id = conv_c) = 'qualified', 'save_lead handles free text');

  r := cancel_appointment(conv_a, 'Travelling');
  perform pg_temp.ok(r like 'CANCELLED:%', 'cancel works');
  perform pg_temp.ok(cancel_appointment(conv_a, null) like 'Nothing to cancel%', 'second cancel finds nothing');
  r := book_appointment(conv_c, v_slot, 'Chand', null, null);
  perform pg_temp.ok(r like 'BOOKED:%', 'freed spot can be booked again');

  perform pg_temp.ok((select count(*) from owner_notifications) = 4, '3 bookings + 1 cancel queued for owner');
end $$;

-- 6. Owner notices: sent once, only when the owner number is set
select pg_temp.ok((select count(*) from take_owner_notifications((select id from tenants where slug = 'bahria-prime'))) = 4, 'owner notices taken');
select pg_temp.ok((select count(*) from take_owner_notifications((select id from tenants where slug = 'bahria-prime'))) = 0, 'not sent twice');

-- 7. Closures block slots
do $$
declare v_t uuid := (select id from tenants where slug = 'glow-smile'); v_day date;
begin
  v_day := (now() at time zone 'Asia/Karachi')::date + 4;
  while extract(dow from v_day) = 0 loop v_day := v_day + 1; end loop;
  perform pg_temp.ok((select count(*) from available_slots(v_t, v_day, 1)) = 16, 'clinic: 16 half-hour slots');
  insert into closures (tenant_id, starts_at, ends_at, reason)
  values (v_t, (v_day + time '12:00') at time zone 'Asia/Karachi', (v_day + time '14:00') at time zone 'Asia/Karachi', 'Doctor away');
  perform pg_temp.ok((select count(*) from available_slots(v_t, v_day, 1)) = 12, 'closure removes 4 slots');
end $$;

-- 8. Time zone validation
do $$ begin
  begin
    update tenants set timezone = 'Mars/Olympus' where slug = 'glow-smile';
    raise exception 'FAIL: bad time zone accepted';
  exception when invalid_parameter_value or check_violation then
    raise notice 'ok - unknown time zone rejected';
  end;
end $$;

-- 9. RLS: an owner sees only their own business; anon sees nothing
insert into auth.users (id, email) values ('00000000-0000-0000-0000-000000000001', 'a@x.com'), ('00000000-0000-0000-0000-000000000002', 'b@x.com');
update tenants set owner_user_id = '00000000-0000-0000-0000-000000000001' where slug = 'bahria-prime';
update tenants set owner_user_id = '00000000-0000-0000-0000-000000000002' where slug = 'glow-smile';
grant usage on schema public, auth to authenticated, anon;
grant select on all tables in schema public to authenticated, anon;
grant execute on function auth.uid() to authenticated, anon;

set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-000000000001';
select pg_temp.ok((select count(*) from tenants) = 1 and (select count(*) from appointments) = 3
                  and (select count(distinct tenant_id) from knowledge_items) = 1, 'owner A sees only Bahria data');
select pg_temp.ok((select count(*) from n8n_chat_histories) = 0, 'chat memory hidden');
do $$ begin
  perform persona_prompt(gen_random_uuid(), 'whatsapp');
  raise exception 'FAIL: authenticated can run server functions';
exception when insufficient_privilege then raise notice 'ok - server functions blocked for logged-in users';
end $$;
reset role;
set role anon;
select pg_temp.ok((select count(*) from tenants) = 0 and (select count(*) from messages) = 0, 'anon sees nothing');
reset role;

\echo 'ALL DB TESTS PASSED'
