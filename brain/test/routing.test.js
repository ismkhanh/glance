import test from 'node:test';
import assert from 'node:assert/strict';
import { matchOption, route, REOPEN_WINDOW_MS } from '../src/routing.js';

const scrollQuestion = { question: 'Which way should it scroll?', options: ['Horizontal', 'Vertical'], recommended: 'Horizontal' };

test('matchOption understands the usual ways of answering', () => {
  assert.equal(matchOption('horizontal', scrollQuestion), 'Horizontal');
  assert.equal(matchOption('Make it vertical.', scrollQuestion), 'Vertical');
  assert.equal(matchOption('yes', scrollQuestion), 'Horizontal');                  // yes = the recommendation
  assert.equal(matchOption('go with your pick', scrollQuestion), 'Horizontal');
  assert.equal(matchOption('the second', scrollQuestion), 'Vertical');
  assert.equal(matchOption('2', scrollQuestion), 'Vertical');
  assert.equal(matchOption('the blue one', scrollQuestion), null);                  // "one" is not "first"
  assert.equal(matchOption('both horizontal and vertical', scrollQuestion), null);  // fits two options
  assert.equal(matchOption('horizontal', { options: ['Horizontal scroll', 'Vertical scroll'] }), 'Horizontal scroll');
});

const now = 1_000_000;
function task(id, status, targetId, extra = {}) {
  return { id, status, target: targetId ? { id: targetId } : null, updatedAt: now - 1000, question: null, ...extra };
}

test('pointing at a tooltip answers that task', () => {
  const tasks = [task('t1', 'asking', '1:4', { question: scrollQuestion })];
  assert.deepEqual(route({ text: 'vertical', answerTo: 't1', target: null, tasks, now }), { kind: 'answer', taskId: 't1' });
});

test('pointing at a layer whose task is asking: an answer answers, a new request updates', () => {
  const tasks = [task('t1', 'asking', '1:4', { question: scrollQuestion })];
  assert.equal(route({ text: 'horizontal', target: { id: '1:4' }, tasks, now }).kind, 'answer');
  assert.equal(route({ text: 'ok', target: { id: '1:4' }, tasks, now }).kind, 'answer');
  assert.deepEqual(route({ text: 'and make it red as well', target: { id: '1:4' }, tasks, now }), { kind: 'update', taskId: 't1' });
});

test('pointing at a layer whose task is still running merges the words into it', () => {
  const tasks = [task('t1', 'running', '1:2'), task('t2', 'running', '1:4')];
  assert.deepEqual(route({ text: 'actually make it blue', target: { id: '1:2' }, tasks, now }), { kind: 'update', taskId: 't1' });
});

test('a task that finished a minute ago is reopened; one from long ago is not', () => {
  const recent = [task('t1', 'done', '1:2', { updatedAt: now - 60_000 })];
  assert.deepEqual(route({ text: 'darker', target: { id: '1:2' }, tasks: recent, now }), { kind: 'update', taskId: 't1' });
  const old = [task('t1', 'done', '1:2', { updatedAt: now - REOPEN_WINDOW_MS - 1 })];
  assert.equal(route({ text: 'darker', target: { id: '1:2' }, tasks: old, now }).kind, 'new');
  const undone = [task('t1', 'reverted', '1:2')];
  assert.equal(route({ text: 'darker', target: { id: '1:2' }, tasks: undone, now }).kind, 'new');
});

test('a different layer is a new task, even while others run', () => {
  const tasks = [task('t1', 'running', '1:2')];
  assert.equal(route({ text: 'make it scrollable', target: { id: '1:4' }, tasks, now }).kind, 'new');
});

test('pointing at nothing: an answer goes to the one open question, anything else is new', () => {
  const tasks = [task('t1', 'asking', '1:4', { question: scrollQuestion }), task('t2', 'running', '1:2')];
  assert.deepEqual(route({ text: 'vertical please', target: null, tasks, now }), { kind: 'answer', taskId: 't1' });
  assert.equal(route({ text: 'add a footer', target: null, tasks, now }).kind, 'new');
  const two = [...tasks, task('t3', 'asking', '1:7', { question: scrollQuestion })];
  assert.equal(route({ text: 'vertical', target: null, tasks: two, now }).kind, 'new');   // which one? not clear
});

test('"undo that" and its variants are an undo, but a new request that starts with a similar word is not', async () => {
  const { isUndo } = await import('../src/routing.js');
  for (const t of ['undo', 'Undo that.', 'undo it please', 'put it back', 'okay change it back', 'revert', 'hmm undo that again']) {
    assert.ok(isUndo(t), t);
  }
  for (const t of ['change it back to blue', 'undo the rounded corners and make it red', 'go back to the old title text', 'make it red']) {
    assert.ok(!isUndo(t), t);
  }
});

test('undo goes to the task on the layer pointed at, else to the one changed last', () => {
  const now = 1_000_000;
  const tasks = [
    { id: 't1', status: 'done', target: { id: 'A' }, updatedAt: now - 5000 },
    { id: 't2', status: 'done', target: { id: 'B' }, updatedAt: now - 1000 },
    { id: 't3', status: 'reverted', target: { id: 'C' }, updatedAt: now - 10 },
  ];
  assert.deepEqual(route({ text: 'undo that', target: { id: 'A' }, tasks, now }), { kind: 'undo', taskId: 't1' });
  assert.deepEqual(route({ text: 'undo that', target: null, tasks, now }), { kind: 'undo', taskId: 't2' });
  assert.deepEqual(route({ text: 'undo', target: null, tasks: [], now }), { kind: 'undo' });
});
