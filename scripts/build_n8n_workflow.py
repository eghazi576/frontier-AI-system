# Generates n8n/whatsapp-fronter.json. Edit this file, then run:
#   python3 scripts/build_n8n_workflow.py n8n/whatsapp-fronter.json
# (You can also just edit the workflow in n8n and export it over that file.)
import json, uuid, sys

OUT = sys.argv[1]
EVO = "http://evolution_api:8080"
PG = {"postgres": {"id": "fronterPostgres", "name": "Supabase Postgres"}}
EVO_CRED = {"httpHeaderAuth": {"id": "fronterEvolution", "name": "Evolution API key"}}
GROQ_CRED = {"httpHeaderAuth": {"id": "fronterGroq", "name": "Groq API key"}}
GEMINI_CRED = {"googlePalmApi": {"id": "fronterGemini", "name": "Gemini API key"}}

nodes = []
def node(name, type_, ver, pos, params, **extra):
    n = {"id": str(uuid.uuid5(uuid.NAMESPACE_DNS, "fronter-" + name)), "name": name, "type": type_,
         "typeVersion": ver, "position": pos, "parameters": params}
    n.update(extra)
    nodes.append(n)
    return n

PARSE_JS = r"""// Turns the Evolution API webhook into simple fields.
const body = $input.first().json.body || {};
const data = body.data || {};
const key = data.key || {};
const msg = data.message || {};

let jid = key.remoteJid || '';
// Some WhatsApp accounts now show a privacy id (@lid). Use the phone-number id when Evolution gives it.
if (jid.endsWith('@lid')) jid = key.remoteJidAlt || key.senderPn || jid;

const type = data.messageType
  || Object.keys(msg).find(k => !['messageContextInfo', 'base64'].includes(k))
  || 'unknown';
const text = msg.conversation
  || msg.extendedTextMessage?.text
  || msg.imageMessage?.caption
  || msg.videoMessage?.caption
  || msg.documentMessage?.caption
  || '';

// Only 1-to-1 chats from customers: no own messages, groups, status updates, channels or broadcasts.
const isDirect = Boolean(body.instance) && !key.fromMe
  && (jid.endsWith('@s.whatsapp.net') || jid.endsWith('@lid'));

return [{
  json: {
    instance: body.instance || '',
    jid,
    phone: jid.endsWith('@s.whatsapp.net') ? jid.split('@')[0] : '',
    name: data.pushName || '',
    type,
    text,
    isAudio: type === 'audioMessage' || type === 'pttMessage',
    audioBase64: msg.base64 || '',
    isDirect,
  },
}];"""

AUDIO_JS = r"""// Voice note (base64 from Evolution) -> file for Groq Whisper.
const p = $('Parse Message').first().json;
return [{
  json: {},
  binary: { file: { data: p.audioBase64, mimeType: 'audio/ogg', fileName: 'voice.ogg' } },
}];"""

USERTEXT_JS = r"""// The customer's words: typed text, transcribed voice note, or a note about other media.
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
return [{ json: { user_text, media } }];"""

P = "$('Persona').first().json"
X0, Y0 = 0, 300

node("WhatsApp Inbound", "n8n-nodes-base.webhook", 2.1, [X0, Y0],
     {"httpMethod": "POST", "path": "whatsapp-inbound", "responseMode": "onReceived", "options": {}},
     webhookId="5b0c7b1e-7d0e-4c55-9a43-f0d1e2a3b4c5")
node("Parse Message", "n8n-nodes-base.code", 2, [X0 + 220, Y0], {"jsCode": PARSE_JS})
node("Customer Message?", "n8n-nodes-base.if", 2.2, [X0 + 440, Y0], {
    "conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "loose", "version": 2},
                   "conditions": [{"id": "c1", "leftValue": "={{ $json.isDirect }}", "rightValue": True,
                                   "operator": {"type": "boolean", "operation": "true", "singleValue": True}}],
                   "combinator": "and"}, "options": {}})
node("Persona", "n8n-nodes-base.postgres", 2.6, [X0 + 660, Y0], {
    "operation": "executeQuery",
    "query": "select * from fronter_inbound($1, $2, $3, $4);",
    "options": {"queryReplacement": "={{ [ $json.instance, $json.jid, $json.name, $json.phone ] }}"}},
     credentials=PG)
node("Voice Note?", "n8n-nodes-base.if", 2.2, [X0 + 880, Y0], {
    "conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "loose", "version": 2},
                   "conditions": [{"id": "c2", "leftValue": "={{ $('Parse Message').first().json.isAudio }}",
                                   "rightValue": True,
                                   "operator": {"type": "boolean", "operation": "true", "singleValue": True}}],
                   "combinator": "and"}, "options": {}})
node("Audio File", "n8n-nodes-base.code", 2, [X0 + 1100, Y0 - 160], {"jsCode": AUDIO_JS})
node("Groq Whisper", "n8n-nodes-base.httpRequest", 4.2, [X0 + 1320, Y0 - 160], {
    "method": "POST", "url": "https://api.groq.com/openai/v1/audio/transcriptions",
    "authentication": "genericCredentialType", "genericAuthType": "httpHeaderAuth",
    "sendBody": True, "contentType": "multipart-form-data",
    "bodyParameters": {"parameters": [
        {"parameterType": "formBinaryData", "name": "file", "inputDataFieldName": "file"},
        {"name": "model", "value": "whisper-large-v3"},
        {"name": "language", "value": "={{ $('Persona').first().json.stt_language || 'ur' }}"}]},
    "options": {}}, credentials=GROQ_CRED, onError="continueRegularOutput")
node("User Text", "n8n-nodes-base.code", 2, [X0 + 1540, Y0], {"jsCode": USERTEXT_JS})
node("Log Customer Message", "n8n-nodes-base.postgres", 2.6, [X0 + 1760, Y0], {
    "operation": "executeQuery",
    "query": "select fronter_log($1::uuid, 'user', $2, $3);",
    "options": {"queryReplacement": "={{ [ " + P + ".conversation_id, $json.user_text, $json.media ] }}"}},
     credentials=PG, onError="continueRegularOutput", alwaysOutputData=True)
node("AI Mode?", "n8n-nodes-base.if", 2.2, [X0 + 1980, Y0], {
    "conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "strict", "version": 2},
                   "conditions": [{"id": "c3", "leftValue": "={{ " + P + ".conv_status }}", "rightValue": "ai",
                                   "operator": {"type": "string", "operation": "equals"}}],
                   "combinator": "and"}, "options": {}})
node("AI Agent", "@n8n/n8n-nodes-langchain.agent", 2.2, [X0 + 2220, Y0], {
    "promptType": "define",
    "text": "={{ $('User Text').first().json.user_text }}",
    "options": {"systemMessage": "={{ " + P + ".system_prompt }}", "maxIterations": 8}})
node("Gemini", "@n8n/n8n-nodes-langchain.lmChatGoogleGemini", 1, [X0 + 2000, Y0 + 260], {
    "modelName": "models/gemini-flash-latest", "options": {"temperature": 0.4, "maxOutputTokens": 1024}},
     credentials=GEMINI_CRED)
node("Memory", "@n8n/n8n-nodes-langchain.memoryPostgresChat", 1.3, [X0 + 2140, Y0 + 260], {
    "sessionIdType": "customKey", "sessionKey": "={{ " + P + ".conversation_id }}",
    "tableName": "n8n_chat_histories", "contextWindowLength": 10}, credentials=PG)

CONV = P + ".conversation_id"
def tool(name, desc, query, params, x):
    node(name, "n8n-nodes-base.postgresTool", 2.6, [X0 + x, Y0 + 260], {
        "descriptionType": "manual", "toolDescription": desc,
        "operation": "executeQuery", "query": query,
        # One array expression, so an empty answer (e.g. no notes) still fills its $n slot.
        "options": {"queryReplacement": "={{ [ " + ", ".join(params) + " ] }}"}}, credentials=PG)

def ai(key, desc):
    assert not any(q in desc for q in "'\"`"), desc  # n8n's $fromAI parser breaks on quotes
    return "$fromAI('" + key + "', '" + desc + "', 'string')"

tool("check_availability",
     "Get the free appointment times. Use before offering or booking any time.",
     "select check_availability($1::uuid, $2) as result;",
     [CONV, ai("date", "Day to check as YYYY-MM-DD, in the business time zone. Empty string for the next free days.")], 2280)
tool("book_appointment",
     "Book an appointment for this customer in a free slot returned by check_availability.",
     "select book_appointment($1::uuid, $2, $3, $4, $5) as result;",
     [CONV, ai("slot", "Exact slot as YYYY-MM-DD HH:MM, taken from check_availability"),
      ai("customer_name", "Name of the customer"),
      ai("service", "What the appointment is for, e.g. site visit for Phase 8 plots"),
      ai("notes", "Useful details for the team (budget, preferences). Empty string if none")], 2420)
tool("my_appointments",
     "List this customer's upcoming bookings.",
     "select my_appointments($1::uuid) as result;", [CONV], 2560)
tool("cancel_appointment",
     "Cancel this customer's next upcoming booking. Only after the customer clearly asks to cancel or move it.",
     "select cancel_appointment($1::uuid, $2) as result;",
     [CONV, ai("reason", "Reason for cancelling, or empty string")], 2700)
tool("save_lead",
     "Save what you learned about the customer (needs, budget, timeline) for the sales team.",
     "select save_lead($1::uuid, $2, $3, $4) as result;",
     [CONV, ai("summary", "One or two sentence summary of the customer and what they want"),
      ai("details", "Answers to the qualification questions, e.g. budget 1.5 Cr; cash; wants 10 marla in Phase 8"),
      ai("status", "qualified if they are a real prospect, lost if not interested, otherwise new")], 2840)

SEND_URL = "=" + EVO + "/message/sendText/{{ $('Parse Message').first().json.instance }}"
node("Send Reply", "n8n-nodes-base.httpRequest", 4.2, [X0 + 2580, Y0], {
    "method": "POST", "url": SEND_URL,
    "authentication": "genericCredentialType", "genericAuthType": "httpHeaderAuth",
    "sendBody": True, "specifyBody": "keypair",
    "bodyParameters": {"parameters": [
        {"name": "number", "value": "={{ $('Parse Message').first().json.jid }}"},
        {"name": "text", "value": "={{ $('AI Agent').first().json.output }}"}]},
    "options": {}}, credentials=EVO_CRED, retryOnFail=True, maxTries=3, waitBetweenTries=2000)
node("Log Reply", "n8n-nodes-base.postgres", 2.6, [X0 + 2800, Y0], {
    "operation": "executeQuery",
    "query": "select fronter_log($1::uuid, 'assistant', $2, 'text');",
    "options": {"queryReplacement": "={{ [ " + P + ".conversation_id, $('AI Agent').first().json.output ] }}"}},
     credentials=PG, onError="continueRegularOutput", alwaysOutputData=True)
node("Owner Notices", "n8n-nodes-base.postgres", 2.6, [X0 + 3020, Y0], {
    "operation": "executeQuery",
    "query": "select * from take_owner_notifications($1::uuid);",
    "options": {"queryReplacement": "={{ [ " + P + ".tenant_id ] }}"}}, credentials=PG, onError="continueRegularOutput")
node("Notify Owner", "n8n-nodes-base.httpRequest", 4.2, [X0 + 3240, Y0], {
    "method": "POST", "url": SEND_URL,
    "authentication": "genericCredentialType", "genericAuthType": "httpHeaderAuth",
    "sendBody": True, "specifyBody": "keypair",
    "bodyParameters": {"parameters": [
        {"name": "number", "value": "={{ $json.owner_number }}"},
        {"name": "text", "value": "={{ $json.body }}"}]},
    "options": {}}, credentials=EVO_CRED, onError="continueRegularOutput")

nodes.append({"id": str(uuid.uuid4()), "name": "Note", "type": "n8n-nodes-base.stickyNote", "typeVersion": 1,
              "position": [X0, Y0 - 420], "parameters": {"width": 640, "height": 260, "content":
              "## AI Fronter: WhatsApp front desk\n"
              "One workflow serves every business. The Evolution instance name in the webhook tells the database "
              "which business the message is for (channels.evolution_instance).\n\n"
              "Credentials to set: **Supabase Postgres** (session pooler, SSL on), **Gemini API key**, "
              "**Groq API key** (Header Auth: Authorization = Bearer ...), **Evolution API key** (Header Auth: apikey = ...).\n\n"
              "Human takeover: set conversations.status = 'human' and the bot goes quiet for that chat "
              "(messages are still logged)."}})

def m(a, b, idx=0):
    return (a, b, idx)
main = {}
def link(a, b, out=0):
    main.setdefault(a, {"main": []})
    while len(main[a]["main"]) <= out:
        main[a]["main"].append([])
    main[a]["main"][out].append({"node": b, "type": "main", "index": 0})

link("WhatsApp Inbound", "Parse Message")
link("Parse Message", "Customer Message?")
link("Customer Message?", "Persona", 0)
link("Persona", "Voice Note?")
link("Voice Note?", "Audio File", 0)
link("Voice Note?", "User Text", 1)
link("Audio File", "Groq Whisper")
link("Groq Whisper", "User Text")
link("User Text", "Log Customer Message")
link("Log Customer Message", "AI Mode?")
link("AI Mode?", "AI Agent", 0)
link("AI Agent", "Send Reply")
link("Send Reply", "Log Reply")
link("Log Reply", "Owner Notices")
link("Owner Notices", "Notify Owner")
main["Gemini"] = {"ai_languageModel": [[{"node": "AI Agent", "type": "ai_languageModel", "index": 0}]]}
main["Memory"] = {"ai_memory": [[{"node": "AI Agent", "type": "ai_memory", "index": 0}]]}
for t in ["check_availability", "book_appointment", "my_appointments", "cancel_appointment", "save_lead"]:
    main[t] = {"ai_tool": [[{"node": "AI Agent", "type": "ai_tool", "index": 0}]]}

wf = {"name": "AI Fronter - WhatsApp", "nodes": nodes, "connections": main, "active": False,
      "settings": {"executionOrder": "v1", "timezone": "UTC"}, "pinData": {},
      "id": "aiFronterWhatsApp", "versionId": str(uuid.uuid5(uuid.NAMESPACE_DNS, "fronter-v1"))}
json.dump(wf, open(OUT, "w"), indent=2, ensure_ascii=False)
print("wrote", OUT, len(nodes), "nodes")
