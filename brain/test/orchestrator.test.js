// The orchestrator with the real plugin code on a fake Figma document, and a scripted Muse.
import test from 'node:test';
import assert from 'node:assert/strict';
import { Orchestrator } from '../src/orchestrator.js';
import { FigmaLink } from '../src/figmaLink.js';
import { makeFigma, sampleDesign, connectPlugin } from './fakes/fakeFigma.js';
import { FakeMuse, callResponse, waitFor } from './fakes/scriptedMuse.js';

const BLUE = '#0A84FF';
const RED = '#FF3B30';
const GREEN = '#34C759';

function setup({ muse = {}, connect = true } = {}) {
  const design = sampleDesign();
  const link = new FigmaLink({ timeoutMs: 2000 });
  if (connect) connectPlugin(link, design);
  const fake = new FakeMuse(muse);
  const orch = new Orchestrator({ muse: fake, figma: link, selectionDelayMs: 0 });
  const asks = [];
  const toasts = [];
  const askDone = [];
  const t0 = Date.now();
  orch.on('ask', (e) => asks.push({ ...e, at: Date.now() - t0 }));
  orch.on('askDone', (e) => askDone.push(e));
  orch.on('toast', (e) => toasts.push(e));
  let n = 0;
  /** What the app does: Figma selects the layer under the pointer (Cmd+click), then the words arrive. */
  const say = async (nodeId, text, extra = {}) => {
    const id = `p${++n}`;
    if (nodeId) design.select(nodeId);
    else design.select();
    orch.point({ id, at: { x: 100 + n, y: 200 }, window: { app: 'Figma', bundleID: 'com.figma.Desktop' } });
    return orch.command({ id, text, ...extra });
  };
  const task = (id) => orch.tasks.get(id);
  const fill = (id) => design.figma.currentPage && design.node(id) && plugin_fill(design.node(id));
  return { design, link, muse: fake, orch, asks, askDone, toasts, say, task, fill, t0 };
}

function plugin_fill(node) {
  const p = node.fills.find((x) => x.type === 'SOLID');
  const hex = (v) => Math.round(v * 255).toString(16).padStart(2, '0').toUpperCase();
  return p ? `#${hex(p.color.r)}${hex(p.color.g)}${hex(p.color.b)}` : null;
}

const settled = (t) => ['done', 'failed', 'cancelled', 'reverted'].includes(t.status);

test('two quick commands run in parallel: the red button finishes while the banner asks which way to scroll', async () => {
  const { say, task, asks, fill, design, orch, t0 } = setup({ muse: { delayMs: 60 } });
  const a1 = await say('1:2', 'turn it red');
  const a2 = await say('1:4', 'make it scrollable');
  assert.equal(a1.kind, 'new');
  assert.equal(a2.kind, 'new');
  assert.notEqual(a1.taskId, a2.taskId);

  await waitFor(() => asks.length === 1, { what: 'the scroll question' });
  const ask = asks[0];
  assert.equal(ask.taskId, a2.taskId);
  assert.deepEqual(ask.options, ['Horizontal', 'Vertical']);
  assert.equal(ask.recommended, 'Horizontal');         // the cards already spill out sideways
  assert.match(ask.reason, /spills out horizontally/);
  assert.deepEqual(ask.anchor, { x: 102, y: 200 });     // the tooltip goes where the pointer was

  await waitFor(() => task(a1.taskId).status === 'done', { what: 'red task done' });
  const doneAt = Date.now() - t0;
  assert.ok(ask.at < doneAt, `the question (${ask.at} ms) came before the red task finished (${doneAt} ms): they ran in parallel`);
  assert.equal(fill('1:2'), RED);
  assert.equal(task(a1.taskId).review.status, 'passed');
  assert.equal(task(a2.taskId).status, 'asking');      // still waiting for the user, not blocking anything

  assert.equal(orch.answer(a2.taskId, 'horizontal'), true);
  await waitFor(() => task(a2.taskId).status === 'done', { what: 'scroll task done' });
  assert.equal(design.node('1:4').overflowDirection, 'HORIZONTAL');
  assert.equal(design.node('1:4').clipsContent, true);
  assert.equal(task(a2.taskId).review.status, 'passed', task(a2.taskId).review.notes.join(' '));
});

test('pointing at the same layer while its task runs merges the new words into that task', async () => {
  const { say, task, fill, orch } = setup({ muse: { delayMs: 120 } });
  const a1 = await say('1:2', 'turn it red');
  await new Promise((r) => setTimeout(r, 30));
  const a2 = await say('1:2', 'no, make it green');
  assert.equal(a2.kind, 'update');
  assert.equal(a2.taskId, a1.taskId);
  await waitFor(() => settled(task(a1.taskId)), { what: 'task settled' });
  const t = task(a1.taskId);
  assert.equal(t.status, 'done');
  assert.equal(fill('1:2'), GREEN);
  assert.deepEqual(t.updates, ['no, make it green']);
  assert.equal(orch.tasks.size, 1);
  assert.equal(t.review.status, 'passed', t.review.notes.join(' '));
});

test('new words while a task is asking close the question; the reviewer brings it back for the part still missing', async () => {
  const { say, task, asks, askDone, fill, design, orch } = setup({ muse: { delayMs: 10 } });
  const a1 = await say('1:4', 'make it scrollable');
  await waitFor(() => asks.length === 1, { what: 'first question' });
  const a2 = await say('1:4', 'and make it red too');
  assert.equal(a2.kind, 'update');
  await waitFor(() => askDone.length >= 1, { what: 'question closed' });
  await waitFor(() => asks.length === 2, { what: 'question asked again after review' });
  assert.equal(fill('1:4'), RED);
  assert.match(task(a1.taskId).feedback || '', /no frame scrolls/);
  orch.answer(a1.taskId, 'Vertical');
  await waitFor(() => settled(task(a1.taskId)), { what: 'task settled' });
  assert.equal(task(a1.taskId).status, 'done');
  assert.equal(design.node('1:4').overflowDirection, 'VERTICAL');
});

test('pause holds every change until resume', async () => {
  const { say, task, fill, orch } = setup({ muse: { delayMs: 60 } });
  const a = await say('1:2', 'turn it red');
  assert.equal(await orch.control(a.taskId, 'pause'), true);
  assert.equal(task(a.taskId).status, 'paused');
  await new Promise((r) => setTimeout(r, 250));
  assert.equal(fill('1:2'), BLUE, 'nothing changed while paused');
  assert.equal(task(a.taskId).status, 'paused');
  await orch.control(a.taskId, 'resume');
  await waitFor(() => task(a.taskId).status === 'done', { what: 'done after resume' });
  assert.equal(fill('1:2'), RED);
});

test('editing a task while it is being checked undoes it and starts again with the new words', async () => {
  const { say, task, fill, orch, muse } = setup({
    muse: { delayMs: (body) => (body.tools ? 10 : 400) },     // the review call is slow, so we edit during it
  });
  const a = await say('1:2', 'turn it red');
  await waitFor(() => task(a.taskId).status === 'verifying', { what: 'verifying' });
  assert.equal(fill('1:2'), RED);
  assert.equal(await orch.edit(a.taskId, 'make it green'), true);
  await waitFor(() => task(a.taskId).status === 'done' && fill('1:2') === GREEN, { what: 'green', timeout: 5000 });
  const t = task(a.taskId);
  assert.equal(t.instruction, 'make it green');
  assert.ok(!t.history.some((h) => h.includes(RED)), 'the old red step is gone from the history');
  assert.ok(muse.workerPrompts().at(-1).includes('make it green'));
  await orch.control(a.taskId, 'undo');
  assert.equal(fill('1:2'), BLUE, 'undo goes back to the original, not to red');
});

test('cancel stops a running task and leaves the layer as it was', async () => {
  const { say, task, fill, orch } = setup({ muse: { delayMs: 100 } });
  const a = await say('1:2', 'turn it red');
  await orch.control(a.taskId, 'cancel');
  assert.equal(task(a.taskId).status, 'cancelled');
  await new Promise((r) => setTimeout(r, 250));
  assert.equal(fill('1:2'), BLUE);
  assert.equal(task(a.taskId).status, 'cancelled');
});

test('a finished task reopened by pointing again keeps one undo point: the original', async () => {
  const { say, task, fill, orch } = setup();
  const a1 = await say('1:2', 'turn it red');
  await waitFor(() => task(a1.taskId).status === 'done');
  const a2 = await say('1:2', 'now make it green');
  assert.equal(a2.kind, 'update');
  await waitFor(() => task(a1.taskId).status === 'done' && fill('1:2') === GREEN, { what: 'green' });
  await orch.control(a1.taskId, 'undo');
  assert.equal(task(a1.taskId).status, 'reverted');
  assert.equal(fill('1:2'), BLUE);
});

test('the reviewer catches a wrong color and the worker fixes it', async () => {
  const { say, task, fill, muse } = setup({ muse: { wrongColorFirst: true } });
  const a = await say('1:2', 'turn it red');
  await waitFor(() => settled(task(a.taskId)));
  assert.equal(task(a.taskId).status, 'done');
  assert.equal(fill('1:2'), RED);
  assert.ok(muse.workerPrompts().some((p) => /Reviewer feedback from the last try: You asked for red/.test(p)));
  assert.equal(task(a.taskId).review.status, 'passed');
});

test('a task that never gets it right fails with the reviewer\'s reason', async () => {
  const { say, task, toasts } = setup({ muse: { alwaysWrong: true } });
  const a = await say('1:2', 'turn it red');
  await waitFor(() => settled(task(a.taskId)));
  const t = task(a.taskId);
  assert.equal(t.status, 'failed');
  assert.equal(t.review.status, 'failed');
  assert.match(t.review.notes[0], /asked for red/);
  assert.ok(toasts.some((x) => x.kind === 'error' && x.taskId === a.taskId));
});

test('Muse\'s review saying no gets one retry, then the task is done with a warning', async () => {
  const { say, task } = setup({ muse: { reviewPass: false } });
  const a = await say('1:2', 'turn it red');
  await waitFor(() => settled(task(a.taskId)));
  assert.equal(task(a.taskId).status, 'done');
  assert.equal(task(a.taskId).review.status, 'warning');
  assert.match(task(a.taskId).review.notes.join(' '), /Reviewer: not what was asked/);
});

test('a worker may change the pointed layer and its children, but nothing outside it', async () => {
  const decide = (p) => {
    if (!/sneaky/.test(p.request)) return null;
    if (!p.history.length) return callResponse(['set_fill', { node_id: '1:5', color: '#FF00FF' }], ['set_fill', { node_id: '1:3', color: '#FFCC00' }]);
    return callResponse(['finish', { summary: 'Done.' }]);
  };
  const { say, task, fill } = setup({ muse: { decide } });
  const a = await say('1:2', 'sneaky change');
  await waitFor(() => settled(task(a.taskId)));
  const t = task(a.taskId);
  assert.ok(t.history[0].includes('outside the layer you pointed at'));
  assert.equal(fill('1:5'), '#000000');         // the title (outside the button) is still black
  assert.equal(fill('1:3'), '#FFCC00');         // the button's own label: allowed
});

test('pointing at a button\'s label lets the task change the button too, but never the whole screen', async () => {
  const decide = (p) => {
    if (p.history.length) return callResponse(['finish', { summary: 'Done.' }]);
    if (/button/.test(p.request)) return callResponse(['set_fill', { node_id: p.target.parentYouMayChange.id, color: GREEN }]);
    if (/screen/.test(p.request)) return callResponse(['set_fill', { node_id: '1:1', color: '#000000' }]);
    return null;
  };
  const { say, task, fill, muse } = setup({ muse: { decide } });
  const a = await say('1:3', 'make this button green');                 // the pointer is on the label "Buy now"
  await waitFor(() => settled(task(a.taskId)));
  assert.equal(task(a.taskId).status, 'done');
  assert.equal(fill('1:2'), GREEN);
  assert.ok(muse.workerPrompts()[0].includes('"parentYouMayChange":{"id":"1:2","name":"Buy button","type":"FRAME"}'));

  const b = await say('1:5', 'make the whole screen dark');             // the title sits right on the Home screen
  await waitFor(() => settled(task(b.taskId)));
  assert.equal(fill('1:1'), '#FFFFFF');
  assert.ok(task(b.taskId).history[0].includes('outside the layer you pointed at'));
  assert.ok(!muse.workerPrompts().at(-1).includes('parentYouMayChange'));
});

test('a screen inside a Figma section is a screen too: its text never widens to it', async () => {
  const design = makeFigma([{
    id: '5:1', type: 'SECTION', name: 'Onboarding', width: 1200, height: 900, children: [{
      id: '5:2', type: 'FRAME', name: 'Welcome screen', width: 390, height: 844, fill: '#FFFFFF',
      children: [{ id: '5:3', type: 'TEXT', name: 'Heading', characters: 'Welcome', fill: '#000000' }],
    }],
  }]);
  const link = new FigmaLink({ timeoutMs: 2000 });
  connectPlugin(link, design);
  const decide = (p) => (p.history.length ? callResponse(['finish', { summary: 'Done.' }]) : callResponse(['set_fill', { node_id: '5:2', color: '#000000' }]));
  const muse = new FakeMuse({ decide });
  const orch = new Orchestrator({ muse, figma: link, selectionDelayMs: 0 });
  design.select('5:3');
  orch.point({ id: 'p1', window: { app: 'Figma' } });
  const ack = await orch.command({ id: 'p1', text: 'make this screen black' });
  await waitFor(() => settled(orch.tasks.get(ack.taskId)));
  assert.ok(!muse.workerPrompts()[0].includes('parentYouMayChange'));
  assert.ok(orch.tasks.get(ack.taskId).history[0].includes('outside the layer you pointed at'));
  assert.equal(plugin_fill(design.node('5:2')), '#FFFFFF');
});

test('saying "undo that" puts the layer back from the saved copy, without asking Muse', async () => {
  const { say, task, fill, muse } = setup();
  const a = await say('1:2', 'turn it red');
  await waitFor(() => task(a.taskId).status === 'done');
  const calls = muse.bodies.length;
  const ack = await say('1:2', 'undo that');
  assert.equal(ack.kind, 'undo');
  assert.equal(ack.taskId, a.taskId);
  assert.equal(task(a.taskId).status, 'reverted');
  assert.equal(fill('1:2'), BLUE);
  assert.equal(muse.bodies.length, calls);
  assert.equal((await say(null, 'undo')).kind, 'none');                 // nothing left that can be undone
});

test('without the plugin, Glance says to open it instead of failing silently', async () => {
  const { say, toasts } = setup({ connect: false });
  const a = await say(null, 'turn it red');
  assert.equal(a.kind, 'none');
  assert.match(toasts[0].text, /Glance Bridge plugin/);
});

test('task views carry what the task panel shows', async () => {
  const { say, orch, task } = setup();
  const a = await say('1:2', 'turn it red');
  await waitFor(() => task(a.taskId).status === 'done');
  const [view] = orch.views();
  assert.deepEqual(Object.keys(view).sort(), ['createdAt', 'detail', 'id', 'instruction', 'metrics', 'question', 'result', 'review', 'status', 'target', 'title', 'updatedAt', 'updates']);
  assert.deepEqual(view.target, { id: '1:2', name: 'Buy button', type: 'FRAME' });
  assert.equal(view.status, 'done');
});

test('every task counts what it cost: Muse calls (worker and reviewer), tools, retries', async () => {
  const { say, task } = setup({ muse: { wrongColorFirst: true } });
  const a = await say('1:2', 'turn it red');
  await waitFor(() => task(a.taskId).status === 'done');
  const m = task(a.taskId).metrics;
  // Try 1: set_fill (wrong blue) → rules fail, no Muse review. Try 2: set_fill (red) → Muse review passes.
  assert.equal(m.museCalls, 3);
  assert.equal(m.passes, 2);
  assert.equal(m.reviewRetries, 1);
  assert.deepEqual(m.tools, { set_fill: 2 });
  assert.equal(m.toolErrors, 0);
  assert.ok(m.museMs >= 0);
});

test('a long session forgets the oldest finished tasks, never a running one', async () => {
  const { say, orch, task } = setup();
  const first = await say('1:2', 'turn it red');
  await waitFor(() => task(first.taskId).status === 'done');
  for (let i = 0; i < 205; i++) orch.tasks.set(`old${i}`, { id: `old${i}`, status: 'done', target: null });
  const next = await say('1:5', 'make it purple');
  assert.ok(orch.tasks.size <= 200, `${orch.tasks.size} tasks kept`);
  assert.ok(orch.tasks.has(next.taskId));
  await waitFor(() => task(next.taskId).status === 'done');
});

test('done messages read like a sentence, not like a tool call', async () => {
  const { say, task } = setup();
  const a = await say('1:4', 'make it scrollable horizontal');
  await waitFor(() => settled(task(a.taskId)));
  assert.equal(task(a.taskId).result, '"Promo banner" scrolls horizontally now.');
});

test('"put a photo here": Muse Image paints it, the reviewer checks an image landed, undo brings the old fill back', async () => {
  const { say, task, design, muse, orch } = setup();
  const a = await say('1:4', 'put a photo of Lisbon here');
  await waitFor(() => settled(task(a.taskId)), { what: 'image task done' });
  assert.equal(task(a.taskId).status, 'done', JSON.stringify(task(a.taskId).review));
  assert.equal(muse.imagePrompts.length, 1);
  assert.equal(design.figma.images.length, 1);
  assert.equal(design.node('1:4').fills[0].type, 'IMAGE');
  assert.equal(task(a.taskId).review.status, 'passed', 'the old solid fill going away is expected, not a surprise');

  await orch.control(a.taskId, 'undo');
  assert.equal(plugin_fill(design.node('1:4')), '#F2F2F7');
});
