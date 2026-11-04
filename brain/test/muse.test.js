import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { ENV_FILE, MuseClient, museKey } from '../src/muse.js';
import { startMuseServer } from './fakes/scriptedMuse.js';

test('reads the key from the Glance folder\'s .env like the Swift app; the environment wins', () => {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'glance-'));
  const file = path.join(dir, '.env');
  writeFileSync(file, 'OTHER=1\nexport MUSE_API_KEY="abc123"\n');
  assert.equal(museKey({}, file), 'abc123');
  assert.equal(museKey({ MUSE_API_KEY: 'env' }, file), 'env');
  assert.equal(museKey({}, path.join(dir, 'missing.env')), null);
  assert.equal(ENV_FILE, fileURLToPath(new URL('../../.env', import.meta.url)));  // src/ and test/ sit at the same depth
});

test('retries once after a server error, then succeeds', async () => {
  const server = await startMuseServer({ failFirst: true });
  try {
    const muse = new MuseClient({ key: 'test-key', baseUrl: server.url });
    const body = { model: 'muse-spark-1.3', input: [{ role: 'user', content: [{ type: 'input_text', text: 'Request: "turn it red"' }] }] };
    const response = await muse.respond(body);
    assert.equal(server.requests.length, 2);
    assert.equal(server.requests[1].auth, 'Bearer test-key');
    assert.ok(Array.isArray(response.output));
  } finally {
    await server.close();
  }
});

test('a wrong key is not retried and the error says why', async () => {
  const server = await startMuseServer();
  try {
    const muse = new MuseClient({ key: 'wrong', baseUrl: server.url });
    await assert.rejects(muse.respond({}), /HTTP 401/);
    assert.equal(server.requests.length, 1);
  } finally {
    await server.close();
  }
});

test('stopping a task aborts its Muse call', async () => {
  const server = await startMuseServer({ delayMs: 2000 });
  try {
    const muse = new MuseClient({ key: 'test-key', baseUrl: server.url });
    const controller = new AbortController();
    setTimeout(() => controller.abort(), 50);
    await assert.rejects(muse.respond({ input: [] }, { signal: controller.signal }), { name: 'AbortError' });
  } finally {
    await server.close();
  }
});

test('reads function calls and text the same way as the Swift client', () => {
  const r = {
    output: [
      { type: 'message', content: [{ type: 'output_text', text: 'Making it red.' }] },
      { type: 'function_call', call_id: 'c1', name: 'set_fill', arguments: '{"node_id":"1:2","color":"#FF3B30"}' },
      { type: 'function_call', call_id: 'c2', name: 'bad', arguments: '{not json' },
    ],
  };
  assert.equal(MuseClient.text(r), 'Making it red.');
  const calls = MuseClient.functionCalls(r);
  assert.equal(calls.length, 2);
  assert.deepEqual(calls[0].arguments, { node_id: '1:2', color: '#FF3B30' });
  assert.deepEqual(calls[1].arguments, {});
});

/** A fetch stand-in: answers from a list, one per call, and records what it was asked. */
function scriptedFetch(replies, { delayMs = 0 } = {}) {
  const calls = [];
  let inFlight = 0;
  const fetchImpl = async (url, init) => {
    calls.push({ url, body: JSON.parse(init.body) });
    inFlight += 1;
    fetchImpl.maxInFlight = Math.max(fetchImpl.maxInFlight, inFlight);
    try {
      if (delayMs) await new Promise((r) => setTimeout(r, delayMs));
      const reply = replies.length > 1 ? replies.shift() : replies[0];
      if (reply instanceof Error) throw reply;
      return {
        status: reply.status ?? 200,
        headers: { get: (h) => reply.headers?.[h.toLowerCase()] ?? null },
        text: async () => JSON.stringify(reply.json ?? { status: 'completed', output: [] }),
      };
    } finally {
      inFlight -= 1;
    }
  };
  fetchImpl.calls = calls;
  fetchImpl.maxInFlight = 0;
  return fetchImpl;
}

test('the rate limit (429) is waited out and tried again, using Retry-After', async () => {
  const delays = [];
  const fetchImpl = scriptedFetch([{ status: 429, headers: { 'retry-after': '2' }, json: { error: 'slow down' } }, { status: 200 }]);
  const muse = new MuseClient({ key: 'k', fetchImpl, retryDelay: (attempt, after) => { delays.push([attempt, after]); return 0; } });
  await muse.respond({ input: [] });
  assert.equal(fetchImpl.calls.length, 2);
  assert.deepEqual(delays, [[0, '2']]);
});

test('retry waits: Retry-After is honoured but capped at 10 s; otherwise 0.5 s then 1.5 s', async () => {
  const { retryDelayMs } = await import('../src/muse.js');
  assert.equal(retryDelayMs(0, '2'), 2000);
  assert.equal(retryDelayMs(0, '600'), 10000);
  assert.equal(retryDelayMs(0, null), 500);
  assert.equal(retryDelayMs(1, undefined), 1500);
});

test('a server that keeps failing is tried three times, then the error says why', async () => {
  const fetchImpl = scriptedFetch([{ status: 503, json: { error: 'down' } }]);
  const muse = new MuseClient({ key: 'k', fetchImpl, retryDelay: () => 0 });
  await assert.rejects(muse.respond({ input: [] }), /HTTP 503/);
  assert.equal(fetchImpl.calls.length, 3);
});

test('no more than maxConcurrent Muse calls are in flight, however many tasks run', async () => {
  const fetchImpl = scriptedFetch([{ status: 200 }], { delayMs: 20 });
  const muse = new MuseClient({ key: 'k', fetchImpl, maxConcurrent: 3 });
  await Promise.all(Array.from({ length: 10 }, () => muse.respond({ input: [] })));
  assert.equal(fetchImpl.calls.length, 10);
  assert.equal(fetchImpl.maxInFlight, 3);
  assert.equal(muse.active, 0);
});

test('a call stopped while it waits for a free slot never reaches Muse', async () => {
  const fetchImpl = scriptedFetch([{ status: 200 }], { delayMs: 40 });
  const muse = new MuseClient({ key: 'k', fetchImpl, maxConcurrent: 1 });
  const first = muse.respond({ input: [] });
  const controller = new AbortController();
  const second = muse.respond({ input: [] }, { signal: controller.signal });
  controller.abort();
  await first;
  await assert.rejects(second, { name: 'AbortError' });
  assert.equal(fetchImpl.calls.length, 1);
});

test('Muse Image: a network error is tried again; an answer with no picture is an error', async () => {
  const fetchImpl = scriptedFetch([new TypeError('fetch failed'), { status: 200, json: { data: [{ b64_json: 'QUJD' }] } }]);
  const muse = new MuseClient({ key: 'k', fetchImpl, retryDelay: () => 0 });
  assert.equal(await muse.image('a beach'), 'QUJD');
  assert.equal(fetchImpl.calls.length, 2);
  assert.equal(fetchImpl.calls[1].body.model, 'muse-image-1.0');
  const empty = new MuseClient({ key: 'k', fetchImpl: scriptedFetch([{ status: 200, json: { data: [] } }]) });
  await assert.rejects(empty.image('a beach'), /no picture/);
});
