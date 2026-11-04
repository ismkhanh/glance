// Streams Kokoro WAV files to Muse Voice Transcribe at real speed and prints what it heard.
//   node demo/asr-check.mjs demo/audio/c01.wav demo/audio/c02.wav ...
import { readFileSync } from 'node:fs';
import { setTimeout as sleep } from 'node:timers/promises';
import { museKey } from '../brain/src/muse.js';

const KEY = museKey();
const FRAME = (24000 * 2 * 80) / 1000; // 80 ms of 24 kHz 16-bit mono

function pcmOf(path) {
  const wav = readFileSync(path);
  const at = wav.indexOf('data') + 8;  // our WAVs have one plain data chunk
  return wav.subarray(at);
}

function transcribe(path) {
  const audio = Buffer.concat([Buffer.alloc(FRAME * 3), pcmOf(path), Buffer.alloc(FRAME * 4)]);
  return new Promise((resolve) => {
    const ws = new WebSocket(`wss://api.meta.ai/v1/asr/realtime?sessionId=glance-demo-${Date.now()}`);
    const timer = setTimeout(() => done('timeout'), 30000);
    const done = (text) => {
      clearTimeout(timer);
      try { ws.close(); } catch {}
      resolve(text);
    };
    ws.addEventListener('open', () => ws.send(JSON.stringify({
      authorization: { accessToken: `Bearer ${KEY}` },
      audioEncoding: 'PCM_24KHZ',
      model: 'muse-voice-transcribe-1.0',
      mode: 'PUSH_TO_TALK',
      partialMode: 'CUMULATIVE',
      languageBias: ['English'],
      emitAudioProgress: false,
    })));
    ws.addEventListener('message', async (ev) => {
      if (typeof ev.data !== 'string') return;
      const msg = JSON.parse(ev.data);
      if (!msg.type && msg.sessionId) {
        const start = performance.now();
        for (let off = 0, n = 0; off < audio.length; off += FRAME, n++) {
          ws.send(audio.subarray(off, off + FRAME));
          const wait = start + (n + 1) * 80 - performance.now();
          if (wait > 0) await sleep(wait);
        }
        ws.send(JSON.stringify({ type: 'endStream' }));
      } else if (msg.type === 'transcript' && msg.final) {
        done(msg.transcript);
      } else if (msg.type === 'error') {
        done(`error: ${msg.message}`);
      }
    });
    ws.addEventListener('error', () => done('socket error'));
  });
}

for (const path of process.argv.slice(2)) {
  console.log(`${path.split('/').pop()}: "${await transcribe(path)}"`);
}
