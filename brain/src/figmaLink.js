// The brain's side of the Glance Bridge plugin: request/response calls and the latest selection.
import { EventEmitter } from 'node:events';

export class FigmaError extends Error {}

export class FigmaLink extends EventEmitter {
  constructor({ timeoutMs = 8000, log = () => {} } = {}) {
    super();
    this.timeoutMs = timeoutMs;
    this.log = log;
    this.socket = null;
    this.pending = new Map();
    this.nextId = 1;
    this.file = null;
    this.page = null;
    this.selection = { nodes: [], at: 0 };
  }

  get connected() {
    return this.socket !== null;
  }

  /** socket: anything with send(string), on('message', fn(data)) and on('close', fn). Latest plugin wins. */
  attach(socket) {
    if (this.socket && this.socket !== socket) {
      try {
        this.socket.close();
      } catch {
        // already closed
      }
    }
    this.socket = socket;
    socket.on('message', (data) => {
      let msg;
      try {
        msg = JSON.parse(String(data));
      } catch {
        return;
      }
      this.handle(msg);
    });
    socket.on('close', () => {
      if (this.socket !== socket) return;
      this.socket = null;
      for (const { reject, timer } of this.pending.values()) {
        clearTimeout(timer);
        reject(new FigmaError('The Glance Bridge plugin closed.'));
      }
      this.pending.clear();
      this.emit('status', false);
    });
    this.emit('status', true);
  }

  handle(msg) {
    if (msg.type === 'hello') {
      this.file = msg.file ?? null;
      this.page = msg.page ?? null;
      this.log(`Figma: "${this.file}", page "${this.page}"`);
      this.emit('hello', msg);
    } else if (msg.type === 'selection') {
      this.selection = { nodes: Array.isArray(msg.nodes) ? msg.nodes : [], at: Date.now() };
      this.emit('selection', this.selection);
    } else if (msg.type === 'result') {
      const waiting = this.pending.get(msg.rid);
      if (!waiting) return;
      this.pending.delete(msg.rid);
      clearTimeout(waiting.timer);
      if (msg.ok) waiting.resolve(msg.value);
      else waiting.reject(new FigmaError(msg.error || 'Figma refused.'));
    }
  }

  call(op, args = {}) {
    if (!this.socket) return Promise.reject(new FigmaError('Open the Glance Bridge plugin in Figma first.'));
    const rid = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(rid);
        reject(new FigmaError(`Figma did not answer "${op}" in ${this.timeoutMs / 1000} s.`));
      }, this.timeoutMs);
      this.pending.set(rid, { resolve, reject, timer });
      this.socket.send(JSON.stringify({ type: 'call', rid, op, args }));
    });
  }
}
