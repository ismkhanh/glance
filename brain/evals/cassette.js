// Record and replay for Muse: a fetch that sits between MuseClient and the network.
//   live:   calls Muse for real and keeps every answer (trimmed to what Glance reads).
//   replay: answers from the recording, no network, no key. A request that was never recorded fails
//           loudly, so a changed prompt or tool list shows up as "re-record", never as a silent pass.
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';

// A 1×1 JPEG: what a recorded Muse Image picture becomes, so the recording stays small.
const TINY_JPEG = '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==';

export function keyOf(url, body) {
  const path = new URL(url).pathname.replace(/^.*\/v1\//, '');
  return createHash('sha256').update(`${path}\n${body}`).digest('hex').slice(0, 24);
}

/** Only what Glance reads from an answer: tool calls, text, usage. Ids, timestamps and reasoning are dropped. */
function trim(json) {
  if (Array.isArray(json?.data)) return { data: json.data.map(() => ({ b64_json: TINY_JPEG })) };
  const output = (json?.output || []).flatMap((item) => {
    if (item.type === 'function_call') return [{ type: 'function_call', name: item.name, call_id: item.call_id, arguments: item.arguments }];
    if (item.type === 'message') return [{ type: 'message', content: (item.content || []).map((c) => ({ type: c.type, text: c.text })) }];
    return [];
  });
  return { status: json?.status, output, output_text: json?.output_text, usage: json?.usage };
}

function reply(status, json) {
  const text = JSON.stringify(json);
  return { status, headers: { get: () => null }, text: async () => text };
}

export class Cassette {
  constructor(file, { mode }) {
    this.file = file;
    this.mode = mode;
    const saved = existsSync(file) ? JSON.parse(readFileSync(file, 'utf8')) : { entries: {} };
    this.entries = saved.entries;
    this.recorded = saved.recorded;
    this.fresh = {};
    this.served = new Map();
    this.misses = 0;
  }

  /** A fetch for MuseClient({fetchImpl}). Each answer carries `ms`: how long Muse took (when it was recorded). */
  fetch = async (url, init) => {
    const key = keyOf(url, init.body);
    if (this.mode === 'replay') {
      const list = this.entries[key];
      if (!list?.length) {
        this.misses += 1;
        return reply(400, { error: `not in the recording (${key}): the prompt, tools or design changed. Run "npm run eval" to record again.` });
      }
      const n = this.served.get(key) || 0;
      this.served.set(key, n + 1);
      const entry = list[n % list.length];
      return { ...reply(200, entry.json), ms: entry.ms };
    }
    const start = performance.now();
    const response = await globalThis.fetch(url, init);
    const text = await response.text();
    const ms = Math.round(performance.now() - start);
    if (response.status === 200) {
      try {
        (this.fresh[key] ||= []).push({ ms, json: trim(JSON.parse(text)) });
      } catch {
        // not JSON: MuseClient reports it
      }
    }
    return { status: response.status, headers: response.headers, text: async () => text, ms };
  };

  /** live: a full run replaces the recording; a partial run (--only) adds to it. */
  save({ partial }) {
    if (this.mode !== 'live') return;
    const entries = partial ? { ...this.entries, ...this.fresh } : this.fresh;
    writeFileSync(this.file, `${JSON.stringify({ model: 'muse-spark-1.3', recorded: new Date().toISOString(), entries })}\n`);
  }
}
