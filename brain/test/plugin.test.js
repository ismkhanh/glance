// The real Figma plugin code (figma-plugin/code.js) on a fake Figma document.
import test from 'node:test';
import assert from 'node:assert/strict';
import { plugin, sampleDesign } from './fakes/fakeFigma.js';

function setup() {
  const design = sampleDesign();
  const bridge = plugin.createBridge(design.figma);
  return { design, bridge, call: (op, args) => bridge.handle(op, args) };
}

test('hex colors convert both ways', () => {
  assert.equal(plugin.rgbToHex(plugin.hexToRgb('#ff3b30')), '#FF3B30');
  assert.equal(plugin.rgbToHex(plugin.hexToRgb('#0af')), '#00AAFF');
  assert.throws(() => plugin.hexToRgb('red'), /Color must look like/);
});

test('getNode describes a layer with its fill, corners, children and parent', async () => {
  const { call } = setup();
  const d = await call('getNode', { id: '1:2' });
  assert.equal(d.name, 'Buy button');
  assert.equal(d.fill, '#0A84FF');
  assert.equal(d.cornerRadius, 8);
  assert.equal(d.childCount, 1);
  assert.equal(d.children[0].name, 'Label');
  assert.deepEqual(d.parent, { id: '1:1', name: 'Home', type: 'FRAME' });
});

test('the banner hints horizontal scrolling because its cards spill out sideways', async () => {
  const { call } = setup();
  const banner = await call('getNode', { id: '1:4' });
  assert.equal(banner.hints.contentOverflow, 'HORIZONTAL');
  assert.equal(banner.hints.recommendedScroll, 'HORIZONTAL');
  const list = await call('getNode', { id: '1:7' });
  assert.equal(list.hints.recommendedScroll, 'VERTICAL');
});

test('setFill replaces the solid fill and makes one undo step', async () => {
  const { call, design } = setup();
  const d = await call('setFill', { id: '1:2', color: '#FF3B30' });
  assert.equal(d.fill, '#FF3B30');
  assert.equal(design.node('1:2').fills.length, 1);
  assert.equal(design.figma.undoSteps, 1);
});

test('setFill on a group explains that groups have no fill', async () => {
  const { call } = setup();
  await assert.rejects(call('setFill', { id: '1:6', color: '#FF3B30' }), /has no fill/);
});

test('setScroll turns on overflow scrolling and clipping; on text it refuses', async () => {
  const { call, design } = setup();
  const d = await call('setScroll', { id: '1:4', direction: 'horizontal' });
  assert.equal(d.overflowDirection, 'HORIZONTAL');
  assert.equal(design.node('1:4').clipsContent, true);
  assert.equal(d.note, undefined);
  const fits = await call('setScroll', { id: '1:7', direction: 'VERTICAL' });
  assert.match(fits.note, /content fits inside/);
  await assert.rejects(call('setScroll', { id: '1:5', direction: 'VERTICAL' }), /Only frames can scroll/);
  await assert.rejects(call('setScroll', { id: '1:4', direction: 'DIAGONAL' }), /Direction must be/);
});

test('setText loads the font first (Figma refuses otherwise)', async () => {
  const { call, design } = setup();
  const d = await call('setText', { id: '1:3', text: 'Buy today' });
  assert.equal(d.text, 'Buy today');
  assert.equal(design.node('1:3').characters, 'Buy today');
});

test('snapshot + restore puts every changed property back', async () => {
  const { call } = setup();
  const before = await call('getNode', { id: '1:4' });
  const snap = await call('snapshot', { id: '1:4' });
  await call('setFill', { id: '1:4', color: '#000000' });
  await call('setScroll', { id: '1:4', direction: 'HORIZONTAL' });
  await call('setAutoLayout', { id: '1:4', direction: 'HORIZONTAL', spacing: 12, padding: 8 });
  await call('setCornerRadius', { id: '1:4', radius: 20 });
  const changed = await call('getNode', { id: '1:4' });
  assert.notEqual(changed.fill, before.fill);
  await call('restore', { snapshot: snap });
  const after = await call('getNode', { id: '1:4' });
  for (const key of ['fill', 'overflowDirection', 'clipsContent', 'layoutMode', 'cornerRadius', 'width', 'height']) {
    assert.deepEqual(after[key], before[key], key);
  }
});

test('snapshot + restore works for text too', async () => {
  const { call } = setup();
  const snap = await call('snapshot', { id: '1:5' });
  await call('setText', { id: '1:5', text: 'Changed' });
  await call('setFontSize', { id: '1:5', size: 40 });
  await call('restore', { snapshot: snap });
  const after = await call('getNode', { id: '1:5' });
  assert.equal(after.text, 'Hello');
  assert.equal(after.fontSize, 28);
});

test('getSelection and findNodes', async () => {
  const { call, design } = setup();
  design.select('1:2');
  const sel = await call('getSelection');
  assert.equal(sel.length, 1);
  assert.equal(sel[0].id, '1:2');
  const found = await call('findNodes', { query: 'card' });
  assert.equal(found.length, 4);
});

test('unknown operations and layers are refused clearly', async () => {
  const { call } = setup();
  await assert.rejects(call('deleteEverything', {}), /Unknown operation/);
  await assert.rejects(call('getNode', { id: '9:9' }), /No layer with id 9:9/);
});
