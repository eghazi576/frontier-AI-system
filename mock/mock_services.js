// AI Fronter mock services: lets the whole system run with NO accounts (no WhatsApp, Gemini or Groq).
//
//  - Mock Evolution API  (WhatsApp gateway): receives the bot's replies at /message/sendText/<instance>
//  - Mock Gemini         (AI brain): a simple rule-based brain at /v1beta/models/<model>:generateContent.
//                        It reads the real system prompt from the database and uses the real booking tools,
//                        so the whole pipeline (n8n, database, booking, owner alerts) is exercised.
//                        Its answers are simple templates, not real AI.
//  - Mock Groq Whisper   (voice notes): /openai/v1/audio/transcriptions returns a fixed sentence.
//  - Test chat page      http://localhost:8080/  - chat with the bot like a WhatsApp customer.
//
// No dependencies. Run: node mock/mock_services.js
// Env: PORT (8080), N8N_WEBHOOK (http://n8n:5678/webhook/whatsapp-inbound)

const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = Number(process.env.PORT || 8080);
const N8N_WEBHOOK = process.env.N8N_WEBHOOK || 'http://n8n:5678/webhook/whatsapp-inbound';
const BUSINESSES = JSON.parse(process.env.MOCK_BUSINESSES || JSON.stringify([
  { instance: 'fronter_realestate', name: 'Bahria Prime Associates (Hamza, Urdu)', owner: '923001111110' },
  { instance: 'fronter_clinic', name: 'Glow & Smile Clinic (Sara, Urdu)', owner: '923002222220' },
  { instance: 'fronter_istanbul', name: 'Bosphorus Homes Istanbul (Deniz, English)', owner: '' },
]));

// ---------- in-memory WhatsApp ----------
const sent = [];      // every message the bot sent: {instance, number, text, at}
const inbox = [];     // every message a customer sent through the test page
let msgId = 1;

const readBody = req => new Promise(resolve => {
  const chunks = []; req.on('data', c => chunks.push(c)); req.on('end', () => resolve(Buffer.concat(chunks)));
});
const json = (res, code, obj) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); };
const digits = s => String(s || '').split('@')[0].replace(/\D/g, '');

// ---------- mock AI brain ----------
const WEEKDAYS = ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday'];
const URDU_DAYS = { itwar: 0, peer: 1, somwar: 1, mangal: 2, budh: 3, jumerat: 4, jumma: 5, juma: 5, hafta: 6, haftay: 6 };

function promptInfo(sys) {
  const who = sys.match(/^You are (.+?), working as (.+?) at (.+?)\.\n/) || [];
  const now = sys.match(/Current date and time at the business: \w+ (\d{1,2}) (\w+) (\d{4}), (\d{2}):(\d{2})/);
  let today = new Date();
  if (now) today = new Date(`${now[2]} ${now[1]}, ${now[3]} 12:00:00 UTC`);
  const knowledge = [...sys.matchAll(/^\[([^\]]+)\] ([^:]+): (.+)$/gm)].map(m => ({ cat: m[1], title: m[2], content: m[3] }));
  const field = name => (sys.match(new RegExp('^' + name + ': (.+)$', 'm')) || [])[1];
  const qline = (sys.match(/QUALIFICATION GOALS[^\n]*\n([^\n]+)/) || [])[1] || '';
  const questions = qline.split(/\s*\d\.\s*/).map(q => q.trim()).filter(Boolean);
  return {
    name: who[1] || 'Assistant', role: who[2] || '', business: who[3] || 'the business',
    urdu: /Default language: [^\n]*Roman Urdu/.test(sys), today, knowledge,
    address: field('Address'), phone: field('Phone'), hours: field('Opening hours'),
    questions,
    canBook: /book_appointment/.test(sys),
    label: (sys.match(/BOOKING \(([^)]+)\)/) || [])[1] || 'appointment',
  };
}

const ymd = d => d.toISOString().slice(0, 10);
const addDays = (d, n) => new Date(d.getTime() + n * 86400000);

function findDate(text, info) {
  const t = text.toLowerCase();
  const iso = t.match(/(\d{4}-\d{2}-\d{2})/);
  if (iso) return iso[1];
  if (/\b(today|aaj)\b/.test(t)) return ymd(info.today);
  if (/\b(day after tomorrow|parson)\b/.test(t)) return ymd(addDays(info.today, 2));
  if (/\b(tomorrow|kal)\b/.test(t)) return ymd(addDays(info.today, 1));
  let dow = WEEKDAYS.findIndex(w => t.includes(w));
  if (dow < 0) for (const [w, n] of Object.entries(URDU_DAYS)) if (new RegExp('\\b' + w + '\\b').test(t)) { dow = n; break; }
  if (dow >= 0) {
    let d = addDays(info.today, 1);
    while (d.getUTCDay() !== dow) d = addDays(d, 1);
    return ymd(d);
  }
  return null;
}

function findTime(text) {
  const t = text.toLowerCase();
  // 11:00, 3:30 pm, 4.30pm (a dot only with am/pm, so prices like 1.45 Cr are not read as times)
  let m = t.match(/\b(\d{1,2}):(\d{2})\s*(am|pm)?/) || t.match(/\b(\d{1,2})\.(\d{2})\s*(am|pm)\b/);
  let h, min = 0, ap;
  if (m) { h = +m[1]; min = +m[2]; ap = m[3]; }
  else {
    m = t.match(/\b(\d{1,2})\s*(am|pm|baje|bajay|o'?clock)\b/);
    if (!m) return null;
    h = +m[1]; ap = m[2];
  }
  if (ap === 'pm' && h < 12) h += 12;
  if ((ap === 'baje' || ap === 'bajay' || !ap) && h >= 1 && h <= 7) h += 12;   // "3 baje" = 15:00 in office hours
  if (h > 23 || min > 59) return null;
  return `${String(h).padStart(2, '0')}:${String(min).padStart(2, '0')}`;
}

function findName(text) {
  const m = text.match(/(?:mera naam|my name is|name is|naam|i am|i'm|main)\s+([A-Z][a-zA-Z]+(?:\s+[A-Z][a-zA-Z]+)?)/i);
  if (!m) return null;
  const n = m[1].replace(/\s+(hai|hoon|hun|here)$/i, '').trim();
  return /^(hai|hoon|ok|yes)$/i.test(n) ? null : n.replace(/\b\w/g, c => c.toUpperCase());
}

function textOf(c) { return (c.parts || []).map(p => p.text || '').join('').trim(); }

function brain(body) {
  const sys = (body.systemInstruction?.parts || []).map(p => p.text).join('\n');
  const info = promptInfo(sys);
  const contents = body.contents || [];
  const last = contents[contents.length - 1] || {};
  const fr = (last.parts || []).find(p => p.functionResponse)?.functionResponse;
  const userTurns = contents.filter(c => c.role === 'user' && textOf(c));
  const userText = userTurns.length ? textOf(userTurns[userTurns.length - 1]) : '';
  const t = userText.toLowerCase();
  const U = info.urdu;
  const call = (name, args) => ({ functionCall: { name, args } });
  const say = text => ({ text });

  // ----- after a tool answered -----
  if (fr) {
    let r = JSON.stringify(fr.response);
    // n8n hands the tool result over as a JSON string like '[{"result":"BOOKED: ..."}]'
    try { const v = JSON.parse(fr.response.result); r = Array.isArray(v) ? v[0].result : (v.result || String(v)); }
    catch { r = String(fr.response.result || r); }
    if (fr.name === 'check_availability') {
      const day = r.match(/Free times on \w+ (\d{4}-\d{2}-\d{2})[^:]*: ([\d:, ]+)/);
      const multi = [...r.matchAll(/(\d{4}-\d{2}-\d{2}) \((\w+)\): ([\d:, ]+)/g)];
      if (day) {
        const times = day[2].split(', ').slice(0, 3).join(', ');
        return say(U ? `${day[1]} ko yeh time free hain: ${times}. Kaunsa time aap ke liye theek hai? Apna naam bhi bata dein.`
                     : `On ${day[1]} these times are free: ${times}. Which one suits you? And may I have your name?`);
      }
      if (multi.length) {
        const m = multi[0]; const times = m[3].split(', ').slice(0, 3).join(', ');
        return say(U ? `Sab se pehle free din ${m[1]} (${m[2]}) hai: ${times}. Kaunsa time theek rahega? Apna naam bhi bata dein.`
                     : `The first free day is ${m[1]} (${m[2]}): ${times}. Which time works for you? And your name, please?`);
      }
      const next = r.match(/Next free slots: ([^.]+)/);
      return say(U ? `Us din koi time free nahi.${next ? ' Agle free time: ' + next[1] + '.' : ''} Kaunsa chalega?`
                   : `Nothing is free that day.${next ? ' Next free times: ' + next[1] + '.' : ''} Would one of those work?`);
    }
    if (fr.name === 'book_appointment') {
      if (r.startsWith('BOOKED')) {
        const m = r.match(/on (.+?) \(([^)]+)\)(?: at (.+?))?\. Reference (\w+)/);
        return say(U ? `Done! Aap ki ${info.label} ${m ? m[1] : ''} ko book ho gayi hai${m && m[3] ? ', address: ' + m[3] : ''}. Reference: ${m ? m[4] : ''}. Hum aap ka intezar karenge.`
                     : `Done! Your ${info.label} is booked for ${m ? m[1] : ''}${m && m[3] ? ' at ' + m[3] : ''}. Reference: ${m ? m[4] : ''}. See you then!`);
      }
      return say(U ? `Maaf kijiye, yeh time book nahi ho saka. ${r.replace(/^NOT BOOKED: /, '')}` : `Sorry, I could not book that. ${r.replace(/^NOT BOOKED: /, '')}`);
    }
    if (fr.name === 'cancel_appointment') {
      return say(r.startsWith('CANCELLED')
        ? (U ? `Aap ki booking (${r.replace('CANCELLED: ', '').replace(/\.$/, '')}) cancel kar di gayi hai. Naya time chahiye to bata dein.` : `Your booking (${r.replace('CANCELLED: ', '').replace(/\.$/, '')}) is cancelled. Tell me if you want a new time.`)
        : (U ? 'Aap ki koi upcoming booking nahi mili.' : 'I could not find an upcoming booking for you.'));
    }
    if (fr.name === 'my_appointments') return say(r.startsWith('Upcoming') ? r : (U ? 'Aap ki koi upcoming booking nahi hai.' : 'You have no upcoming bookings.'));
    if (fr.name === 'save_lead') return say(U ? `Shukriya, note kar liya. Kya aap site visit ya appointment book karna chahenge?`
                                              : 'Thank you, noted. Would you like to book a visit?');
  }

  // ----- new customer message -----
  const lastModel = [...contents].reverse().find(c => c.role === 'model' && textOf(c));
  const offeredDate = lastModel ? (textOf(lastModel).match(/(\d{4}-\d{2}-\d{2})/) || [])[1] : null;
  const date = findDate(userText, info);
  const time = findTime(userText);
  const wantsBooking = /\b(book|booking|appointment|visit|slot|meeting|viewing|milna|aana|time)\b/.test(t);

  if (/\b(cancel|cancle|radd|khatam)\b/.test(t) && info.canBook) return call('cancel_appointment', { reason: userText.slice(0, 120) });
  if (/\b(my booking|meri booking|my appointment|mera appointment)\b/.test(t) && info.canBook) return call('my_appointments', {});
  if (time && (date || offeredDate) && info.canBook) {
    return call('book_appointment', {
      slot: `${date || offeredDate} ${time}`, customer_name: findName(userText) || 'Customer',
      service: info.label, notes: '' });
  }
  if (wantsBooking && info.canBook) return call('check_availability', { date: date || '' });
  if (/\b(budget|cr|crore|lakh|lac|cash|installment|qist)\b/.test(t) && /\d/.test(t)) {
    return call('save_lead', { summary: userText.slice(0, 200), details: userText.slice(0, 200), status: 'qualified' });
  }

  // knowledge search: score each item by shared words
  const words = t.split(/[^a-z0-9]+/).filter(w => w.length > 2 && !['kya', 'hai', 'the', 'and', 'for', 'ka', 'ki', 'mein', 'what', 'how'].includes(w));
  const scored = info.knowledge.map(k => {
    const hay = (k.cat + ' ' + k.title + ' ' + k.content).toLowerCase();
    return { k, s: words.filter(w => hay.includes(w)).length };
  }).filter(x => x.s > 0).sort((a, b) => b.s - a.s);

  if (/\b(address|location|kahan|where|office)\b/.test(t) && info.address) {
    return say(U ? `Hamara address hai: ${info.address}. Timing: ${info.hours}.` : `We are at ${info.address}. Opening hours: ${info.hours}.`);
  }
  if (/\b(timing|time|hours|open|khula|band)\b/.test(t) && info.hours) {
    return say(U ? `Hamari timing: ${info.hours}.` : `Our opening hours: ${info.hours}.`);
  }
  if (scored.length) {
    const top = scored.slice(0, 2).map(x => `${x.k.title}: ${x.k.content}`).join('\n');
    // They already named what they want, so ask the next qualification question (e.g. budget).
    const q = info.questions[1] || info.questions[0];
    return say(U ? `Ji zaroor! ${top}\n${q || 'Aur kya jaanna chahenge?'}` : `Sure! ${top}\n${q || 'What else would you like to know?'}`);
  }
  if (/\b(salam|assalam|aoa|hi|hello|hey|merhaba|selam)\b/.test(t) || userTurns.length <= 1) {
    return say(U ? `Wa Alaikum Assalam! Main ${info.name} hoon, ${info.business} se. Bataiye, main aap ki kya madad karoon?`
                 : `Hello! I am ${info.name} from ${info.business}. How can I help you today?`);
  }
  if (/\b(human|bot|ai|robot|insaan)\b/.test(t)) {
    return say(U ? `Main ${info.name} hoon, ${info.business} ka AI assistant.` : `I am ${info.name}, the AI assistant of ${info.business}.`);
  }
  return say(U ? `Is baare mein hamari team confirm karegi. Aap ko call karne ka behtareen time kya hai?`
               : `A team member will confirm that for you. What is a good time to call you?`);
}

// ---------- server ----------
http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const p = url.pathname;
  try {
    // Mock Evolution API: the bot sends a WhatsApp message
    let m = p.match(/^\/message\/sendText\/([^/]+)$/);
    if (m && req.method === 'POST') {
      const b = JSON.parse((await readBody(req)).toString() || '{}');
      sent.push({ id: msgId++, instance: decodeURIComponent(m[1]), number: digits(b.number), text: b.text, at: new Date().toISOString() });
      return json(res, 201, { key: { id: 'MOCK' + msgId, fromMe: true }, status: 'PENDING' });
    }
    if (p === '/instance/create' && req.method === 'POST') return json(res, 201, { instance: { status: 'mock' } });

    // Mock Gemini
    if (/^\/v1beta\/models\/[^/]+:(generateContent|streamGenerateContent)$/.test(p)) {
      const b = JSON.parse((await readBody(req)).toString() || '{}');
      const part = brain(b);
      const out = { candidates: [{ content: { role: 'model', parts: [part] }, finishReason: 'STOP', index: 0 }],
                    usageMetadata: { promptTokenCount: 0, candidatesTokenCount: 0, totalTokenCount: 0 } };
      if (p.includes('stream')) { res.writeHead(200, { 'content-type': 'text/event-stream' }); return res.end('data: ' + JSON.stringify(out) + '\r\n\r\n'); }
      return json(res, 200, out);
    }

    // Mock Groq Whisper
    if (p === '/openai/v1/audio/transcriptions') {
      await readBody(req);
      return json(res, 200, { text: process.env.MOCK_TRANSCRIPT || 'Kal appointment book karni hai' });
    }

    // Test chat page API
    if (p === '/api/businesses') return json(res, 200, BUSINESSES);
    if (p === '/api/send' && req.method === 'POST') {
      const b = JSON.parse((await readBody(req)).toString() || '{}');
      const phone = digits(b.phone) || '923330000000';
      inbox.push({ id: msgId++, instance: b.instance, number: phone, text: b.text, at: new Date().toISOString() });
      const payload = {
        event: 'messages.upsert', instance: b.instance,
        data: {
          key: { remoteJid: `${phone}@s.whatsapp.net`, fromMe: false, id: 'MOCKIN' + msgId },
          pushName: b.name || 'Test Customer',
          message: b.voice ? { audioMessage: { ptt: true }, base64: Buffer.from('mock-voice').toString('base64') } : { conversation: b.text },
          messageType: b.voice ? 'audioMessage' : 'conversation',
          messageTimestamp: Math.floor(Date.now() / 1000),
        },
      };
      const r = await fetch(N8N_WEBHOOK, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(payload) })
        .then(x => x.status).catch(e => 'n8n unreachable: ' + e.message);
      return json(res, 200, { ok: r === 200, n8n: r });
    }
    if (p === '/api/messages') {
      const inst = url.searchParams.get('instance'); const phone = digits(url.searchParams.get('phone'));
      const owner = (BUSINESSES.find(b => b.instance === inst) || {}).owner;
      const chat = [...inbox.filter(x => x.instance === inst && x.number === phone).map(x => ({ ...x, from: 'customer' })),
                    ...sent.filter(x => x.instance === inst && x.number === phone).map(x => ({ ...x, from: 'bot' }))]
        .sort((a, b) => a.id - b.id);
      const alerts = owner ? sent.filter(x => x.instance === inst && x.number === owner) : [];
      return json(res, 200, { chat, alerts });
    }
    if (p === '/api/sent') return json(res, 200, sent);
    if (p === '/' || p === '/index.html') {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      return res.end(fs.readFileSync(path.join(__dirname, 'chat.html')));
    }
    json(res, 404, { error: 'not found', path: p });
  } catch (e) {
    console.error(e);
    json(res, 500, { error: String(e) });
  }
}).listen(PORT, '0.0.0.0', () => console.log(`AI Fronter mocks on :${PORT}  (test chat: http://localhost:${PORT}/)`));

module.exports = { brain, findTime, findDate, findName };
