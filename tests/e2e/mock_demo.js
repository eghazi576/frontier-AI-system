// Plays sample customer conversations through the mock test chat and prints the transcript.
// Needs the mock setup running (docker compose -f docker-compose.mock.yml up, or the services started by hand).
// Usage: node tests/e2e/mock_demo.js [http://localhost:8080]
const BASE = process.argv[2] || 'http://localhost:8080';
const sleep = ms => new Promise(r => setTimeout(r, ms));
const get = (instance, phone) => fetch(`${BASE}/api/messages?instance=${instance}&phone=${phone}`).then(r => r.json());

async function say(instance, phone, name, text, voice = false) {
  const before = (await get(instance, phone)).chat.filter(m => m.from === 'bot').length;
  const r = await fetch(`${BASE}/api/send`, { method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ instance, phone, name, text, voice }) }).then(r => r.json());
  if (!r.ok) throw new Error('n8n did not accept the message: ' + r.n8n);
  console.log(`  ${name}: ${voice ? '[voice note]' : text}`);
  for (let i = 0; i < 60; i++) {
    await sleep(500);
    const bots = (await get(instance, phone)).chat.filter(m => m.from === 'bot');
    if (bots.length > before) { console.log(`  BOT: ${bots[bots.length - 1].text.replace(/\n/g, '\n       ')}`); return bots[bots.length - 1].text; }
  }
  console.log('  BOT: (no reply)'); return null;
}

(async () => {
  const scripts = [
    ['fronter_realestate', '923331234567', 'Ali', ['Assalam o Alaikum', 'Phase 8 mein 10 marla plot ka rate kya hai?',
      'Mera budget 1.5 Cr hai, cash', 'Kal site visit book karni hai', '11 baje, mera naam Ali Khan hai']],
    ['fronter_istanbul', '905551234567', 'Sam', ['Hello', 'What do you have in Levent?', 'I want to book a viewing on Saturday', '11:00 please, my name is Sam Taylor']],
    ['fronter_clinic', '923339876543', 'Zara', ['__voice__', '12:30, mera naam Zara hai', 'Meri booking cancel kar dein']],
  ];
  for (const [inst, phone, name, lines] of scripts) {
    console.log(`\n== ${inst} (${phone})`);
    for (const l of lines) await say(inst, phone, name, l === '__voice__' ? '' : l, l === '__voice__');
    const alerts = (await get(inst, phone)).alerts;
    if (alerts.length) console.log('  OWNER ALERTS:\n    ' + alerts.map(a => a.text.replace(/\n/g, '\n    ')).join('\n    ---\n    '));
  }
})().catch(e => { console.error(e); process.exit(1); });
