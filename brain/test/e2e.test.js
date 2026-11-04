// End to end over real WebSockets: a fake Glance app, the real brain server, the real plugin code on a
// fake Figma document (connected like ui.html), and a mock Muse HTTP server called by the real MuseClient.
import test from 'node:test';
import assert from 'node:assert/strict';
import WebSocket from 'ws';
import { startServer } from '../src/server.js';
import { Orchestrator } from '../src/orchestrator.js';
import { FigmaLink } from '../src/figmaLink.js';
import { MuseClient } from '../src/muse.js';
import { plugin, sampleDesign } from './fakes/fakeFigma.js';
import { startMuseServer, waitFor } from './fakes/scriptedMuse.js';

const TOKEN = 'secret-token';

function open(url, headers = {}) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url, { headers });
    ws.once('open', () => resolve(ws));
    ws.once('error', reject);
  });
}

/** What ui.html + code.js do inside Figma, over a real socket. */
async function startPlugin(port, design) {
  const ws = await open(`ws://127.0.0.1:${port}/figma`);
  const bridge = plugin.createBridge(design.figma);
  let queue = Promise.resolve();
  ws.on('message', (data) => {
    const msg = JSON.parse(String(data));
    if (msg.type !== 'call') return;
    queue = queue.then(() => bridge.handle(msg.op, msg.args).then(
      (value) => ws.send(JSON.stringify({ type: 'result', rid: msg.rid, ok: true, value })),
      (error) => ws.send(JSON.stringify({ type: 'result', rid: msg.rid, ok: false, error: error.message })),
    ));
  });
  ws.send(JSON.stringify({ type: 'hello', plugin: 'glance-bridge', file: 'Test file', page: 'Page 1' }));
  return ws;
}

/** What the Swift app does: point (after its Cmd+click selected the layer), then send the words. */
async function startApp(port) {
  const ws = await open(`ws://127.0.0.1:${port}/app?token=${TOKEN}`);
  const inbox = [];
  ws.on('message', (data) => inbox.push(JSON.parse(String(data))));
  ws.send(JSON.stringify({ type: 'hello', app: 'glance', version: 'test' }));
  let n = 0;
  return {
    ws,
    inbox,
    of: (type) => inbox.filter((m) => m.type === type),
    lastTasks: () => [...inbox].reverse().find((m) => m.type === 'tasks')?.tasks ?? [],
    send: (msg) => ws.send(JSON.stringify(msg)),
    async say(design, nodeId, text) {
      const id = `cmd${++n}`;
      design.select(nodeId);
      ws.send(JSON.stringify({ type: 'point', id, at: { x: 500 + n, y: 300 }, window: { app: 'Figma', bundleID: 'com.figma.Desktop', bounds: { x: 0, y: 0, w: 1440, h: 900 } } }));
      ws.send(JSON.stringify({ type: 'command', id, text }));
      return waitFor(() => inbox.find((m) => m.type === 'ack' && m.id === id), { what: `ack for ${id}` });
    },
  };
}

async function startAll(museOpts = {}) {
  const design = sampleDesign();
  const museServer = await startMuseServer({ key: 'test-key', ...museOpts });
  const muse = new MuseClient({ key: 'test-key', baseUrl: museServer.url });
  const figma = new FigmaLink({ timeoutMs: 3000 });
  const orchestrator = new Orchestrator({ muse, figma, selectionDelayMs: 30 });
  const server = await startServer({ orchestrator, figma, port: 0, hosts: ['127.0.0.1'], token: TOKEN });
  const pluginSocket = await startPlugin(server.port, design);
  await waitFor(() => figma.connected, { what: 'plugin connected' });
  const app = await startApp(server.port);
  await waitFor(() => app.of('hello').length, { what: 'hello' });
  return {
    design, app, orchestrator, museServer, server,
    async stop() {
      app.ws.close();
      pluginSocket.close();
      await server.close();
      await museServer.close();
    },
  };
}

const fillOf = (node) => {
  const p = node.fills[0];
  const h = (v) => Math.round(v * 255).toString(16).padStart(2, '0').toUpperCase();
  return `#${h(p.color.r)}${h(p.color.g)}${h(p.color.b)}`;
};

test('the whole story over sockets: red button + scrollable banner in parallel, question tooltip, update, undo', async () => {
  const s = await startAll({ delayMs: 40 });
  const { design, app } = s;
  try {
    // 1. Point at the blue button: "turn it red". Then right away at the banner: "make it scrollable".
    const red = await app.say(design, '1:2', 'turn it red');
    const scroll = await app.say(design, '1:4', 'make it scrollable');
    assert.equal(red.kind, 'new');
    assert.equal(scroll.kind, 'new');

    // 2. The banner's worker asks, with a recommendation, at the place the pointer was.
    const ask = await waitFor(() => app.of('ask')[0], { what: 'ask' });
    assert.equal(ask.taskId, scroll.taskId);
    assert.equal(ask.recommended, 'Horizontal');
    assert.deepEqual(ask.anchor, { x: 502, y: 300 });

    // 3. Meanwhile the button is done and reviewed.
    await waitFor(() => app.lastTasks().find((t) => t.id === red.taskId)?.status === 'done', { what: 'red done' });
    assert.equal(fillOf(design.node('1:2')), '#FF3B30');
    const redView = app.lastTasks().find((t) => t.id === red.taskId);
    assert.equal(redView.review.status, 'passed');
    assert.ok(app.of('toast').some((t) => t.taskId === red.taskId && t.kind === 'done'));

    // 4. Point at the button again while the banner still waits: "actually make it green" updates the same task.
    const update = await app.say(design, '1:2', 'actually make it green');
    assert.equal(update.kind, 'update');
    assert.equal(update.taskId, red.taskId);
    await waitFor(() => fillOf(design.node('1:2')) === '#34C759' && app.lastTasks().find((t) => t.id === red.taskId)?.status === 'done', { what: 'green done' });

    // 5. Click "Horizontal" in the tooltip.
    app.send({ type: 'answer', taskId: scroll.taskId, text: 'Horizontal' });
    await waitFor(() => app.of('askDone').some((m) => m.taskId === scroll.taskId), { what: 'tooltip closed' });
    await waitFor(() => app.lastTasks().find((t) => t.id === scroll.taskId)?.status === 'done', { what: 'scroll done' });
    assert.equal(design.node('1:4').overflowDirection, 'HORIZONTAL');

    // 6. Undo the button task from the task panel: back to the original blue.
    app.send({ type: 'control', taskId: red.taskId, action: 'undo' });
    await waitFor(() => app.lastTasks().find((t) => t.id === red.taskId)?.status === 'reverted', { what: 'reverted' });
    assert.equal(fillOf(design.node('1:2')), '#0A84FF');

    // The real Muse client sent the real request shape.
    const workerCall = s.museServer.requests.find((r) => r.body.tools);
    assert.equal(workerCall.body.model, 'muse-spark-1.3');
    assert.equal(workerCall.body.store, false);
    assert.deepEqual(workerCall.body.reasoning, { effort: 'low' });
    assert.ok(workerCall.body.tools.some((t) => t.name === 'ask_user' && t.type === 'function'));
  } finally {
    await s.stop();
  }
});

test('edit and pause from the task panel work over the socket', async () => {
  const s = await startAll({ delayMs: 80 });
  const { design, app } = s;
  try {
    const a = await app.say(design, '1:2', 'turn it red');
    app.send({ type: 'control', taskId: a.taskId, action: 'pause' });
    await waitFor(() => app.lastTasks().find((t) => t.id === a.taskId)?.status === 'paused', { what: 'paused' });
    await new Promise((r) => setTimeout(r, 250));
    assert.equal(fillOf(design.node('1:2')), '#0A84FF');
    app.send({ type: 'edit', taskId: a.taskId, text: 'make it purple' });
    await waitFor(() => app.lastTasks().find((t) => t.id === a.taskId)?.status === 'done', { what: 'done', timeout: 5000 });
    assert.equal(fillOf(design.node('1:2')), '#AF52DE');
  } finally {
    await s.stop();
  }
});

test('web pages cannot connect: wrong origin, missing token', async () => {
  const s = await startAll();
  try {
    const port = s.server.port;
    await assert.rejects(open(`ws://127.0.0.1:${port}/figma`, { Origin: 'https://evil.example' }), /403/);
    await assert.rejects(open(`ws://127.0.0.1:${port}/app`), /403/);
    await assert.rejects(open(`ws://127.0.0.1:${port}/app?token=${TOKEN}`, { Origin: 'https://evil.example' }), /403/);
    const figmaOk = await open(`ws://127.0.0.1:${port}/figma`, { Origin: 'https://www.figma.com' });
    figmaOk.close();
  } finally {
    await s.stop();
  }
});
