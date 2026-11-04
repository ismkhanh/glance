// The orchestrator: every spoken command becomes a task (or updates one, or answers one).
// Tasks run in parallel, each with its own worker. Before a task is "done", the reviewer checks it.
//
//   point ──► (Figma selects the layer under the pointer) ──► target
//   command ──► route: answer | update | new ──► worker pass ──► reviewer ──► done / retry once / failed
//
// The user can pause, resume, edit, cancel or undo any task at any time; a task's changes are saved
// before the first edit of each layer, so cancel/undo/edit put the layer back exactly.
import { EventEmitter } from 'node:events';
import { route, matchOption, ACTIVE, FINISHED } from './routing.js';
import { runWorkerPass } from './worker.js';
import { WRITE_TOOLS, READ_TOOLS, isWrite, isRead } from './tools.js';
import { review } from './review.js';

export class Stop extends Error {
  constructor(why = 'stopped') {
    super(why);
    this.name = 'Stop';
  }
}

const MAX_PASSES = 6;
const MAX_TASKS = 200;          // finished tasks beyond this are forgotten, oldest first
/** Layers with no children of their own. Pointing at one inside a frame often means the frame (a button's label). */
const LEAVES = new Set(['TEXT', 'RECTANGLE', 'ELLIPSE', 'VECTOR', 'LINE', 'STAR', 'POLYGON', 'BOOLEAN_OPERATION']);

/** What one task cost: Muse calls, time and tokens, tools used, questions, reviewer retries. */
export function newMetrics() {
  return {
    museCalls: 0, museMs: 0, museErrors: 0, inputTokens: 0, outputTokens: 0, reasoningTokens: 0,
    imageCalls: 0, imageMs: 0, toolCalls: 0, toolErrors: 0, tools: {}, asks: 0, passes: 0, reviewRetries: 0,
  };
}

/** The shared Muse client, seen through one task: every call it makes is counted in its metrics. */
export function metered(muse, m) {
  const timed = async (kind, run) => {
    const start = performance.now();
    try {
      return await run();
    } catch (error) {
      if (error.name !== 'AbortError') m.museErrors += 1;
      throw error;
    } finally {
      m[`${kind}Calls`] += 1;
      m[`${kind}Ms`] += Math.round(performance.now() - start);
    }
  };
  return {
    get available() {
      return muse.available;
    },
    respond: (body, opts) => timed('muse', async () => {
      const response = await muse.respond(body, opts);
      const u = response?.usage || {};
      m.inputTokens += u.input_tokens || 0;
      m.outputTokens += u.output_tokens || 0;
      m.reasoningTokens += u.output_tokens_details?.reasoning_tokens || 0;
      return response;
    }),
    image: (prompt, opts) => timed('image', () => muse.image(prompt, opts)),
  };
}

/** "3 Muse calls, 4.2 s, 2,140 tokens" */
export function costLine(m) {
  const tokens = m.inputTokens + m.outputTokens;
  const parts = [`${m.museCalls} Muse call${m.museCalls === 1 ? '' : 's'}`, `${(m.museMs / 1000).toFixed(1)} s`];
  if (tokens) parts.push(`${tokens.toLocaleString('en-US')} tokens`);
  if (m.imageCalls) parts.push(`${m.imageCalls} image${m.imageCalls === 1 ? '' : 's'} in ${(m.imageMs / 1000).toFixed(1)} s`);
  return parts.join(', ');
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function titleOf(text) {
  const t = String(text).trim().replace(/\s+/g, ' ');
  return t.length > 60 ? `${t.slice(0, 57)}…` : t;
}

function compact(value) {
  const s = JSON.stringify(value);
  return s.length > 2500 ? `${s.slice(0, 2500)}…` : s;
}

export class Orchestrator extends EventEmitter {
  constructor({ muse, figma, now = () => Date.now(), selectionDelayMs = 250, useMuseReview = true, log = () => {} }) {
    super();
    this.muse = muse;
    this.figma = figma;
    this.now = now;
    this.selectionDelayMs = selectionDelayMs;
    this.useMuseReview = useMuseReview;
    this.log = log;
    this.tasks = new Map();
    this.pointings = new Map();
    this.nextId = 1;
    this.emitScheduled = false;
  }

  // ───────────────────────────── inputs from the app

  /** Talk key down. For Figma, the app has just Cmd+clicked, so the layer under the pointer is now selected. */
  point({ id, at = null, window = null }) {
    const isFigma = !window || /figma/i.test(`${window.bundleID || ''} ${window.app || ''}`);
    const target = isFigma && this.figma.connected
      ? sleep(this.selectionDelayMs)
        .then(() => this.figma.call('getSelection'))
        .then((nodes) => (Array.isArray(nodes) && nodes.length ? { id: nodes[0].id, name: nodes[0].name, type: nodes[0].type } : null))
        .catch(() => null)
      : Promise.resolve(null);
    this.pointings.set(id, { at, window, target });
    if (this.pointings.size > 100) this.pointings.delete(this.pointings.keys().next().value);
  }

  /** Talk key up (or typed). Returns the ack sent back to the app. */
  async command({ id, text, answerTo }) {
    const said = String(text || '').trim();
    if (!said) return { type: 'ack', id, kind: 'none', text: 'I did not hear anything.' };
    const pointing = this.pointings.get(id);
    const target = pointing ? await pointing.target : null;
    const decision = route({ text: said, answerTo, target, tasks: [...this.tasks.values()], now: this.now() });

    if (decision.kind === 'undo') {
      const task = this.tasks.get(decision.taskId);
      if (!task) return { type: 'ack', id, kind: 'none', text: 'Nothing to undo.' };
      await this.control(task.id, ACTIVE.has(task.status) ? 'cancel' : 'undo');
      return { type: 'ack', id, taskId: task.id, kind: 'undo', text: `Undone: "${task.title}"` };
    }
    if (decision.kind === 'answer' && this.answer(decision.taskId, said)) {
      return { type: 'ack', id, taskId: decision.taskId, kind: 'answer', text: `Answer for "${this.tasks.get(decision.taskId).title}"` };
    }
    if (decision.kind === 'update') {
      const task = this.tasks.get(decision.taskId);
      this.update(task, said);
      return { type: 'ack', id, taskId: task.id, kind: 'update', text: `Added to "${task.title}"` };
    }
    if (!this.figma.connected) {
      this.emit('toast', { text: 'Open the Glance Bridge plugin in Figma first (Plugins > Development > Glance Bridge).', kind: 'error', anchor: pointing?.at });
      return { type: 'ack', id, kind: 'none', text: 'Figma is not connected.' };
    }
    if (!this.muse.available) {
      this.emit('toast', { text: 'No Muse key: add MUSE_API_KEY to the .env file in the Glance folder.', kind: 'error', anchor: pointing?.at });
      return { type: 'ack', id, kind: 'none', text: 'Muse is not set up.' };
    }
    const task = this.create(said, target, pointing?.at ?? null);
    return { type: 'ack', id, taskId: task.id, kind: 'new', text: `Working on "${task.title}"` };
  }

  /** An answer to a task's question (tooltip click, or words routed here). */
  answer(taskId, text) {
    const task = this.tasks.get(taskId);
    if (!task?.askWaiter) return false;
    const picked = matchOption(text, task.question) || String(text).trim();
    const waiter = task.askWaiter;
    task.askWaiter = null;
    task.question = null;
    this.emit('askDone', { taskId });
    if (!task.paused) this.set(task, 'running', `You said: ${picked}`);
    waiter.resolve(picked);
    return true;
  }

  async control(taskId, action) {
    const task = this.tasks.get(taskId);
    if (!task) return false;
    switch (action) {
      case 'pause':
        if (!ACTIVE.has(task.status) || task.paused) return false;
        task.paused = true;
        task.statusBeforePause = task.status;
        this.set(task, 'paused', 'Paused');
        return true;
      case 'resume': {
        if (!task.paused) return false;
        task.paused = false;
        const waiters = task.pauseWaiters.splice(0);
        if (task.question) {
          this.set(task, 'asking', task.question.question);
          this.emit('ask', this.askEvent(task));
        } else {
          this.set(task, task.statusBeforePause === 'verifying' ? 'verifying' : 'running', 'Resumed');
        }
        for (const w of waiters) w();
        return true;
      }
      case 'cancel':
        if (ACTIVE.has(task.status)) {
          this.stopWorker(task);
          await this.revert(task);
          this.set(task, 'cancelled', 'Cancelled; the layer is back as it was.');
          return true;
        }
        return this.control(taskId, 'undo');
      case 'undo':
        if (!FINISHED.has(task.status)) return false;
        await this.revert(task);
        this.set(task, 'reverted', 'Undone; the layer is back as it was.');
        this.toast(task, 'info', `Undone: ${task.title}`);
        return true;
      case 'retry':
        if (!['failed', 'cancelled', 'reverted'].includes(task.status)) return false;
        await this.revert(task);
        this.resetWork(task);
        this.run(task);
        return true;
      default:
        return false;
    }
  }

  /** New words for a task, from the task panel. Undoes what it did so far and starts again. */
  async edit(taskId, text) {
    const task = this.tasks.get(taskId);
    const said = String(text || '').trim();
    if (!task || !said) return false;
    this.stopWorker(task);
    await this.revert(task);
    task.instruction = said;
    task.title = titleOf(said);
    task.updates = [];
    task.answers = [];
    this.resetWork(task);
    this.run(task);
    return true;
  }

  views() {
    return [...this.tasks.values()].reverse().slice(0, 40).map((t) => ({
      id: t.id,
      title: t.title,
      instruction: t.instruction,
      target: t.target,
      status: t.status,
      detail: t.detail,
      question: t.question,
      result: t.result,
      review: t.review,
      updates: t.updates,
      metrics: t.metrics,
      createdAt: t.createdAt,
      updatedAt: t.updatedAt,
    }));
  }

  // ───────────────────────────── task life

  create(text, target, anchor) {
    const task = {
      id: `t${this.nextId++}`,
      title: titleOf(text),
      instruction: text,
      target,
      anchor,
      status: 'queued',
      detail: '',
      question: null,
      result: null,
      review: null,
      updates: [],
      answers: [],
      createdAt: this.now(),
      updatedAt: this.now(),
      history: [],
      feedback: null,
      seenUpdates: 0,
      writes: [],
      before: {},
      snapshots: new Map(),
      scopeOk: new Set(),
      gen: 0,
      controller: null,
      paused: false,
      statusBeforePause: null,
      pauseWaiters: [],
      askWaiter: null,
      inflight: Promise.resolve(),
      metrics: newMetrics(),
    };
    task.muse = metered(this.muse, task.metrics);
    this.tasks.set(task.id, task);
    this.forgetOldTasks();
    this.log(`[${task.id}] new: "${text}" on ${target ? `${target.type} "${target.name}"` : 'no layer'}`);
    this.run(task);
    return task;
  }

  /** Keeps memory bounded in a long session: the oldest finished tasks go first; running ones always stay. */
  forgetOldTasks() {
    for (const [id, t] of this.tasks) {
      if (this.tasks.size <= MAX_TASKS) return;
      if (!ACTIVE.has(t.status) && t.status !== 'queued') this.tasks.delete(id);
    }
  }

  update(task, text) {
    task.updates.push(text);
    this.log(`[${task.id}] update: "${text}"`);
    if (task.askWaiter) {
      // The user moved on instead of answering: the worker gets the new words instead.
      const waiter = task.askWaiter;
      task.askWaiter = null;
      const q = task.question;
      task.question = null;
      this.emit('askDone', { taskId: task.id });
      task.answers.push({ question: q.question, answer: `(no answer; the user said instead: "${text}")` });
      if (!task.paused) this.set(task, 'running', `Update: ${text}`);
      waiter.resolve(`(no answer; the user said instead: "${text}")`);
      return;
    }
    if (ACTIVE.has(task.status)) {
      // The worker reads updates at its next step; if its pass already ended, run() starts another.
      this.set(task, task.status, `Update: ${text}`);
      return;
    }
    // Finished: run again on top of what is there (undo still goes back to the very first state).
    task.feedback = null;
    this.run(task);
  }

  resetWork(task) {
    task.scope = null;
    task.history = [];
    task.feedback = null;
    task.review = null;
    task.result = null;
    task.seenUpdates = 0;
    task.writes = [];
    task.before = {};
    task.snapshots = new Map();
    task.scopeOk = new Set();
  }

  async run(task) {
    const gen = ++task.gen;
    task.controller = new AbortController();
    task.paused = false;
    this.set(task, 'running', 'Starting…');
    const ctx = this.contextFor(task, gen);
    try {
      let retried = false;
      for (let pass = 0; pass < MAX_PASSES; pass++) {
        if (task.status !== 'running' && !task.paused) this.set(task, 'running');
        task.metrics.passes += 1;
        const { summary } = await runWorkerPass(task, ctx);
        await ctx.checkpoint();
        if (task.updates.length > task.seenUpdates) continue;          // the user said more during this pass

        this.set(task, 'verifying', 'Checking the result…');
        const verdict = await this.verify(task, summary);
        await ctx.checkpoint();
        if (task.updates.length > task.seenUpdates) continue;
        if (verdict.retry && !retried) {
          retried = true;
          task.metrics.reviewRetries += 1;
          task.feedback = verdict.notes.join(' ');
          this.log(`[${task.id}] reviewer: ${task.feedback}`);
          this.set(task, 'running', 'Fixing what the reviewer found…');
          continue;
        }
        task.feedback = null;
        task.review = { status: verdict.status, notes: verdict.notes };
        task.result = summary;
        if (verdict.status === 'failed') {
          this.set(task, 'failed', verdict.notes[0] || 'The reviewer did not accept the result.');
          this.toast(task, 'error', `✗ ${task.title}: ${verdict.notes[0] || 'did not work'}`);
        } else {
          this.set(task, 'done', summary);
          this.toast(task, 'done', `${verdict.status === 'passed' ? '✓' : '⚠︎'} ${task.title}: ${summary}`);
        }
        this.log(`[${task.id}] ${task.status} (review ${verdict.status}) ${verdict.notes.join(' ')} · ${costLine(task.metrics)}`.replace('  ·', ' ·'));
        return;
      }
      this.set(task, 'failed', 'Too many changes while working; try again.');
    } catch (error) {
      if (task.gen !== gen || error instanceof Stop || error.name === 'AbortError') return;   // replaced or stopped
      this.set(task, 'failed', error.message);
      this.toast(task, 'error', `✗ ${task.title}: ${error.message}`);
      this.log(`[${task.id}] failed: ${error.message} · ${costLine(task.metrics)}`);
    }
  }

  contextFor(task, gen) {
    const live = () => {
      if (task.gen !== gen) throw new Stop('replaced');
    };
    return {
      muse: task.muse,
      get signal() {
        return task.controller.signal;
      },
      checkpoint: async () => {
        live();
        while (task.paused) {
          await new Promise((resolve) => task.pauseWaiters.push(resolve));
          live();
        }
      },
      ask: (q) => {
        live();
        return this.ask(task, q);
      },
      tool: async (name, args) => {
        live();
        const call = this.tool(task, gen, name, args);
        task.inflight = call.catch(() => {});
        return call;
      },
      facts: async () => {
        const [facts, scope] = await Promise.all([this.figma.call('getNode', { id: task.target.id }), this.scopeOf(task)]);
        return scope.parent ? { ...facts, parentYouMayChange: scope.parent } : facts;
      },
      step: (text) => {
        if (task.gen !== gen || task.paused) return;
        this.set(task, 'running', text);
      },
    };
  }

  ask(task, q) {
    task.metrics.asks += 1;
    const options = q.options.length >= 2 ? q.options : ['Yes', 'No'];
    let recommended = q.recommended;
    if (recommended && !options.includes(recommended)) recommended = matchOption(recommended, { options }) || undefined;
    task.question = { question: q.question, options, recommended, reason: q.reason };
    this.set(task, task.paused ? 'paused' : 'asking', q.question);
    this.emit('ask', this.askEvent(task));
    return new Promise((resolve, reject) => {
      task.askWaiter = { resolve, reject };
    });
  }

  askEvent(task) {
    return { taskId: task.id, ...task.question, anchor: task.anchor, title: task.title };
  }

  async tool(task, gen, name, args) {
    const m = task.metrics;
    m.toolCalls += 1;
    m.tools[name] = (m.tools[name] || 0) + 1;
    const result = await this.runTool(task, gen, name, args);
    if (!result.ok) m.toolErrors += 1;
    return result;
  }

  async runTool(task, gen, name, args) {
    try {
      if (isWrite(name)) {
        const spec = WRITE_TOOLS[name];
        const pluginArgs = spec.args(args || {});
        const id = String(pluginArgs.id || '');
        if (!id) throw new Error('node_id is missing.');
        await this.checkScope(task, id);
        if (!task.snapshots.has(id)) {
          const snap = await this.figma.call('snapshot', { id });
          const facts = await this.figma.call('getNode', { id });
          if (task.gen !== gen) throw new Stop('replaced');
          task.snapshots.set(id, snap);
          task.before[id] = facts;
        }
        if (task.gen !== gen) throw new Stop('replaced');     // stopped while saving: do not change anything
        const ready = spec.prepare
          ? await spec.prepare(pluginArgs, {
            muse: task.muse,
            signal: task.controller?.signal,
            step: (text) => {
              if (task.gen === gen && !task.paused) this.set(task, 'running', text);
            },
          })
          : pluginArgs;
        if (task.gen !== gen) throw new Stop('replaced');     // stopped while painting: do not change anything
        const value = await this.figma.call(spec.op, ready);
        for (const [prop, expected] of spec.expect(args || {})) task.writes.push({ id, prop, value: expected });
        return { ok: true, text: compact(value) };
      }
      if (isRead(name)) {
        const spec = READ_TOOLS[name];
        return { ok: true, text: compact(await this.figma.call(spec.op, spec.args(args || {}))) };
      }
      return { ok: false, text: `Unknown tool "${name}".` };
    } catch (error) {
      if (error instanceof Stop) throw error;
      return { ok: false, text: `Could not: ${error.message}` };
    }
  }

  /**
   * What a task may change: the layer you pointed at and its children. When the pointer was on a text or shape
   * inside a frame (Figma selects the deepest layer, so a button's label rather than the button), that frame and
   * its children too, but never a whole screen (a frame right on the page).
   */
  scopeOf(task) {
    if (!task.scope) {
      task.scope = (async () => {
        const roots = [task.target.id];
        if (!LEAVES.has(task.target.type)) return { roots, parent: null };
        try {
          const node = await this.figma.call('getNode', { id: task.target.id });
          const parent = node?.parent && await this.figma.call('getNode', { id: node.parent.id });
          // A frame right on the page, or in a section, is a screen: never that.
          if (!parent?.parent || parent.parent.type === 'SECTION') return { roots, parent: null };
          roots.push(parent.id);
          return { roots, parent: { id: parent.id, name: parent.name, type: parent.type } };
        } catch {
          return { roots, parent: null };
        }
      })();
    }
    return task.scope;
  }

  /** A worker may change what scopeOf allows, nothing else. */
  async checkScope(task, id) {
    if (!task.target || task.scopeOk.has(id)) return;
    const { roots, parent } = await this.scopeOf(task);
    if (roots.includes(id)) return;
    let node = await this.figma.call('getNode', { id });
    for (let i = 0; i < 15 && node?.parent; i++) {
      if (roots.includes(node.parent.id)) {
        task.scopeOk.add(id);
        return;
      }
      node = await this.figma.call('getNode', { id: node.parent.id });
    }
    const allowed = `"${task.target.name}"${parent ? ` or "${parent.name}"` : ''}`;
    throw new Error(`layer ${id} is outside the layer you pointed at. Only ${allowed} and the layers inside may change: `
      + 'use one of those, or finish and say what the user should point at.');
  }

  intent(task) {
    return [task.instruction, ...task.updates, ...task.answers.map((a) => a.answer)].join('. ');
  }

  async verify(task, summary) {
    const after = {};
    for (const id of Object.keys(task.before)) {
      try {
        after[id] = await this.figma.call('getNode', { id });
      } catch {
        after[id] = null;
      }
    }
    return review({
      muse: task.muse,
      intent: this.intent(task),
      summary,
      writes: task.writes,
      before: task.before,
      after,
      signal: task.controller.signal,
      useMuse: this.useMuseReview,
    });
  }

  stopWorker(task) {
    task.gen++;
    task.controller?.abort();
    if (task.askWaiter) {
      task.askWaiter.reject(new Stop('stopped'));
      task.askWaiter = null;
      task.question = null;
      this.emit('askDone', { taskId: task.id });
    }
    task.paused = false;
    for (const w of task.pauseWaiters.splice(0)) w();
  }

  /** Puts every layer the task changed back to how it was before the task touched it. */
  async revert(task) {
    await task.inflight;                 // a change already on its way to Figma lands first, then is undone
    const snaps = [...task.snapshots.values()].reverse();
    for (const snapshot of snaps) {
      try {
        await this.figma.call('restore', { snapshot });
      } catch (error) {
        this.log(`[${task.id}] could not restore ${snapshot.id}: ${error.message}`);
      }
    }
    task.snapshots = new Map();
    task.before = {};
    task.writes = [];
    task.scopeOk = new Set();
  }

  // ───────────────────────────── events

  set(task, status, detail) {
    task.status = status;
    if (detail !== undefined) task.detail = detail;
    task.updatedAt = this.now();
    this.changed();
  }

  changed() {
    if (this.emitScheduled) return;
    this.emitScheduled = true;
    setImmediate(() => {
      this.emitScheduled = false;
      this.emit('tasks', this.views());
    });
  }

  toast(task, kind, text) {
    this.emit('toast', { taskId: task.id, text, kind, anchor: task.anchor });
  }
}
