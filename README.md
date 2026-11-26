# AI Fronter: AI front desk for any business

An AI receptionist that answers customers on WhatsApp, shares the business's information, qualifies the
lead and **books appointments itself** into the business's own calendar. Built first for real estate, but
every business (clinic, salon, restaurant, agency...) is just rows in the database, with its own language,
time zone, currency, opening hours and booking rules.

This first version covers **WhatsApp chat and voice notes + booking**. Phone calls, WhatsApp calls and the
on-screen avatar kiosk come next and reuse the same database and prompt (see [Roadmap](#roadmap)).

## How it works

```
Customer on WhatsApp
      │  text or voice note
      ▼
Evolution API (WhatsApp gateway, Docker) ──webhook──►  n8n workflow (Docker)
                                                         │ 1. which business? (Evolution instance name)
                                                         │ 2. voice note → text (Groq Whisper)
                                                         │ 3. log message; stop if a human took over
                                                         │ 4. AI Agent (Gemini) with 5 tools:
                                                         │      check_availability, book_appointment,
                                                         │      my_appointments, cancel_appointment, save_lead
                                                         │ 5. reply on WhatsApp, log it
                                                         │ 6. new booking? WhatsApp alert to the owner
                                                         ▼
                                              Supabase Postgres (all business data,
                                              prompt builder, booking logic, security)
```

The AI never writes to tables directly. Every tool is a database function that only accepts the current
conversation id, so the AI can only see and book for the business and customer it is talking to, can only
pick a time that is really free, and two customers can never take the same last slot.

## What's in this repo

| Path | What it is |
| --- | --- |
| `docker-compose.yml` | n8n + Evolution API v2 + Evolution's Postgres and Redis |
| `.env.example` | Keys the containers need (copy to `.env`) |
| `db/001_tables.sql` … `db/005_seed.sql` | Database: tables, prompt builder, booking functions, security (RLS), demo data |
| `db/templates/new_business.sql` | Fill-in-the-blanks script to add a business |
| `n8n/whatsapp-fronter.json` | The n8n workflow to import |
| `scripts/create-whatsapp-instance.sh` | Connects a WhatsApp number (one per business) |
| `scripts/build_n8n_workflow.py` | Generates the workflow JSON (optional; you can edit in n8n instead) |
| `docs/n8n-guide-roman-urdu.md` | n8n guide in Roman Urdu: import, AI-builder prompt, manual build |
| `docker-compose.mock.yml`, `mock/` | Mock mode: test chat page, mock WhatsApp, mock AI, mock voice transcription |
| `tests/` | Database tests and end-to-end test scripts |

## Try it with no accounts (mock mode)

Runs the whole system on any computer with Docker, with no WhatsApp number, Supabase, Gemini or Groq:
```bash
docker compose -f docker-compose.mock.yml up
```
Open the test chat at http://localhost:8080, pick a business and chat as a customer. The database, the n8n
workflow, booking and owner alerts are the real ones; WhatsApp, the AI (a simple rule-based stand-in brain)
and voice-note transcription are mocked (`mock/`). `node tests/e2e/mock_demo.js` plays sample conversations.
Reset with `docker compose -f docker-compose.mock.yml down -v`.

## Setup (about 1 hour)

### 1. Accounts (free tiers are fine for testing)
- **Supabase**: supabase.com → New project. Keep the database password.
- **Google AI Studio**: aistudio.google.com → Get API key (Gemini).
- **Groq**: console.groq.com → API key (voice notes).
- **Docker Desktop** on your laptop, or Docker on a VPS.
- A **spare WhatsApp number** for testing (see [Risks](#risks)).

### 2. Database
Supabase → SQL Editor → New query. Paste and run each file **in order**:
`db/001_tables.sql`, `002_prompt_and_inbound.sql`, `003_booking.sql`, `004_security.sql`, `005_seed.sql`.

Check it worked:
```sql
select persona_prompt(id, 'whatsapp') from tenants where slug = 'bahria-prime';
```
You should see Hamza's full instructions, including today's date in Karachi time.

In `005_seed.sql` (or afterwards with an `update`), put your **test WhatsApp number** into
`channels.whatsapp_number` and your own number into `tenants.owner_whatsapp` to receive booking alerts.

### 3. Start the servers
```bash
cp .env.example .env      # then put long random strings in it
docker compose up -d
```
n8n opens at http://localhost:5678 (create your admin login). Evolution runs at http://localhost:8080.

### 4. Import the workflow
n8n → Workflows → **Import from file** → `n8n/whatsapp-fronter.json`.

### 5. Add the four credentials in n8n
Open each node with a red warning and create its credential:

| Credential | Type | Values |
| --- | --- | --- |
| Supabase Postgres | Postgres | From Supabase → **Connect** → **Session pooler** (not "Direct"): host, port 5432, database `postgres`, user `postgres.<project-ref>`, password. SSL: **require** |
| Gemini API key | Google Gemini (PaLM) API | Your AI Studio key |
| Groq API key | Header Auth | Name `Authorization`, Value `Bearer <your Groq key>` |
| Evolution API key | Header Auth | Name `apikey`, Value = `EVOLUTION_API_KEY` from your `.env` |

The same Postgres credential is used by the Persona, Log, Memory and the 5 tool nodes.

Model: the **Gemini** node uses `models/gemini-flash-latest` (always the current Flash model). If you want a
fixed version, pick it in that node.

Then switch the workflow to **Active / Published**.

### 6. Connect the WhatsApp number
```bash
scripts/create-whatsapp-instance.sh fronter_realestate
```
Scan the QR code (Evolution manager at http://localhost:8080/manager, or the URL the script prints) from
the phone: WhatsApp → Settings → Linked devices → Link a device. The instance name must match
`channels.evolution_instance` for that business (`fronter_realestate`, `fronter_clinic`, `fronter_istanbul`
in the demo data).

### 7. Test
From your personal WhatsApp, message the connected number:
- `Salam, Bahria Phase 8 mein 10 marla plot ka rate kya hai?` → Hamza answers from the knowledge base and asks about budget.
- `Kal site visit book kar dein` → Hamza checks free times for tomorrow (Karachi time), offers some, and books the one you pick. The owner number gets a WhatsApp alert.
- `Mera appointment cancel kar dein` → cancels, and the owner is told.
- A voice note in Urdu → transcribed and answered.
- A message in a WhatsApp group → ignored.

See bookings: `select * from appointments order by starts_at;`
See chats: `select * from messages order by id desc limit 20;`

## Running a business on it

**Add a business:** copy `db/templates/new_business.sql`, fill it in, run it, then connect its number (step 6).
One n8n workflow serves every business.

**Per-business settings** (all in `tenants`):

| Column | Example | Effect |
| --- | --- | --- |
| `language` | `English; switch to Turkish if the customer writes in Turkish` | How the AI talks |
| `timezone` | `Asia/Karachi`, `Europe/Istanbul` | "Tomorrow", opening hours and slots use this |
| `currency` | `PKR`, `TRY` | Currency the AI uses for prices |
| `stt_language` | `ur`, `tr`, `en` | Main language of voice notes |
| `booking_mode` | `calendar` / `link` / `callback` | AI books itself / shares `personas.booking_link` / offers a call back |
| `slot_minutes`, `slot_capacity` | `60`, `2` | Appointment length; how many at the same time (e.g. 2 advisors) |
| `min_notice_minutes`, `max_days_ahead` | `120`, `30` | Earliest and latest bookable time |
| `owner_whatsapp` | `923001111110` | Gets a WhatsApp for every booking and cancellation |

Opening hours are in `business_hours` (several rows per day allowed, e.g. lunch breaks), holidays and leave
in `closures`, and all business information in `knowledge_items` (one row per fact). Changes apply from the
next message because the prompt is rebuilt from the database every time.

**Take over a chat yourself:** `update conversations set status = 'human' where id = '...'`. The bot goes
quiet in that chat (messages are still saved). Set it back to `'ai'` to hand it back. The dashboard will
have a button for this.

**Leads:** the AI saves what it learns (budget, area, cash or installments...) with `save_lead`; see them in
`select * from leads order by updated_at desc;`. Booked leads are marked `booked`.

## Changes from the original guides
Built from the "AI Fronter Technical Guide & 10-Day Plan" and the "Technical Setup Guide", plus:
- The AI **books appointments itself** against real opening hours and capacity, instead of only sending a Cal.com link (the link is still an option per business).
- **Per-business language, time zone, currency and voice language** instead of fixed Pakistan defaults (Pakistan stays the default).
- Customer messages are **logged even during human takeover**.
- **Owner alerts** on WhatsApp for every booking and cancellation.
- Groups, status updates, channels and your own messages are filtered; WhatsApp's new `@lid` ids are handled.
- All SQL uses query parameters (no SQL injection), all keys live in credentials or `.env`.
- The AI memory table is locked with RLS (Supabase would otherwise expose it to the public API key).

## Tests
- `tests/run_db_tests.sh` builds a fresh database from `db/` on a local PostgreSQL and runs 40 checks
  (prompt, inbound, time zones, slots, capacity, double booking, cancel, closures, leads, owner alerts, RLS).
- The workflow was run end to end in n8n 2.49.6 against fake WhatsApp, Gemini and Groq servers
  (`tests/e2e/`): text reply, voice note, full booking with owner alert, group and own-message filters,
  unknown number, human takeover. It has **not** yet run against the real WhatsApp, Gemini and Groq services;
  do that in step 7. If a field name in Evolution's webhook differs in your version, fix it in the
  **Parse Message** node.

## Risks
- **WhatsApp ban:** Evolution API (Baileys) is not WhatsApp's official API, so a number can be banned. Test on a spare SIM, never send bulk or first-contact messages. For paying clients move to the official WhatsApp Cloud API (needed for WhatsApp calls anyway).
- **Free tiers:** Gemini's free tier has rate limits and Google may use the data; Supabase free projects pause after 7 days idle. Use paid tiers before the first real client.
- **Laptop off = bot off.** Move the Docker part to a small VPS for real use.

## Roadmap
1. ✅ WhatsApp chat + voice notes + booking (this version)
2. Owner dashboard (Next.js): business info, hours, chats, takeover button, leads, appointments
3. Phone calls (voice pipeline, same prompt and booking tools)
4. WhatsApp calls (official Cloud API)
5. On-screen avatar kiosk (`web_avatar` channel already in the database)
