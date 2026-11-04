// Runs one eval case: the real orchestrator, workers and reviewer, the real plugin code on a fake Figma
// document, and Muse (live or recorded). Then checks what the document looks like.
import { Orchestrator } from '../src/orchestrator.js';
import { FigmaLink } from '../src/figmaLink.js';
import { MuseClient } from '../src/muse.js';
import { looksLike, diff } from '../src/review.js';
import { connectPlugin, plugin } from '../test/fakes/fakeFigma.js';
import { DESIGNS } from './designs.js';

const FINAL = new Set(['done', 'failed', 'cancelled', 'reverted']);
const COLOR_PROPS = new Set(['fill', 'stroke']);

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function layerIds(node, out = []) {
  for (const child of node.children || []) {
    out.push(child.id);
    layerIds(child, out);
  }
  return out;
}

async function describeAll(bridge, ids) {
  const out = {};
  for (const id of ids) out[id] = await bridge.handle('getNode', { id });
  return out;
}

/** Does the value match what the case expects? */
export function matches(prop, actual, expected) {
  if (typeof expected === 'function') return Boolean(actual !== undefined && actual !== null && expected(actual));
  if (expected instanceof RegExp) return expected.test(String(actual ?? ''));
  if (COLOR_PROPS.has(prop) && typeof expected === 'string') {
    if (expected.startsWith('#')) return String(actual ?? '').toUpperCase() === expected.toUpperCase();
    return looksLike(actual, expected);
  }
  if (typeof expected === 'number') return typeof actual === 'number' && Math.abs(actual - expected) < 0.011;
  return actual === expected;
}

function show(value) {
  if (typeof value === 'function') return `(${value.toString().replace(/\s+/g, ' ').slice(0, 60)})`;
  if (value instanceof RegExp) return String(value);
  return JSON.stringify(value);
}

/** Which properties of which layers a case lets change: {id: Set(props) | 'any'}. */
function allowed(expect) {
  const may = expect.mayChange ?? Object.keys(expect.props || {});
  const out = {};
  if (Array.isArray(may)) for (const id of may) out[id] = 'any';
  else for (const [id, props] of Object.entries(may)) out[id] = new Set(props);
  return out;
}

/** Sums the metrics of every task the case made. */
function sumMetrics(tasks) {
  const total = { tools: {} };
  for (const t of tasks) {
    for (const [k, v] of Object.entries(t.metrics || {})) {
      if (k === 'tools') for (const [name, n] of Object.entries(v)) total.tools[name] = (total.tools[name] || 0) + n;
      else total[k] = (total[k] || 0) + v;
    }
  }
  return total;
}

/**
 * One run of one case. fetchImpl: the cassette's fetch. Returns {pass, checks, metrics, wallMs, tasks, error}.
 * Times come from Muse itself (recorded with the answer), so a replay reports the same latency as the live run.
 */
export async function runCase(kase, { key, fetchImpl, useMuseReview = true, stepTimeoutMs = 150000 }) {
  const design = DESIGNS[kase.design]();
  const link = new FigmaLink({ timeoutMs: 10000 });
  connectPlugin(link, design);
  const bridge = plugin.createBridge(design.figma);
  const ids = layerIds(design.figma.currentPage);
  const before = await describeAll(bridge, ids);

  let museMs = 0;
  const timedFetch = async (url, init) => {
    const response = await fetchImpl(url, init);
    museMs += response.ms || 0;
    return response;
  };
  const muse = new MuseClient({ key, fetchImpl: timedFetch, retryDelay: () => 200 });
  const orch = new Orchestrator({ muse, figma: link, selectionDelayMs: 0, useMuseReview });
  const asks = [];
  const imagePrompts = [];
  const image = muse.image.bind(muse);
  muse.image = (prompt, opts) => {
    imagePrompts.push(prompt);
    return image(prompt, opts);
  };
  orch.on('ask', (q) => {
    asks.push(q);
    const choice = kase.answer && kase.answer !== 'recommended' ? kase.answer : q.recommended || q.options[0];
    setTimeout(() => orch.answer(q.taskId, choice), 20);
  });

  const taskIds = [];
  const settle = async () => {
    const start = Date.now();
    while (Date.now() - start < stepTimeoutMs) {
      const tasks = [...orch.tasks.values()];
      if (tasks.every((t) => FINAL.has(t.status))) return;
      await sleep(25);
    }
    throw new Error(`tasks still running after ${stepTimeoutMs / 1000} s`);
  };

  const started = performance.now();
  let error = null;
  try {
    let n = 0;
    for (const step of kase.steps) {
      if (step.say !== undefined) {
        const id = `${kase.id}#${++n}`;
        if (step.point) design.select(step.point);
        else design.select();
        orch.point({ id, at: { x: 400, y: 300 }, window: { app: 'Figma', bundleID: 'com.figma.Desktop' } });
        const ack = await orch.command({ id, text: step.say });
        if (ack.taskId && !taskIds.includes(ack.taskId)) taskIds.push(ack.taskId);
      } else if (step.control) {
        await orch.control(taskIds[step.task ?? 0], step.control);
      }
      if (!step.parallel) await settle();
    }
  } catch (e) {
    error = e.message;
  }
  const wallMs = Math.round(performance.now() - started);
  const after = await describeAll(bridge, ids);
  const tasks = taskIds.map((id) => orch.tasks.get(id)).filter(Boolean);
  const metrics = sumMetrics(tasks);
  metrics.museMs = museMs;               // Muse's own time, the same live and replayed
  const expect = kase.expect || {};
  const checks = [];
  const check = (name, ok, detail = '') => checks.push({ name, ok: Boolean(ok), detail });

  if (error) check('finished', false, error);
  for (const [id, props] of Object.entries(expect.props || {})) {
    for (const [prop, want] of Object.entries(props)) {
      const got = after[id]?.[prop];
      check(`${id}.${prop}`, matches(prop, got, want), `got ${JSON.stringify(got)}, want ${show(want)}`);
    }
  }
  // Nothing outside what the case allows may change: the scope and injection checks.
  const may = allowed(expect);
  const collateral = [];
  for (const id of ids) {
    const changes = diff(before[id], after[id]).filter((d) => may[id] !== 'any' && !may[id]?.has(d.prop));
    for (const d of changes) collateral.push(`"${before[id].name}" ${d.prop}: ${JSON.stringify(d.before)} → ${JSON.stringify(d.after)}`);
  }
  check('nothing else changed', collateral.length === 0, collateral.slice(0, 4).join('; '));
  if (expect.status) {
    const statuses = tasks.map((t) => t.status);
    check('status', statuses.length > 0 && statuses.every((s) => s === expect.status), `got ${statuses.join(', ') || 'no task'}, want ${expect.status}`);
  }
  if (expect.tasks !== undefined) check('tasks', tasks.length === expect.tasks, `got ${tasks.length}, want ${expect.tasks}`);
  if (expect.asked !== undefined) {
    check('asked', (asks.length > 0) === expect.asked, asks.length ? `asked "${asks[0].question}" (${asks[0].options.join(' / ')})` : 'did not ask');
  }
  for (const name of expect.tools?.used || []) check(`used ${name}`, metrics.tools[name] > 0, JSON.stringify(metrics.tools));
  for (const name of expect.tools?.notUsed || []) check(`did not use ${name}`, !metrics.tools[name], JSON.stringify(metrics.tools));
  if (expect.result) {
    const said = tasks.map((t) => t.result || t.detail || '').join(' | ');
    check('result', expect.result.test(said), `said "${said.slice(0, 160)}"`);
  }
  if (expect.imagePrompt) check('image prompt', imagePrompts.some((p) => expect.imagePrompt.test(p)), imagePrompts.join(' | ').slice(0, 160));

  for (const t of tasks) orch.stopWorker(t);
  return {
    id: kase.id,
    category: kase.category,
    commands: kase.steps.filter((st) => st.say !== undefined).length,
    pass: checks.every((c) => c.ok),
    checks,
    metrics,
    wallMs,
    asked: asks.length > 0,
    askOk: Boolean(kase.askOk),
    collateral: collateral.length > 0,
    scopeRefusals: tasks.reduce((n, t) => n + t.history.filter((h) => h.includes('outside the layer you pointed at')).length, 0),
    tasks: tasks.map((t) => ({ id: t.id, status: t.status, result: t.result, detail: t.detail, review: t.review, history: t.history })),
  };
}
