// Fake Evolution API (8080) and fake Gemini (9090) for an end-to-end run of the n8n workflow.
const http = require('http'); const fs = require('fs');
const log = (f, o) => fs.appendFileSync(f, JSON.stringify(o) + '\n');
const read = req => new Promise(r => { let b=''; req.on('data', c => b += c); req.on('end', () => r(b)); });

http.createServer(async (req, res) => {
  const body = await read(req);
  if (req.url.startsWith('/groq')) {
    log('groq.log', { auth: req.headers.authorization, ctype: req.headers['content-type'], len: body.length, hasLang: /name="language"\r\n\r\nur/.test(body), hasFile: /filename="voice.ogg"/.test(body) });
    res.writeHead(200, {'content-type':'application/json'}); return res.end('{"text":"Bhai installments par koi option hai?"}');
  }
  log('evolution.log', { url: req.url, apikey: req.headers.apikey, body: JSON.parse(body || '{}') });
  res.writeHead(201, {'content-type':'application/json'}); res.end('{"key":{"id":"x"},"status":"PENDING"}');
}).listen(8080);

http.createServer(async (req, res) => {
  const raw = await read(req); const b = JSON.parse(raw || '{}');
  log('gemini.log', { url: req.url, key: req.headers['x-goog-api-key'], body: b });
  const contents = b.contents || [];
  const last = contents[contents.length - 1] || {};
  const lastUser = [...contents].reverse().find(c => c.role === 'user' && c.parts?.some(p => p.text));
  const userText = lastUser?.parts.map(p => p.text || '').join('') || '';
  const fr = last.parts?.find(p => p.functionResponse);
  let part;
  if (!fr && /book/i.test(userText)) {
    part = { functionCall: { name: 'check_availability', args: { date: '' } } };
  } else if (fr && fr.functionResponse.name === 'check_availability') {
    const txt = JSON.stringify(fr.functionResponse.response);
    const m = txt.match(/(\d{4}-\d{2}-\d{2}) \(\w+\): (\d{2}:\d{2})/);
    part = { functionCall: { name: 'book_appointment', args: { slot: m ? `${m[1]} ${m[2]}` : 'none', customer_name: 'Ali Test', service: 'Site visit, Phase 8', notes: 'Budget 1.5 Cr, it\'s "cash"' } } };
  } else if (fr) {
    part = { text: 'Done: ' + JSON.stringify(fr.functionResponse.response).slice(0, 300) };
  } else {
    part = { text: 'Ji, Bahria Town Phase 8 mein 10 marla plots 1.45 Cr se 1.80 Cr tak hain. Aap ka budget kya hai?' };
  }
  const resp = { candidates: [{ content: { role: 'model', parts: [part] }, finishReason: 'STOP', index: 0 }],
                 usageMetadata: { promptTokenCount: 1, candidatesTokenCount: 1, totalTokenCount: 2 } };
  if (req.url.includes('streamGenerateContent')) {
    res.writeHead(200, {'content-type':'text/event-stream'}); res.end('data: ' + JSON.stringify(resp) + '\r\n\r\n');
  } else { res.writeHead(200, {'content-type':'application/json'}); res.end(JSON.stringify(resp)); }
}).listen(9090);
console.log('fakes up');
