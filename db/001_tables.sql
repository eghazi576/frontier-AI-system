-- AI Fronter: tables
-- Run the db/ files in order (001 → 005) in Supabase → SQL Editor.
-- Every business ("tenant") has its own language, time zone, currency,
-- opening hours and booking rules, so the same system serves any business.

create extension if not exists pgcrypto;

-- One row per business.
create table tenants (
  id                 uuid primary key default gen_random_uuid(),
  slug               text unique not null,                -- 'bahria-prime'
  business_name      text not null,
  industry           text not null,                       -- 'real_estate', 'clinic', ...
  owner_user_id      uuid references auth.users(id) on delete set null,
  -- Per-business settings
  timezone           text not null default 'Asia/Karachi'
                     check ((timestamp '2000-01-01' at time zone timezone) is not null), -- rejects unknown zones
  language           text not null default 'natural Roman Urdu (Urdu written in English letters) mixed with common English terms',
  currency           text not null default 'PKR',
  stt_language       text not null default 'ur',  -- voice-note language code for Whisper: ur, en, tr, ar...
  phone              text,
  address            text,
  owner_whatsapp     text,           -- owner's number (digits only); gets a WhatsApp note for each booking
  -- Booking rules
  booking_mode       text not null default 'calendar'
                     check (booking_mode in ('calendar','link','callback')),
  slot_minutes       int  not null default 60  check (slot_minutes between 5 and 480),
  slot_capacity      int  not null default 1   check (slot_capacity between 1 and 100),
  min_notice_minutes int  not null default 120 check (min_notice_minutes >= 0),
  max_days_ahead     int  not null default 30  check (max_days_ahead between 1 and 365),
  is_active          boolean not null default true,
  created_at         timestamptz not null default now()
);

-- Default role / tone / questions per industry. A new industry is one row.
create table industry_templates (
  industry          text primary key,
  display_name      text not null,
  default_role      text not null,
  default_tone      text not null,
  default_questions text not null
);

-- The front-desk persona of a business.
create table personas (
  id                      uuid primary key default gen_random_uuid(),
  tenant_id               uuid not null unique references tenants(id) on delete cascade,
  name                    text not null,                 -- 'Hamza'
  role                    text not null,                 -- 'Senior Property Advisor'
  tone_guidelines         text not null,
  greeting                text not null,
  qualification_questions text not null,
  appointment_label       text not null default 'appointment', -- 'site visit', 'consultation', ...
  booking_link            text,                          -- used when booking_mode = 'link'
  avatar_provider         text not null default 'talkinghead_3d'
                          check (avatar_provider in ('talkinghead_3d','simli','liveavatar')),
  avatar_model_url        text,
  avatar_image_url        text,
  tts_provider            text not null default 'azure',
  voice_id                text,                          -- 'ur-PK-AsadNeural'
  updated_at              timestamptz not null default now()
);

-- How customers reach a business: a WhatsApp number (Evolution instance) or an avatar link.
create table channels (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references tenants(id) on delete cascade,
  type               text not null check (type in ('whatsapp','web_avatar')),
  evolution_instance text unique,      -- WhatsApp: Evolution instance name
  whatsapp_number    text unique,      -- digits only, no +
  public_slug        text unique,      -- avatar: /a/<public_slug>
  is_active          boolean not null default true,
  check ((type = 'whatsapp'   and evolution_instance is not null)
      or (type = 'web_avatar' and public_slug is not null))
);

-- Business information: one row per fact (project, price, service, policy...).
create table knowledge_items (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references tenants(id) on delete cascade,
  category   text not null,            -- 'Projects', 'Prices', 'Location'
  title      text not null,
  content    text not null,
  sort_order int  not null default 0,
  is_active  boolean not null default true,
  updated_at timestamptz not null default now()
);
create index knowledge_by_tenant on knowledge_items (tenant_id, category, sort_order);

-- Opening hours, in the business's own time zone. weekday: 0 = Sunday ... 6 = Saturday.
-- A day can have several rows (e.g. 10:00-13:00 and 14:00-19:00 for a lunch break).
create table business_hours (
  tenant_id uuid     not null references tenants(id) on delete cascade,
  weekday   smallint not null check (weekday between 0 and 6),
  opens     time     not null,
  closes    time     not null check (closes > opens),
  primary key (tenant_id, weekday, opens)
);

-- Holidays, leave, blocked periods: no bookings inside these.
create table closures (
  id        uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  starts_at timestamptz not null,
  ends_at   timestamptz not null check (ends_at > starts_at),
  reason    text
);
create index closures_by_tenant on closures (tenant_id, starts_at);

-- Every customer (WhatsApp number or avatar browser session).
create table contacts (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references tenants(id) on delete cascade,
  channel_type text not null check (channel_type in ('whatsapp','web_avatar')),
  external_id  text not null,          -- WhatsApp JID or browser session id
  display_name text,
  phone        text,                   -- digits only, when known
  created_at   timestamptz not null default now(),
  unique (tenant_id, channel_type, external_id)
);

create table conversations (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  contact_id      uuid not null references contacts(id) on delete cascade,
  channel_type    text not null check (channel_type in ('whatsapp','web_avatar')),
  status          text not null default 'ai' check (status in ('ai','human','closed')),
  started_at      timestamptz not null default now(),
  last_message_at timestamptz not null default now()
);
-- A contact has at most one open conversation.
create unique index conversations_one_open on conversations (contact_id) where status <> 'closed';
create index conversations_by_tenant on conversations (tenant_id, last_message_at desc);

create table messages (
  id              bigint generated always as identity primary key,
  conversation_id uuid not null references conversations(id) on delete cascade,
  tenant_id       uuid not null references tenants(id) on delete cascade,
  role            text not null check (role in ('user','assistant','human_agent')),
  content         text not null,
  media_type      text not null default 'text' check (media_type in ('text','audio','image','other')),
  created_at      timestamptz not null default now()
);
create index messages_by_conversation on messages (conversation_id, created_at);

create table leads (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  contact_id      uuid not null references contacts(id) on delete cascade,
  conversation_id uuid not null unique references conversations(id) on delete cascade,
  summary         text,
  answers         jsonb not null default '{}',
  status          text not null default 'new' check (status in ('new','qualified','booked','lost')),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create table appointments (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references tenants(id) on delete cascade,
  contact_id      uuid not null references contacts(id) on delete cascade,
  conversation_id uuid references conversations(id) on delete set null,
  service         text,                -- what it is for: 'Site visit, Phase 8 plots'
  customer_name   text,
  customer_phone  text,
  notes           text,
  starts_at       timestamptz not null,
  ends_at         timestamptz not null check (ends_at > starts_at),
  status          text not null default 'booked'
                  check (status in ('booked','cancelled','completed','no_show')),
  source          text not null default 'whatsapp',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index appointments_by_time on appointments (tenant_id, starts_at) where status = 'booked';
create index appointments_by_contact on appointments (contact_id, starts_at);

-- Messages for the business owner (new booking, cancellation). n8n sends them on WhatsApp.
create table owner_notifications (
  id         bigint generated always as identity primary key,
  tenant_id  uuid not null references tenants(id) on delete cascade,
  body       text not null,
  sent_at    timestamptz,
  created_at timestamptz not null default now()
);
create index owner_notifications_pending on owner_notifications (tenant_id) where sent_at is null;

-- n8n's "Postgres Chat Memory" node keeps the AI's short-term memory here.
-- It would create this table itself, but creating it now lets us lock it down with RLS (004).
create table if not exists n8n_chat_histories (
  id         serial primary key,
  session_id varchar(255) not null,
  message    jsonb not null
);
create index if not exists n8n_chat_histories_session on n8n_chat_histories (session_id);
