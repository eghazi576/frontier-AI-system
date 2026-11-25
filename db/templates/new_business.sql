-- Add a new business. Copy this, fill in the values, and run it in Supabase → SQL Editor.
-- Then connect its WhatsApp number: scripts/create-whatsapp-instance.sh <evolution_instance>
with t as (
  insert into tenants (slug, business_name, industry, timezone, language, currency, stt_language,
                       phone, address, owner_whatsapp, booking_mode, slot_minutes, slot_capacity,
                       min_notice_minutes, max_days_ahead)
  values ('my-business',                 -- short unique id
          'My Business Name',
          'real_estate',                 -- real_estate, clinic, salon, restaurant, general (see industry_templates)
          'Europe/Istanbul',             -- time zone name: Asia/Karachi, Europe/Istanbul, Asia/Dubai ...
          'English; switch to Turkish if the customer writes in Turkish',  -- how the AI should talk
          'TRY',                         -- currency for prices
          'tr',                          -- main voice-note language: ur, en, tr, ar ...
          '+90 ...', 'Street, district, city',
          '90XXXXXXXXXX',                -- owner's WhatsApp (digits only) for booking alerts, or null
          'calendar',                    -- calendar = AI books itself; link = share booking_link; callback
          60,                            -- minutes per appointment
          1,                             -- appointments allowed at the same time
          120,                           -- earliest booking: minutes from now
          30)                            -- latest booking: days ahead
  returning id
), p as (
  insert into personas (tenant_id, name, role, tone_guidelines, greeting, qualification_questions, appointment_label)
  select t.id, 'Deniz', it.default_role, it.default_tone,
         'Hello, I am Deniz from My Business Name. How can I help?',
         it.default_questions,
         'site visit'                    -- what an appointment is called here
  from t join industry_templates it on it.industry = 'real_estate'
  returning tenant_id
), c as (
  insert into channels (tenant_id, type, evolution_instance, whatsapp_number)
  select t.id, 'whatsapp', 'fronter_mybusiness', '90XXXXXXXXXX' from t   -- instance name + business number
  returning tenant_id
), h as (
  insert into business_hours (tenant_id, weekday, opens, closes)   -- 0 = Sunday ... 6 = Saturday
  select t.id, d, time '09:00', time '18:00' from t, unnest(array[1,2,3,4,5]) d
  union all
  select t.id, 6, time '10:00', time '14:00' from t
  returning tenant_id
)
insert into knowledge_items (tenant_id, category, title, content, sort_order)
select t.id, v.* from t, (values
  ('Projects', 'Project A', 'What it is, prices, sizes, payment plan, delivery date.', 1),
  ('Services', 'Viewings',  'How viewings work, how long they take.', 1),
  ('Policies', 'Deposit',   'Deposit and cancellation rules.', 1)
) as v(category, title, content, sort_order);

-- Later changes are plain updates, e.g.:
--   update knowledge_items set content = '10 Marla plots, 1.50 Cr to 1.90 Cr.' where title = 'Bahria Town Phase 8';
--   insert into closures (tenant_id, starts_at, ends_at, reason)
--     select id, '2026-12-25 00:00+03', '2026-12-26 00:00+03', 'Holiday' from tenants where slug = 'my-business';
--   update conversations set status = 'human' where id = '...';   -- you take over a chat; the bot goes quiet
--   update conversations set status = 'ai'    where id = '...';   -- hand it back
