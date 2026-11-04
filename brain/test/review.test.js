import test from 'node:test';
import assert from 'node:assert/strict';
import { looksLike, lastColorWord, ruleReview, review, diff } from '../src/review.js';

test('color words match generously, but not across hues', () => {
  for (const hex of ['#FF3B30', '#FF0000', '#E5484D', '#D70015']) assert.ok(looksLike(hex, 'red'), hex);
  assert.ok(!looksLike('#0A84FF', 'red'));
  assert.ok(looksLike('#0A84FF', 'blue'));
  assert.ok(looksLike('#34C759', 'green'));
  assert.ok(looksLike('#000000', 'black'));
  assert.ok(looksLike('#FFFFFF', 'white'));
  assert.ok(looksLike('#8E8E93', 'grey'));
  assert.ok(!looksLike('#8E8E93', 'blue'));
});

test('the newest color word wins', () => {
  assert.equal(lastColorWord('turn it red. actually make it blue'), 'blue');
  assert.equal(lastColorWord('make it scrollable'), null);
});

const before = { '1:2': { id: '1:2', name: 'Buy button', fill: '#0A84FF', cornerRadius: 8, width: 160, height: 48 } };

test('passes when the change landed and matches the words', () => {
  const after = { '1:2': { ...before['1:2'], fill: '#FF3B30' } };
  const r = ruleReview({ intent: 'turn it red', writes: [{ id: '1:2', prop: 'fill', value: '#FF3B30' }], before, after });
  assert.equal(r.status, 'passed');
  assert.equal(r.retry, false);
});

test('fails when the color does not match the words, and asks for a retry', () => {
  const after = { '1:2': { ...before['1:2'], fill: '#0A84FF' } };
  const r = ruleReview({ intent: 'turn it red', writes: [{ id: '1:2', prop: 'fill', value: '#0A84FF' }], before, after });
  assert.equal(r.status, 'failed');
  assert.match(r.notes[0], /asked for red/);
  assert.equal(r.retry, true);
});

test('fails when a change did not land in Figma', () => {
  const after = { '1:2': { ...before['1:2'] } };
  const r = ruleReview({ intent: 'set the fill', writes: [{ id: '1:2', prop: 'fill', value: '#FF3B30' }], before, after });
  assert.equal(r.status, 'failed');
  assert.match(r.notes[0], /fill is "#0A84FF", expected "#FF3B30"/);
});

test('scroll direction must match the words or the answer', () => {
  const b = { '1:4': { id: '1:4', name: 'Promo banner', overflowDirection: 'NONE', clipsContent: false } };
  const vertical = { '1:4': { ...b['1:4'], overflowDirection: 'VERTICAL', clipsContent: true } };
  const writes = [{ id: '1:4', prop: 'overflowDirection', value: 'VERTICAL' }];
  assert.equal(ruleReview({ intent: 'make it scrollable. Horizontal', writes, before: b, after: vertical }).status, 'failed');
  const ok = ruleReview({ intent: 'make it scrollable. Vertical', writes, before: b, after: vertical });
  assert.equal(ok.status, 'passed', ok.notes.join());   // clipsContent is an allowed side effect of scrolling
});

test('other properties that changed are reported as a warning', () => {
  const after = { '1:2': { ...before['1:2'], fill: '#FF3B30', cornerRadius: 0 } };
  const r = ruleReview({ intent: 'turn it red', writes: [{ id: '1:2', prop: 'fill', value: '#FF3B30' }], before, after });
  assert.equal(r.status, 'warning');
  assert.match(r.notes[0], /also changed cornerRadius: 8 → 0/);
});

test('a question with no change passes', () => {
  const r = ruleReview({ intent: 'what font is this?', writes: [], before: {}, after: {} });
  assert.equal(r.status, 'passed');
});

test('Muse saying no asks for one retry but is only a warning on its own', async () => {
  const after = { '1:2': { ...before['1:2'], fill: '#FF3B30' } };
  const muse = { available: true, respond: async () => ({ output_text: '{"pass": false, "reason": "wrong layer"}' }) };
  const r = await review({ muse, intent: 'turn it red', writes: [{ id: '1:2', prop: 'fill', value: '#FF3B30' }], before, after });
  assert.equal(r.status, 'warning');
  assert.equal(r.retry, true);
  assert.match(r.notes.at(-1), /Reviewer: wrong layer/);
});

test('without Muse, the rules decide alone', async () => {
  const after = { '1:2': { ...before['1:2'], fill: '#FF3B30' } };
  const r = await review({ muse: { available: false }, intent: 'turn it red', writes: [{ id: '1:2', prop: 'fill', value: '#FF3B30' }], before, after });
  assert.equal(r.status, 'passed');
});

test('diff lists only real changes', () => {
  assert.deepEqual(diff({ fill: '#ff3b30', width: 10 }, { fill: '#FF3B30', width: 10.004 }), []);
  assert.equal(diff({ fill: '#FF3B30' }, { fill: '#000000' }).length, 1);
});
