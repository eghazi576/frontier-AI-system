-- AI Fronter: seed data. 5 industry templates + 3 demo businesses.
-- Two Pakistan demos from the original guide (Urdu, Asia/Karachi, PKR) and one Istanbul demo
-- (English/Turkish, Europe/Istanbul, TRY) to show the per-business settings.
-- Replace the WhatsApp numbers with your own test numbers (digits only, no +).

insert into industry_templates values
('real_estate','Real Estate','Senior Property Advisor',
 'Respectful, confident. Use real estate terms (marla, kanal, possession, installments) where the customer does.',
 '1. Which area or project? 2. Budget? 3. Cash or installments? 4. Buying to live in or to invest? 5. When can they come for a site visit?'),
('clinic','Clinic / Aesthetics','Patient Care Coordinator',
 'Warm, polite, reassuring. Never give medical advice; offer a doctor consultation instead.',
 '1. Which treatment are they interested in? 2. Have they had it before? 3. Which day and time suits them?'),
('salon','Salon / Spa','Front Desk Executive',
 'Friendly and upbeat. Mention packages when relevant.',
 '1. Which service? 2. Which day? 3. Any preferred stylist?'),
('restaurant','Restaurant','Reservations Host',
 'Welcoming and quick. Confirm date, time and number of guests.',
 '1. How many guests? 2. Which day and time? 3. Any special occasion?'),
('general','General Business','Front Desk Assistant',
 'Polite, clear and helpful.',
 '1. What do they need help with? 2. Their name? 3. Best time for an appointment or call?');

with t as (
  insert into tenants (slug, business_name, industry, timezone, language, currency, stt_language, phone, address,
                       owner_whatsapp, slot_minutes, slot_capacity)
  values
  ('bahria-prime', 'Bahria Prime Associates', 'real_estate', 'Asia/Karachi',
   'natural Roman Urdu (Urdu written in English letters) mixed with common English terms', 'PKR', 'ur',
   '+92 300 1111111', 'Office 12, Civic Center, Bahria Town Phase 4, Rawalpindi', '923001111110', 60, 2),
  ('glow-smile', 'Glow & Smile Aesthetics Clinic F-7', 'clinic', 'Asia/Karachi',
   'natural Roman Urdu (Urdu written in English letters) mixed with common English terms', 'PKR', 'ur',
   '+92 300 2222222', 'F-7 Markaz, Islamabad', '923002222220', 30, 1),
  ('bosphorus-homes', 'Bosphorus Homes Istanbul', 'real_estate', 'Europe/Istanbul',
   'English; switch to Turkish, Arabic or Russian if the customer writes in it', 'TRY', 'tr',
   '+90 212 000 0000', 'Levent, Besiktas, Istanbul', null, 60, 1)
  returning id, slug, industry
), p as (
  insert into personas (tenant_id, name, role, tone_guidelines, greeting, qualification_questions,
                        appointment_label, booking_link, voice_id)
  select t.id,
         case t.slug when 'bahria-prime' then 'Hamza' when 'glow-smile' then 'Sara' else 'Deniz' end,
         it.default_role, it.default_tone,
         case t.slug
           when 'bahria-prime' then 'Assalam o Alaikum, main Hamza hoon, Bahria Prime Associates se. Aap kis project mein interested hain?'
           when 'glow-smile'   then 'Assalam o Alaikum, main Sara hoon, Glow and Smile Clinic se. Main aap ki kya madad kar sakti hoon?'
           else 'Hello, I am Deniz from Bosphorus Homes. Are you looking to buy, rent or invest in Istanbul?' end,
         it.default_questions,
         case t.industry when 'real_estate' then 'site visit' else 'appointment' end,
         null,
         case t.slug when 'bahria-prime' then 'ur-PK-AsadNeural'
                     when 'glow-smile'   then 'ur-PK-UzmaNeural' else 'en-US-AvaMultilingualNeural' end
  from t join industry_templates it on it.industry = t.industry
  returning tenant_id
), c as (
  insert into channels (tenant_id, type, evolution_instance, whatsapp_number, public_slug)
  select t.id, 'whatsapp',
         case t.slug when 'bahria-prime' then 'fronter_realestate'
                     when 'glow-smile'   then 'fronter_clinic' else 'fronter_istanbul' end,
         case t.slug when 'bahria-prime' then '923001111111'
                     when 'glow-smile'   then '923002222222' else '902120000000' end,
         null
  from t
  union all
  select t.id, 'web_avatar', null, null, t.slug from t
  returning tenant_id
), h as (
  -- Opening hours. weekday 0 = Sunday.
  insert into business_hours (tenant_id, weekday, opens, closes)
  select t.id, d, v.opens, v.closes
  from t
  join (values ('bahria-prime',   time '10:00', time '19:00', array[1,2,3,4,5,6]),
               ('glow-smile',     time '12:00', time '20:00', array[1,2,3,4,5,6]),
               ('bosphorus-homes',time '09:30', time '18:30', array[1,2,3,4,5]),
               ('bosphorus-homes',time '10:00', time '15:00', array[6])
       ) as v(slug, opens, closes, days) on v.slug = t.slug
  cross join lateral unnest(v.days) d
  returning tenant_id
)
insert into knowledge_items (tenant_id, category, title, content, sort_order)
select t.id, v.category, v.title, v.content, v.sort_order
from t join (values
  ('bahria-prime','Projects','Bahria Town Phase 8','10 Marla plots, 1.45 Cr to 1.80 Cr, possession ready.',1),
  ('bahria-prime','Projects','Gulberg Greens','Farmhouses and commercial shops on 2-year installments, 30% down payment.',2),
  ('bahria-prime','Services','Site visits','Free guided site visit with an advisor, about 1 hour. Meet at the office first.',1),
  ('glow-smile','Services','HydraFacial','Rs. 8,000 per session.',1),
  ('glow-smile','Services','Laser Hair Removal (Full Body)','Rs. 25,000 per session.',2),
  ('glow-smile','Services','Dental Scaling & Polishing','Rs. 6,000.',3),
  ('glow-smile','Doctors','Dr. Ayesha','Available during all clinic hours.',1),
  ('bosphorus-homes','Projects','Levent Residence','1+1 to 3+1 apartments, from 9,500,000 TRY. Ready to move in. Gym, pool, 24h security.',1),
  ('bosphorus-homes','Projects','Basaksehir Garden','2+1 and 3+1 family apartments, from 6,200,000 TRY. 24-month installment plan with 35% down payment. Delivery June 2027.',2),
  ('bosphorus-homes','Services','Citizenship','Purchases of at least 400,000 USD can qualify for Turkish citizenship by investment; our partner lawyer explains the process at the office.',1),
  ('bosphorus-homes','Services','Viewings','Free viewing with an advisor, about 1 hour. Online video viewings also possible.',2)
) as v(slug, category, title, content, sort_order) on v.slug = t.slug;

-- Checks:
--   select persona_prompt(id, 'whatsapp') from tenants where slug = 'bahria-prime';
--   select * from fronter_inbound('fronter_realestate', '923335555555@s.whatsapp.net', 'Test', '923335555555');
--
-- After you sign up in the dashboard, link the demo businesses to your login:
--   update tenants set owner_user_id = (select id from auth.users where email = 'you@example.com')
--   where slug in ('bahria-prime', 'glow-smile', 'bosphorus-homes');
