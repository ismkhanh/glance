// Minimal client for the Meta Model API Responses endpoint (same request shape the Swift app uses).
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

export const MODEL = 'muse-spark-1.3';
export const IMAGE_MODEL = 'muse-image-1.0';

/** The .env file at the top of the Glance folder (the Swift app reads the same one). */
export const ENV_FILE = fileURLToPath(new URL('../../.env', import.meta.url));

/** MUSE_API_KEY (or MODEL_API_KEY) from the environment, else from the Glance folder's .env. */
export function museKey(env = process.env, file = ENV_FILE) {
  if (env.MUSE_API_KEY) return env.MUSE_API_KEY;
  if (env.MODEL_API_KEY) return env.MODEL_API_KEY;
  try {
    const text = readFileSync(file, 'utf8');
    for (const raw of text.split(/\r?\n/)) {
      const line = raw.trim().replace(/^export\s+/, '');
      if (!line.startsWith('MUSE_API_KEY=')) continue;
      const value = line.slice('MUSE_API_KEY='.length).trim().replace(/^["']|["']$/g, '');
      if (value) return value;
    }
  } catch {
    // no .env file: the caller reports the missing key
  }
  return null;
}

export class MuseError extends Error {}

/** How long to wait before trying again: Retry-After when Muse sends it (capped), else 0.5 s, then 1.5 s. */
export function retryDelayMs(attempt, retryAfter) {
  const seconds = retryAfter === null || retryAfter === undefined || retryAfter === '' ? NaN : Number(retryAfter);
  if (Number.isFinite(seconds) && seconds >= 0) return Math.min(seconds, 10) * 1000;
  return 500 * 3 ** attempt;
}

function wait(ms, signal) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return reject(abortError());
    const timer = setTimeout(resolve, ms);
    signal?.addEventListener('abort', () => {
      clearTimeout(timer);
      reject(abortError());
    }, { once: true });
  });
}

export class MuseClient {
  /**
   * maxConcurrent: Muse calls in flight at once, across all tasks. Ten quick commands start ten tasks, but only
   * this many talk to Muse at the same time; the rest wait their turn instead of hitting the rate limit.
   */
  constructor({ key, baseUrl = 'https://api.meta.ai/v1', fetchImpl = globalThis.fetch, log = () => {}, timeoutMs = 60000,
                maxConcurrent = 6, retryDelay = retryDelayMs }) {
    this.key = key;
    this.baseUrl = baseUrl.replace(/\/$/, '');
    this.fetch = fetchImpl;
    this.log = log;
    this.timeoutMs = timeoutMs;
    this.maxConcurrent = maxConcurrent;
    this.retryDelay = retryDelay;
    this.active = 0;
    this.waiting = [];
  }

  get available() {
    return Boolean(this.key);
  }

  /** Runs fn when a slot is free. A call stopped while it waits never starts. */
  async limited(fn, signal) {
    while (this.active >= this.maxConcurrent) {
      await new Promise((resolve) => this.waiting.push(resolve));
      if (signal?.aborted) {
        this.waiting.shift()?.();
        throw abortError();
      }
    }
    this.active += 1;
    try {
      return await fn();
    } finally {
      this.active -= 1;
      this.waiting.shift()?.();
    }
  }

  /**
   * One Responses request. A network error, a server error or the rate limit (429) is tried again, up to three
   * tries in all (1 in 11 calls failed on 31 Oct); a bad request or a wrong key is not.
   */
  respond(body, { signal } = {}) {
    if (!this.key) return Promise.reject(new MuseError('No Muse key: set MUSE_API_KEY or add it to the .env file in the Glance folder.'));
    return this.limited(() => this.post('responses', body, { signal, timeoutMs: this.timeoutMs, what: 'Muse' }), signal);
  }

  /** Muse Image: a JPEG (base64) painted from the description. Took 12–20 s on 4 Nov. */
  async image(prompt, { signal } = {}) {
    if (!this.key) throw new MuseError('No Muse key: set MUSE_API_KEY or add it to the .env file in the Glance folder.');
    const body = { model: IMAGE_MODEL, prompt: String(prompt), size: '1024x1024', n: 1, output_format: 'jpeg' };
    const json = await this.limited(
      () => this.post('images/generations', body, { signal, timeoutMs: Math.max(this.timeoutMs, 90000), what: 'Muse Image' }),
      signal,
    );
    const b64 = json?.data?.[0]?.b64_json;
    if (!b64) throw new MuseError('Muse Image sent no picture.');
    return b64;
  }

  async post(path, body, { signal, timeoutMs, what }) {
    const MAX_TRIES = 3;
    let lastError = new MuseError(`${what} was not called.`);
    for (let attempt = 0; attempt < MAX_TRIES; attempt++) {
      if (signal?.aborted) throw abortError();
      const timeout = AbortSignal.timeout(timeoutMs);
      const combined = signal ? AbortSignal.any([signal, timeout]) : timeout;
      let response;
      try {
        response = await this.fetch(`${this.baseUrl}/${path}`, {
          method: 'POST',
          headers: { Authorization: `Bearer ${this.key}`, 'Content-Type': 'application/json' },
          body: JSON.stringify(body),
          signal: combined,
        });
      } catch (error) {
        if (signal?.aborted) throw abortError();
        lastError = error;
        if (attempt < MAX_TRIES - 1) {
          this.log(`(network error, trying again: ${error.message})`);
          await wait(this.retryDelay(attempt), signal);
          continue;
        }
        throw error;
      }
      const text = await response.text();
      let json = {};
      try {
        json = JSON.parse(text);
      } catch {
        // not JSON: handled as an error below
      }
      const failed = json.status === 'failed';
      if (response.status === 200 && !failed) return json;
      lastError = new MuseError(`${what} returned HTTP ${response.status}: ${text.slice(0, 300)}`);
      lastError.status = response.status;
      const retryable = response.status === 429 || response.status >= 500 || failed || text.includes('server_error');
      if (retryable && attempt < MAX_TRIES - 1) {
        this.log(`(${what} ${response.status === 429 ? 'rate limit' : 'error'}, trying again: ${text.slice(0, 120)})`);
        await wait(this.retryDelay(attempt, response.headers?.get?.('retry-after')), signal);
        continue;
      }
      throw lastError;
    }
    throw lastError;
  }

  static text(response) {
    if (typeof response?.output_text === 'string' && response.output_text) return response.output_text.trim();
    const parts = [];
    for (const item of response?.output ?? []) {
      if (item.type !== 'message') continue;
      for (const c of item.content ?? []) if (typeof c.text === 'string') parts.push(c.text);
    }
    return parts.join(' ').trim();
  }

  static functionCalls(response) {
    const calls = [];
    for (const item of response?.output ?? []) {
      if (item.type !== 'function_call' || !item.name || !item.call_id) continue;
      let args = {};
      try {
        args = typeof item.arguments === 'string' ? JSON.parse(item.arguments || '{}') : item.arguments ?? {};
      } catch {
        args = {};
      }
      calls.push({ callId: item.call_id, name: item.name, arguments: args });
    }
    return calls;
  }
}

export function abortError() {
  const e = new Error('Stopped.');
  e.name = 'AbortError';
  return e;
}
