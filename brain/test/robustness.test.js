// What happens when Muse does not behave like the script: unknown tools, bad colors, text instead of tools,
// numbers as strings, a plugin that stops answering.
import test from 'node:test';
import assert from 'node:assert/strict';
import { Orchestrator } from '../src/orchestrator.js';
import { FigmaLink } from '../src/figmaLink.js';
import { sampleDesign, connectPlugin } from './fakes/fakeFigma.js';
import { FakeMuse, callResponse, textResponse, waitFor } from './fakes/scriptedMuse.js';

function setup(decide, { timeoutMs = 2000, connect = true } = {}) {
  const design = sampleDesign();
  const link = new FigmaLink({ timeoutMs });
  if (connect) connectPlugin(link, design);
  const muse = new FakeMuse({ decide });
  const orch = new Orchestrator({ muse, figma: link, selectionDelayMs: 0 });
  let n = 0;
  const say = (nodeId, text) => {
    const id = `p${++n}`;
    design.select(nodeId);
    orch.point({ id, at: { x: 1, y: 1 }, window: { bundleID: 'com.figma.Desktop' } });
    return orch.command({ id, text });
  };
  return { design, link, muse, orch, say, task: (id) => orch.tasks.get(id) };
}

const settled = (t) => ['done', 'failed', 'cancelled', 'reverted'].includes(t.status);

test('an unknown tool and a bad color are reported back to Muse, which then gets it right', async () => {
  const decide = (p) => {
    if (p.history.length === 0) return callResponse(['paint_it', { node_id: p.target.id }], ['set_fill', { node_id: p.target.id, color: 'reddish' }]);
    // (the error for "reddish" mentions #FF3B30 as an example, so only a set_fill that worked counts)
    if (!p.history.some((h) => h.startsWith('set_fill') && h.includes('#FF3B30') && !h.includes('Could not'))) {
      return callResponse(['set_fill', { node_id: p.target.id, color: '#ff3b30' }]);
    }
    return callResponse(['finish', { summary: 'Red now.' }]);
  };
  const { say, task, design } = setup(decide);
  const a = await say('1:2', 'turn it red');
  await waitFor(() => settled(task(a.taskId)));
  const t = task(a.taskId);
  assert.equal(t.status, 'done');
  assert.match(t.history[0], /Unknown tool "paint_it"/);
  assert.match(t.history[1], /"reddish" is not a color/);
  assert.equal(design.node('1:2').fills[0].color.r, 1);
});

test('Muse answering in text instead of acting is caught by the reviewer, and the retry acts', async () => {
  const decide = (p) => {
    if (!p.feedback) return textResponse('Sure, I will make it red.');
    if (!p.history.some((h) => h.startsWith('set_fill'))) return callResponse(['set_fill', { node_id: p.target.id, color: '#FF3B30' }]);
    return null;
  };
  const { say, task } = setup(decide);
  const a = await say('1:2', 'turn it red');
  await waitFor(() => settled(task(a.taskId)));
  assert.equal(task(a.taskId).status, 'done');
  assert.equal(task(a.taskId).review.status, 'passed');
});

test('numbers sent as strings still work', async () => {
  const decide = (p) => (p.history.length === 0
    ? callResponse(['set_corner_radius', { node_id: p.target.id, radius: '24' }], ['set_opacity', { node_id: p.target.id, opacity: '0.5' }])
    : null);
  const { say, task, design } = setup(decide);
  const a = await say('1:2', 'round the corners and make it half see-through');
  await waitFor(() => settled(task(a.taskId)));
  assert.equal(task(a.taskId).status, 'done', task(a.taskId).detail);
  assert.equal(design.node('1:2').cornerRadius, 24);
  assert.equal(design.node('1:2').opacity, 0.5);
});

test('a plugin that stops answering makes the task fail with a clear reason instead of hanging', async () => {
  const { say, task, link, design } = setup(null, { timeoutMs: 150 });
  const a = await say('1:2', 'turn it red');
  // The plugin goes silent: calls are sent but never answered.
  link.socket.send = () => {};
  await waitFor(() => settled(task(a.taskId)), { timeout: 5000 });
  const t = task(a.taskId);
  assert.ok(['failed', 'done'].includes(t.status));
  assert.ok(t.history.some((h) => /did not answer/.test(h)) || /did not answer/.test(t.detail), t.detail);
  assert.equal(design.node('1:2').fills[0].color.b, 1, 'the button is still blue');
});

test('a command while nothing is selected starts a task that can look layers up by name', async () => {
  const decide = (p) => {
    if (p.target) return null;
    if (!p.history.length) return callResponse(['find_layers', { query: 'banner' }]);
    return callResponse(['finish', { summary: 'Found it: Promo banner.' }]);
  };
  const { say, task } = setup(decide);
  const a = await say(null, 'which layer is the banner?');
  await waitFor(() => settled(task(a.taskId)));
  assert.equal(task(a.taskId).status, 'done');
  assert.match(task(a.taskId).history[0], /Promo banner/);
});

test('a tool call Muse wrote as text becomes its summary', async () => {
  const { plainText } = await import('../src/worker.js');
  const raw = '<atem:function_calls>\n<atem:invoke name="default.finish">\n<atem:parameter name="summary">Trip cards now scroll horizontally.</atem:parameter>\n</atem:invoke>\n</atem:function_calls>';
  assert.equal(plainText(raw), 'Trip cards now scroll horizontally.');
  assert.equal(plainText('<x:invoke name="a">Done <b>.</x:invoke>'), 'Done <b>.');
  assert.equal(plainText('Plain words stay.'), 'Plain words stay.');
});
