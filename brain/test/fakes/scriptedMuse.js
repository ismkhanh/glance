// A scripted stand-in for Muse. It reads the same prompt the real model gets and answers with the
// Responses API shapes Glance already uses with the real API (function_call items, output_text).
import http from 'node:http';
import { REVIEW_INSTRUCTIONS, lastColorWord } from '../../src/review.js';

const HEX = { red: '#FF3B30', blue: '#0A84FF', green: '#34C759', purple: '#AF52DE', orange: '#FF9500', black: '#000000' };

let callCounter = 0;

export function callResponse(...calls) {
  return {
    status: 'completed',
    output: calls.map(([name, args]) => ({ type: 'function_call', call_id: `call_${++callCounter}`, name, arguments: JSON.stringify(args) })),
  };
}

export function textResponse(text) {
  return { status: 'completed', output: [{ type: 'message', content: [{ type: 'output_text', text }] }], output_text: text };
}

/** Pulls the parts back out of the worker prompt (see buildPrompt in src/worker.js). */
export function parsePrompt(text) {
  const lines = text.split('\n');
  const out = { request: '', updates: [], answers: [], feedback: null, target: null, history: [] };
  let section = null;
  for (const line of lines) {
    let m;
    if ((m = line.match(/^Request: "(.*)"$/))) out.request = m[1];
    else if (line.startsWith('Updates from the user')) section = 'updates';
    else if (line.startsWith('Answers the user gave')) section = 'answers';
    else if (line.startsWith('Tools already used')) section = 'history';
    else if ((m = line.match(/^Reviewer feedback from the last try: (.*)$/))) out.feedback = m[1];
    else if ((m = line.match(/^Target layer: (\{.*\})$/))) out.target = JSON.parse(m[1]);
    else if (line.startsWith('- ') && section === 'updates') out.updates.push(line.slice(3, -1));
    else if (line.startsWith('- ') && section === 'answers') out.answers.push(line.split('→ ').pop().replace(/^"|"$/g, ''));
    else if (line.startsWith('- ') && section === 'history') out.history.push(line.slice(2));
  }
  return out;
}

/**
 * How the fake "thinks". Options:
 *  wrongColorFirst: the first try uses the wrong color, so the reviewer must catch it.
 *  alwaysWrong: never gets the color right.
 *  reviewPass: what Muse's review says (default true).
 *  decide(prompt): custom answer for one test.
 */
export function scripted(body, opts = {}) {
  if (body.instructions === REVIEW_INSTRUCTIONS) {
    const pass = typeof opts.reviewPass === 'function' ? opts.reviewPass(body) : opts.reviewPass ?? true;
    return textResponse(JSON.stringify({ pass, reason: pass ? 'matches the request' : 'not what was asked' }));
  }
  const text = body.input?.[0]?.content?.[0]?.text ?? '';
  const p = parsePrompt(text);
  if (opts.decide) {
    const custom = opts.decide(p, body);
    if (custom) return custom;
  }
  const target = p.target;
  const said = [p.request, ...p.updates].join(' ').toLowerCase();
  const all = [said, ...p.answers].join(' ').toLowerCase();
  const worked = (prefix, value) => p.history.some((h) => h.startsWith(prefix) && h.includes(value) && !h.includes('Could not'));

  const color = lastColorWord(said);
  if (color && target) {
    const wrong = opts.alwaysWrong || (opts.wrongColorFirst && !p.feedback);
    const want = wrong ? (color === 'blue' ? HEX.orange : HEX.blue) : HEX[color] ?? HEX.red;
    if (!worked('set_fill(', want)) return callResponse(['set_fill', { node_id: target.id, color: want }]);
  }
  if (/scroll/.test(said) && target) {
    const dir = /horizontal|sideways/.test(all) ? 'HORIZONTAL' : /vertical/.test(all) ? 'VERTICAL' : null;
    if (!dir) {
      const rec = target.hints?.recommendedScroll === 'HORIZONTAL' ? 'Horizontal' : 'Vertical';
      return callResponse(['ask_user', {
        question: 'Which way should it scroll?', options: ['Horizontal', 'Vertical'], recommended: rec,
        reason: target.hints?.recommendedScrollWhy ?? '',
      }]);
    }
    if (!worked('set_scroll(', dir)) return callResponse(['set_scroll', { node_id: target.id, direction: dir }]);
  }
  if (/\b(photo|picture|image)\b/.test(said) && target && !worked('set_image(', '"prompt"')) {
    return callResponse(['set_image', { node_id: target.id, prompt: 'A sunny Lisbon street with a yellow tram, travel photo' }]);
  }
  if (/round/.test(said) && target && !worked('set_corner_radius(', '"radius"')) {
    return callResponse(['set_corner_radius', { node_id: target.id, radius: 24 }]);
  }
  return callResponse(['finish', { summary: 'Done.' }]);
}

function abortable(ms, signal) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return reject(Object.assign(new Error('Stopped.'), { name: 'AbortError' }));
    const t = setTimeout(resolve, ms);
    signal?.addEventListener('abort', () => {
      clearTimeout(t);
      reject(Object.assign(new Error('Stopped.'), { name: 'AbortError' }));
    }, { once: true });
  });
}

/** In-process fake with the MuseClient interface (respond / available). */
export class FakeMuse {
  constructor(opts = {}) {
    this.opts = opts;
    this.available = true;
    this.bodies = [];
    this.delayMs = opts.delayMs ?? 5;
  }

  async respond(body, { signal } = {}) {
    this.bodies.push(body);
    const delay = typeof this.delayMs === 'function' ? this.delayMs(body) : this.delayMs;
    await abortable(delay, signal);
    return scripted(body, this.opts);
  }

  async image(prompt, { signal } = {}) {
    this.imagePrompts = [...(this.imagePrompts || []), prompt];
    await abortable(this.delayMs, signal);
    return Buffer.from('fake jpeg bytes').toString('base64');
  }

  workerPrompts() {
    return this.bodies.filter((b) => b.instructions !== REVIEW_INSTRUCTIONS).map((b) => b.input[0].content[0].text);
  }

  reviews() {
    return this.bodies.filter((b) => b.instructions === REVIEW_INSTRUCTIONS).length;
  }
}

/** The same script behind a real HTTP server, for the end-to-end test (exercises the real MuseClient). */
export async function startMuseServer(opts = {}) {
  const requests = [];
  let failNext = opts.failFirst ? 1 : 0;
  const server = http.createServer((req, res) => {
    let raw = '';
    req.on('data', (c) => { raw += c; });
    req.on('end', async () => {
      const auth = req.headers.authorization;
      requests.push({ path: req.url, auth, body: JSON.parse(raw || '{}') });
      if (req.url !== '/v1/responses' || auth !== `Bearer ${opts.key ?? 'test-key'}`) {
        res.writeHead(401, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'bad key or path' }));
        return;
      }
      if (failNext > 0) {
        failNext -= 1;
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: { type: 'server_error' } }));
        return;
      }
      await new Promise((r) => setTimeout(r, opts.delayMs ?? 10));
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(scripted(JSON.parse(raw), opts)));
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return {
    url: `http://127.0.0.1:${server.address().port}/v1`,
    requests,
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}

export async function waitFor(check, { timeout = 4000, every = 10, what = 'condition' } = {}) {
  const start = Date.now();
  for (;;) {
    const value = await check();
    if (value) return value;
    if (Date.now() - start > timeout) throw new Error(`Timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, every));
  }
}
