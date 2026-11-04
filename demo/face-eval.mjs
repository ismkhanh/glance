// Scores "which window is the user facing?" without calibration, on the 12 cued frames of demo/jobs/face-test.sh.
//   A: the camera photo, mirrored like a selfie → Muse Spark
//   B: SAM 3.1 finds the face → crop, mirror, place it at the centre of the screen split into 4 numbered regions → Muse Spark
//   node demo/face-eval.mjs demo/facetest demo/logs/screen.png
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { MuseClient, museKey, MODEL } from '../brain/src/muse.js';

const dir = process.argv[2] || 'demo/facetest';
const screenshot = process.argv[3] || 'demo/logs/screen.png';
const cues = JSON.parse(readFileSync(`${dir}/cues.json`, 'utf8'));
const duration = Number(execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', `${dir}/camera.mov`]).toString());
// The camera stops right after camEnd was written, so its first frame was `duration` seconds before that.
const t0 = Number(readFileSync(`${dir}/camEnd.txt`, 'utf8')) - duration;
const REGION = { 'top-left': 1, 'top-right': 2, 'bottom-left': 3, 'bottom-right': 4 };
const key = museKey();
const muse = new MuseClient({ key });
const b64 = (path) => `data:image/jpeg;base64,${readFileSync(path).toString('base64')}`;
const magick = (...args) => execFileSync('magick', args);

mkdirSync(`${dir}/frames`, { recursive: true });
// The screen, 1280 wide, with the four regions numbered.
const grid = `${dir}/frames/grid.png`;
magick(screenshot, '-resize', '1280x', '-fill', 'none', '-stroke', '#FFD60A', '-strokewidth', '6',
  '-draw', 'line 640,0 640,2000', '-draw', 'line 0,416 1280,416',
  '-stroke', 'none', '-fill', '#FFD60A', '-font', '/System/Library/Fonts/Helvetica.ttc', '-pointsize', '120', '-gravity', 'NorthWest',
  '-annotate', '+40+20', '1', '-annotate', '+1180+20', '2', '-annotate', '+40+640', '3', '-annotate', '+1180+640', '4', grid);

async function samFace(path) {
  const r = await fetch('https://api.meta.ai/v1/responses', {
    method: 'POST', headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ model: 'sam-3.1', input: [{ role: 'user', content: [{ type: 'input_text', text: 'face' }, { type: 'input_image', image_url: b64(path) }] }] }),
  });
  const text = MuseClient.text(await r.json());
  const m = text.match(/<\|box;x1=(\d+);y1=(\d+);x2=(\d+);y2=(\d+);w=(\d+);h=(\d+)\|>/);
  return m ? m.slice(1).map(Number) : null;
}

async function ask(images, text) {
  const content = [{ type: 'input_text', text }, ...images.map((p) => ({ type: 'input_image', image_url: b64(p) }))];
  const response = await muse.respond({ model: MODEL, store: false, reasoning: { effort: 'low' }, input: [{ role: 'user', content }] });
  return MuseClient.text(response);
}

const PROMPT_A = 'This is a webcam photo of a person at a laptop, mirrored like a selfie: if their nose points to the left of this ' +
  'picture, they are facing the left of their screen. Their screen is split into four regions: 1 top-left, 2 top-right, ' +
  '3 bottom-left, 4 bottom-right. Judge where the nose points (head turn left or right, head tilt up or down). ' +
  'Which region are they facing? Reply with the number only.';
const PROMPT_B = 'This is the user\'s screen, split into four numbered regions. In the middle is a live photo of the user\'s face, ' +
  'mirrored like a selfie, so the region their nose points toward in this picture is the region they are facing. Judge the ' +
  'head turn (left or right) and tilt (up or down). Which region (1, 2, 3 or 4) is the face turned toward? Reply with the number only.';

const rows = [];
for (let i = 0; i < cues.length; i++) {
  const want = REGION[cues[i].corner];
  const at = (cues[i].t - t0 + 1.6).toFixed(2);           // 1.6 s after the cue: head has turned and settled
  const raw = `${dir}/frames/${i}-raw.jpg`;
  const mirrored = `${dir}/frames/${i}-mirrored.jpg`;
  execFileSync('ffmpeg', ['-v', 'error', '-y', '-ss', at, '-i', `${dir}/camera.mov`, '-frames:v', '1', '-q:v', '3', raw]);
  magick(raw, '-flop', '-resize', '960x', mirrored);

  let t = Date.now();
  const a = (await ask([mirrored], PROMPT_A)).match(/[1-4]/)?.[0];
  const msA = Date.now() - t;

  t = Date.now();
  const box = await samFace(raw);
  const msSam = Date.now() - t;
  let b = null;
  let msB = 0;
  if (box) {
    const [x1, y1, x2, y2] = box;
    const pad = Math.round((x2 - x1) * 0.35);
    const face = `${dir}/frames/${i}-face.png`;
    magick(raw, '-crop', `${x2 - x1 + 2 * pad}x${y2 - y1 + 2 * pad}+${Math.max(0, x1 - pad)}+${Math.max(0, y1 - pad)}`, '+repage', '-flop', '-resize', 'x300', face);
    const composite = `${dir}/frames/${i}-composite.jpg`;
    magick(grid, face, '-gravity', 'center', '-composite', '-quality', '85', composite);
    t = Date.now();
    b = (await ask([composite], PROMPT_B)).match(/[1-4]/)?.[0];
    msB = Date.now() - t;
  }
  rows.push({ corner: cues[i].corner, want, a: Number(a), b: Number(b), msA, msSam, msB });
  console.log(`${cues[i].corner.padEnd(12)} want ${want}  A ${a} ${Number(a) === want ? '✓' : '✗'} ${msA}ms   ` +
              `B ${b} ${Number(b) === want ? '✓' : '✗'} sam ${msSam}ms + ${msB}ms`);
}
const score = (k) => rows.filter((r) => r[k] === r.want).length;
const lr = (k) => rows.filter((r) => r[k] && ((r[k] - 1) % 2) === ((r.want - 1) % 2)).length;
const tb = (k) => rows.filter((r) => r[k] && (r[k] > 2) === (r.want > 2)).length;
console.log(`\nA: ${score('a')}/${rows.length} (left/right ${lr('a')}, top/bottom ${tb('a')})`);
console.log(`B: ${score('b')}/${rows.length} (left/right ${lr('b')}, top/bottom ${tb('b')})`);
writeFileSync(`${dir}/results.json`, JSON.stringify(rows, null, 2));
