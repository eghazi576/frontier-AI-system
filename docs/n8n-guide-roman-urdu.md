# n8n Automation Guide (Roman Urdu)

Is system mein **ek hi n8n workflow** hai: "AI Fronter - WhatsApp". Yahi ek workflow saare businesses
ke WhatsApp messages sambhalta hai, AI se jawab banwata hai, appointment book karta hai aur owner ko
alert bhejta hai. Usay banane ke 3 tareeqay hain. **Tareeqa 1 sab se behtar hai.**

| Tareeqa | Waqt | Kab use karein |
| --- | --- | --- |
| 1. Ready JSON import karna | 5 minute | Hamesha. Yeh tested hai |
| 2. n8n AI Workflow Builder ko prompt dena | 15-30 minute | Agar aap AI builder try karna chahte hain |
| 3. Haath se node-by-node banana | 1-2 ghante | Seekhne ke liye, ya kuch badalna ho |

Kisi bhi tareeqay se pehle database tayyar hona chahiye (README step 2: `db/001` se `db/005` tak SQL chalayein).

---

## Tareeqa 1: Ready workflow import karein (recommended)

1. GitHub repo se `n8n/whatsapp-fronter.json` file download karein.
2. n8n kholein → left side **Workflows** → upar right **⋯ / Create** → **Import from File** → woh file chunein.
3. Jin nodes par laal (red) nishan hai, un ko khol kar credential banayein. Sirf 4 credentials chahiye:

| Credential ka naam | n8n mein type | Kya bharna hai |
| --- | --- | --- |
| Supabase Postgres | Postgres | Supabase → Connect → **Session pooler**: Host, Port 5432, Database `postgres`, User `postgres.<project-ref>`, Password. SSL = require |
| Gemini API key | Google Gemini (PaLM) API | AI Studio ki API key |
| Groq API key | Header Auth | Name: `Authorization`, Value: `Bearer <groq key>` |
| Evolution API key | Header Auth | Name: `apikey`, Value: `.env` wali `EVOLUTION_API_KEY` |

4. Upar **Save**, phir **Publish / Active** ON karein.
5. Test: apne doosre number se connected WhatsApp number par "Salam" bhejein.

Bas. Neeche ke tareeqay sirf tab chahiye jab aap khud banana chahein.

---

## Tareeqa 2: n8n AI Workflow Builder ke liye prompt

n8n ke naye versions mein workflow ke andar **AI Builder** (chat box, "Build with AI") hota hai. Neeche
wala poora prompt copy kar ke wahan paste karein. Prompt English mein hai kyun ke builder English mein
sab se sahi kaam karta hai.

**Zaroori:** AI builder har dafa thora mukhtalif workflow banata hai aur aksar choti ghaltiyan karta hai.
Banne ke baad neeche "Tareeqa 3" ki settings se har node check karein, khas kar SQL queries aur
"Query Parameters". Agar kuch ajeeb lage to Tareeqa 1 (import) use karein.

### Prompt (copy karein)

```text
Build an n8n workflow named "AI Fronter - WhatsApp". It is an AI front desk for many businesses on
WhatsApp. All business data and logic live in a Postgres (Supabase) database that already has these
SQL functions: fronter_inbound, fronter_log, check_availability, book_appointment, my_appointments,
cancel_appointment, save_lead, take_owner_notifications. Do not create tables. Use exactly these node
names, because later nodes reference them by name.

1. "WhatsApp Inbound": Webhook node, POST, path "whatsapp-inbound", respond immediately.
   It receives Evolution API v2 "messages.upsert" events.

2. "Parse Message": Code node (JavaScript, run once for all items). From $input.first().json.body read:
   instance = body.instance; data = body.data; key = data.key; msg = data.message.
   jid = key.remoteJid, but if it ends with "@lid" use key.remoteJidAlt or key.senderPn instead.
   type = data.messageType.
   text = msg.conversation || msg.extendedTextMessage?.text || msg.imageMessage?.caption || "".
   isDirect = instance is set AND key.fromMe is false AND jid ends with "@s.whatsapp.net" or "@lid".
   phone = digits before "@" when jid ends with "@s.whatsapp.net", else "".
   name = data.pushName || "". isAudio = type is "audioMessage". audioBase64 = msg.base64 || "".
   Return one item with: instance, jid, phone, name, type, text, isAudio, audioBase64, isDirect.

3. "Customer Message?": IF node, boolean {{ $json.isDirect }} is true. Only the true branch continues.

4. "Persona": Postgres node, operation Execute Query, credential "Supabase Postgres".
   Query: select * from fronter_inbound($1, $2, $3, $4);
   Options > Query Parameters (one expression returning an array):
   {{ [ $json.instance, $json.jid, $json.name, $json.phone ] }}
   It returns tenant_id, conversation_id, conv_status, system_prompt, stt_language.

5. "Voice Note?": IF node, boolean {{ $('Parse Message').first().json.isAudio }} is true.
   True branch goes to "Audio File", false branch goes straight to "User Text".

6. "Audio File": Code node returning one item with json {} and binary.file =
   { data: $('Parse Message').first().json.audioBase64, mimeType: 'audio/ogg', fileName: 'voice.ogg' }.

7. "Groq Whisper": HTTP Request, POST https://api.groq.com/openai/v1/audio/transcriptions,
   authentication Generic Credential > Header Auth credential "Groq API key".
   Body: multipart form-data with fields: file = n8n binary field "file"; model = whisper-large-v3;
   language = {{ $('Persona').first().json.stt_language || 'ur' }}. Settings: On Error = Continue.
   Output goes to "User Text".

8. "User Text": Code node. p = $('Parse Message').first().json.
   If p.isAudio: user_text = $input.first().json.text (trimmed), media = "audio"; if empty use
   "[The customer sent a voice note that could not be understood. Politely ask them to type or send it again.]".
   Else user_text = p.text; media = "text" (or "image" for imageMessage); if empty use
   "[The customer sent a <type> without text. You cannot see it; ask what they need.]".
   Return { user_text, media }.

9. "Log Customer Message": Postgres Execute Query:
   select fronter_log($1::uuid, 'user', $2, $3);
   Query Parameters: {{ [ $('Persona').first().json.conversation_id, $json.user_text, $json.media ] }}
   Settings: On Error = Continue, Always Output Data = on.

10. "AI Mode?": IF node, string {{ $('Persona').first().json.conv_status }} equals "ai".
    Only the true branch continues (false = a human took over, bot stays quiet).

11. "AI Agent": AI Agent node (Tools Agent). Prompt source: Define below,
    text = {{ $('User Text').first().json.user_text }}.
    Options > System Message = {{ $('Persona').first().json.system_prompt }}. Max iterations 8.
    Sub-nodes:
    - Chat model: Google Gemini Chat Model, credential "Gemini API key", model models/gemini-flash-latest, temperature 0.4.
    - Memory: Postgres Chat Memory, credential "Supabase Postgres", session key (Define below)
      {{ $('Persona').first().json.conversation_id }}, table n8n_chat_histories, context window 10.
    - Five "Postgres Tool" nodes, credential "Supabase Postgres", operation Execute Query, each with a
      manual tool description. In each, Query Parameters is ONE expression that returns an array, and
      $fromAI descriptions contain no quote characters:
      a) "check_availability" – description: Get the free appointment times. Use before offering or booking any time.
         Query: select check_availability($1::uuid, $2) as result;
         Params: {{ [ $('Persona').first().json.conversation_id, $fromAI('date', 'Day to check as YYYY-MM-DD in the business time zone. Empty string for the next free days', 'string') ] }}
      b) "book_appointment" – description: Book an appointment for this customer in a free slot returned by check_availability.
         Query: select book_appointment($1::uuid, $2, $3, $4, $5) as result;
         Params: {{ [ $('Persona').first().json.conversation_id, $fromAI('slot', 'Exact slot as YYYY-MM-DD HH:MM from check_availability', 'string'), $fromAI('customer_name', 'Name of the customer', 'string'), $fromAI('service', 'What the appointment is for', 'string'), $fromAI('notes', 'Useful details for the team. Empty string if none', 'string') ] }}
      c) "my_appointments" – description: List this customer's upcoming bookings.
         Query: select my_appointments($1::uuid) as result;
         Params: {{ [ $('Persona').first().json.conversation_id ] }}
      d) "cancel_appointment" – description: Cancel this customer's next upcoming booking, only when they clearly ask.
         Query: select cancel_appointment($1::uuid, $2) as result;
         Params: {{ [ $('Persona').first().json.conversation_id, $fromAI('reason', 'Reason for cancelling, or empty string', 'string') ] }}
      e) "save_lead" – description: Save what you learned about the customer (needs, budget, timeline) for the sales team.
         Query: select save_lead($1::uuid, $2, $3, $4) as result;
         Params: {{ [ $('Persona').first().json.conversation_id, $fromAI('summary', 'Short summary of the customer and what they want', 'string'), $fromAI('details', 'Answers to the qualification questions', 'string'), $fromAI('status', 'qualified, lost or new', 'string') ] }}

12. "Send Reply": HTTP Request, POST
    http://evolution_api:8080/message/sendText/{{ $('Parse Message').first().json.instance }}
    Authentication: Header Auth credential "Evolution API key". Send Body, JSON, "Using Fields Below":
    number = {{ $('Parse Message').first().json.jid }}, text = {{ $('AI Agent').first().json.output }}.
    Retry on fail: 3 tries, 2000 ms.

13. "Log Reply": Postgres Execute Query: select fronter_log($1::uuid, 'assistant', $2, 'text');
    Params: {{ [ $('Persona').first().json.conversation_id, $('AI Agent').first().json.output ] }}
    On Error = Continue, Always Output Data = on.

14. "Owner Notices": Postgres Execute Query: select * from take_owner_notifications($1::uuid);
    Params: {{ [ $('Persona').first().json.tenant_id ] }}. On Error = Continue.
    It returns zero or more rows with owner_number and body.

15. "Notify Owner": HTTP Request, same URL and credential as "Send Reply", body fields
    number = {{ $json.owner_number }}, text = {{ $json.body }}. On Error = Continue.

Connections: WhatsApp Inbound → Parse Message → Customer Message? (true) → Persona → Voice Note?
(true → Audio File → Groq Whisper → User Text; false → User Text) → Log Customer Message → AI Mode? (true)
→ AI Agent → Send Reply → Log Reply → Owner Notices → Notify Owner.
```

---

## Tareeqa 3: Haath se banana (node by node)

n8n mein **New Workflow** banayein, naam rakhein `AI Fronter - WhatsApp`. Har node ka **naam bilkul wahi
rakhein** jo neeche likha hai (node par double click → upar naam), kyun ke baad wale nodes naam se
pichle nodes ko parhte hain, jaise `$('Persona')`.

**Expression kaise likhein:** jis field mein `{{ }}` wala code ho, us field ke upar **Expression** chunein
(ya field mein `{{` likhna shuru karein), phir paste karein.

### Node 1: WhatsApp Inbound (Webhook)
- **+** → *On webhook call*.
- HTTP Method: `POST`, Path: `whatsapp-inbound`, Respond: `Immediately`.
- Evolution is URL par message bhejega: `http://n8n:5678/webhook/whatsapp-inbound`.

### Node 2: Parse Message (Code)
- **+** → *Code* → Mode: *Run Once for All Items*, Language: JavaScript. Yeh code paste karein:

```js
const body = $input.first().json.body || {};
const data = body.data || {};
const key = data.key || {};
const msg = data.message || {};

let jid = key.remoteJid || '';
if (jid.endsWith('@lid')) jid = key.remoteJidAlt || key.senderPn || jid;

const type = data.messageType
  || Object.keys(msg).find(k => !['messageContextInfo', 'base64'].includes(k))
  || 'unknown';
const text = msg.conversation || msg.extendedTextMessage?.text
  || msg.imageMessage?.caption || msg.videoMessage?.caption || msg.documentMessage?.caption || '';

// Sirf customer ki 1-to-1 chat: apne messages, groups, status aur channels nahi
const isDirect = Boolean(body.instance) && !key.fromMe
  && (jid.endsWith('@s.whatsapp.net') || jid.endsWith('@lid'));

return [{ json: {
  instance: body.instance || '', jid,
  phone: jid.endsWith('@s.whatsapp.net') ? jid.split('@')[0] : '',
  name: data.pushName || '', type, text,
  isAudio: type === 'audioMessage' || type === 'pttMessage',
  audioBase64: msg.base64 || '', isDirect,
} }];
```

### Node 3: Customer Message? (IF)
- Condition: Value 1 (expression) `{{ $json.isDirect }}` → *Boolean* → *is true*.
- Sirf **true** wale output ko aage jorein. False ko khali chhor dein.

### Node 4: Persona (Postgres)
- **+** → *Postgres* → *Execute a SQL query*. Credential: `Supabase Postgres`.
- Query: `select * from fronter_inbound($1, $2, $3, $4);`
- **Options → Add option → Query Parameters**, expression:
  `{{ [ $json.instance, $json.jid, $json.name, $json.phone ] }}`
- Yeh business ki persona, conversation_id aur poora system prompt laata hai. Agar WhatsApp instance
  database mein nahi to koi row nahi aati aur workflow ruk jata hai (yeh theek hai).

### Node 5: Voice Note? (IF)
- Condition: `{{ $('Parse Message').first().json.isAudio }}` → Boolean → is true.
- **true** → Node 6. **false** → seedha Node 8 (User Text).

### Node 6: Audio File (Code)
```js
const p = $('Parse Message').first().json;
return [{ json: {}, binary: { file: { data: p.audioBase64, mimeType: 'audio/ogg', fileName: 'voice.ogg' } } }];
```

### Node 7: Groq Whisper (HTTP Request)
- Method `POST`, URL `https://api.groq.com/openai/v1/audio/transcriptions`
- Authentication: *Generic Credential Type* → *Header Auth* → `Groq API key`
- Send Body ON → Body Content Type: *Form-Data* → 3 parameters:
  - `file` → Parameter Type *n8n Binary File* → Input Data Field Name `file`
  - `model` → `whisper-large-v3`
  - `language` → expression `{{ $('Persona').first().json.stt_language || 'ur' }}`
- Settings (gear) → **On Error: Continue**. Output → Node 8.

### Node 8: User Text (Code)
Node 5 ka false output aur Node 7 ka output **dono** is node se jorein.
```js
const p = $('Parse Message').first().json;
let user_text = (p.text || '').trim();
let media = p.type === 'imageMessage' ? 'image' : 'text';
if (p.isAudio) {
  media = 'audio';
  user_text = String($input.first().json.text || '').trim()
    || '[The customer sent a voice note that could not be understood. Politely ask them to type or send it again.]';
} else if (!user_text) {
  media = p.type === 'imageMessage' ? 'image' : 'other';
  user_text = `[The customer sent a ${p.type.replace('Message', '')} without text. You cannot see it; ask what they need.]`;
}
return [{ json: { user_text, media } }];
```

### Node 9: Log Customer Message (Postgres)
- Execute query: `select fronter_log($1::uuid, 'user', $2, $3);`
- Query Parameters: `{{ [ $('Persona').first().json.conversation_id, $json.user_text, $json.media ] }}`
- Settings → On Error: *Continue*, aur **Always Output Data: ON**.

### Node 10: AI Mode? (IF)
- `{{ $('Persona').first().json.conv_status }}` → *String* → *is equal to* → `ai`
- Sirf **true** ko aage jorein. False ka matlab owner ne chat khud sambhal li hai, bot chup rehta hai.

### Node 11: AI Agent
- **+** → *AI Agent*. Source for Prompt: *Define below*. Prompt: `{{ $('User Text').first().json.user_text }}`
- Options → **System Message**: `{{ $('Persona').first().json.system_prompt }}` (prompt database banata hai,
  yahan kuch aur nahi likhna). Options → Max Iterations: `8`.
- Agent ke neeche 3 jagah hain, un mein yeh lagayein:
  - **Chat Model** → *Google Gemini Chat Model* → credential `Gemini API key` → Model `models/gemini-flash-latest`.
  - **Memory** → *Postgres Chat Memory* → credential `Supabase Postgres` → Session ID: *Define below* →
    `{{ $('Persona').first().json.conversation_id }}` → Table `n8n_chat_histories` → Context Window `10`.
  - **Tool** → *Postgres Tool* (5 dafa). Har ek: credential `Supabase Postgres`, Operation *Execute Query*,
    Description: *Set manually*. Node ka naam, description, query aur Query Parameters yeh rakhein:

| Tool node ka naam | Description | Query |
| --- | --- | --- |
| `check_availability` | Get the free appointment times. Use before offering or booking any time. | `select check_availability($1::uuid, $2) as result;` |
| `book_appointment` | Book an appointment for this customer in a free slot returned by check_availability. | `select book_appointment($1::uuid, $2, $3, $4, $5) as result;` |
| `my_appointments` | List this customer's upcoming bookings. | `select my_appointments($1::uuid) as result;` |
| `cancel_appointment` | Cancel this customer's next upcoming booking. Only after the customer clearly asks to cancel or move it. | `select cancel_appointment($1::uuid, $2) as result;` |
| `save_lead` | Save what you learned about the customer (needs, budget, timeline) for the sales team. | `select save_lead($1::uuid, $2, $3, $4) as result;` |

  Query Parameters (har tool mein **ek hi expression**, array ki shakal mein):
  ```text
  check_availability:  {{ [ $('Persona').first().json.conversation_id, $fromAI('date', 'Day to check as YYYY-MM-DD in the business time zone. Empty string for the next free days', 'string') ] }}
  book_appointment:    {{ [ $('Persona').first().json.conversation_id, $fromAI('slot', 'Exact slot as YYYY-MM-DD HH:MM from check_availability', 'string'), $fromAI('customer_name', 'Name of the customer', 'string'), $fromAI('service', 'What the appointment is for', 'string'), $fromAI('notes', 'Useful details for the team. Empty string if none', 'string') ] }}
  my_appointments:     {{ [ $('Persona').first().json.conversation_id ] }}
  cancel_appointment:  {{ [ $('Persona').first().json.conversation_id, $fromAI('reason', 'Reason for cancelling, or empty string', 'string') ] }}
  save_lead:           {{ [ $('Persona').first().json.conversation_id, $fromAI('summary', 'Short summary of the customer and what they want', 'string'), $fromAI('details', 'Answers to the qualification questions', 'string'), $fromAI('status', 'qualified, lost or new', 'string') ] }}
  ```
  Do ghaltiyan jo humne test mein pakri:
  - `$fromAI(...)` ki description mein **apostrophe ya quote (' " `) na likhein**, warna n8n error deta hai.
  - Parameters ko comma se alag alag `{{ }}` mein na likhein. Agar AI koi field khali bheje (jaise notes)
    to n8n woh parameter gira deta hai aur query fail hoti hai. Isi liye **ek array** `{{ [ ... ] }}`.

### Node 12: Send Reply (HTTP Request)
- Method `POST`, URL (expression):
  `http://evolution_api:8080/message/sendText/{{ $('Parse Message').first().json.instance }}`
- Authentication: Generic → Header Auth → `Evolution API key`
- Send Body ON → JSON → *Using Fields Below*:
  - `number` = `{{ $('Parse Message').first().json.jid }}`
  - `text` = `{{ $('AI Agent').first().json.output }}`
- Settings → Retry On Fail ON, Max Tries 3, Wait 2000 ms.

### Node 13: Log Reply (Postgres)
- `select fronter_log($1::uuid, 'assistant', $2, 'text');`
- Parameters: `{{ [ $('Persona').first().json.conversation_id, $('AI Agent').first().json.output ] }}`
- On Error: Continue, Always Output Data: ON.

### Node 14: Owner Notices (Postgres)
- `select * from take_owner_notifications($1::uuid);`
- Parameters: `{{ [ $('Persona').first().json.tenant_id ] }}` · On Error: Continue.
- Nayi booking ya cancel hui ho to yeh owner ke liye message deta hai, warna kuch nahi (aur workflow yahin khatam).

### Node 15: Notify Owner (HTTP Request)
- Node 12 jaisa hi URL aur credential. Body: `number` = `{{ $json.owner_number }}`, `text` = `{{ $json.body }}`.
- On Error: Continue.

### Jorr (connections) ek nazar mein
```
WhatsApp Inbound → Parse Message → Customer Message? (true) → Persona → Voice Note?
   Voice Note? true  → Audio File → Groq Whisper → User Text
   Voice Note? false → User Text
User Text → Log Customer Message → AI Mode? (true) → AI Agent → Send Reply → Log Reply → Owner Notices → Notify Owner
AI Agent ke neeche: Gemini (model), Memory, aur 5 tools
```

Akhir mein **Save** aur **Publish/Active** ON karein.

---

## Check karna ke sab theek chal raha hai

1. n8n → **Executions** tab: har aane wale message ki ek line aati hai. Kisi node par laal nishan ho to
   us par click kar ke error parhein.
2. Supabase SQL Editor:
   ```sql
   select role, content, created_at from messages order by id desc limit 10;   -- chats
   select * from appointments order by starts_at;                               -- bookings
   select * from leads order by updated_at desc;                                -- leads
   ```
3. Aam masle:

| Masla | Wajah / hal |
| --- | --- |
| Persona node ke baad kuch nahi hota | Evolution instance ka naam `channels.evolution_instance` se match nahi karta |
| Bot jawab nahi deta, AI Mode? par ruk jata hai | Us chat ka `conversations.status` = `human` hai; wapis `ai` karein |
| "there is no parameter $2" | Query Parameters alag alag `{{ }}` mein likhe hain; ek array `{{ [ ... ] }}` banayein |
| "Unbalanced parentheses while parsing $fromAI" | `$fromAI` description mein apostrophe/quote hai; hata dein |
| Gemini model error | Gemini node mein AI Studio ka koi current Flash model chunein |
| Voice note ka jawab ajeeb | `tenants.stt_language` business ki zuban par set karein (ur, en, tr) |

## Bina kisi account ke test (mock mode)
Docker wale kisi bhi computer par: `docker compose -f docker-compose.mock.yml up`, phir
`http://localhost:8080` par test chat kholein. Is mein yahi workflow khud import ho jata hai, WhatsApp aur
AI mock hote hain. Detail README mein hai.
