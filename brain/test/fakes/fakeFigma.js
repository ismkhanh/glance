// A small stand-in for Figma's plugin API: enough of it to run the real plugin code (figma-plugin/code.js).
// Like real Figma: paint arrays are frozen copies, text needs its font loaded before it changes, ids look like "1:2".
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
export const plugin = require('../../../figma-plugin/code.js');

const MIXED = Symbol('figma.mixed');
const WITH_PAINT = new Set(['FRAME', 'RECTANGLE', 'ELLIPSE', 'TEXT', 'COMPONENT', 'INSTANCE']);
const WITH_CORNERS = new Set(['FRAME', 'RECTANGLE', 'COMPONENT', 'INSTANCE']);
const WITH_LAYOUT = new Set(['FRAME', 'COMPONENT', 'INSTANCE']);
const CONTAINERS = new Set(['FRAME', 'GROUP', 'COMPONENT', 'INSTANCE', 'SECTION']);

function solid(hex) {
  return [{ type: 'SOLID', visible: true, opacity: 1, color: plugin.hexToRgb(hex) }];
}

function frozenCopy(paints) {
  return Object.freeze(JSON.parse(JSON.stringify(paints)).map((p) => Object.freeze(p)));
}

function findAll(node, fn, out = []) {
  for (const child of node.children || []) {
    if (fn(child)) out.push(child);
    findAll(child, fn, out);
  }
  return out;
}

/**
 * spec: {id, type, name, x, y, width, height, fill, cornerRadius, layoutMode, characters, fontSize, children: [...]}
 * Returns {figma, node(id), select(...ids)}.
 */
export function makeFigma(pageChildren, { fileName = 'Test file' } = {}) {
  const nodes = new Map();
  const loadedFonts = new Set();
  const figma = {
    mixed: MIXED,
    undoSteps: 0,
    notes: [],
    root: { name: fileName },
    currentPage: null,
    async getNodeByIdAsync(id) {
      return nodes.get(String(id)) || null;
    },
    async loadFontAsync(font) {
      loadedFonts.add(`${font.family}/${font.style}`);
    },
    commitUndo() {
      this.undoSteps += 1;
    },
    notify(text) {
      this.notes.push(text);
    },
    images: [],
    base64Decode(text) {
      return Uint8Array.from(Buffer.from(String(text), 'base64'));
    },
    createImage(bytes) {
      this.images.push(bytes);
      return { hash: `img${this.images.length}` };
    },
  };

  function build(spec, parent) {
    const node = {
      id: spec.id,
      type: spec.type,
      name: spec.name,
      x: spec.x ?? 0,
      y: spec.y ?? 0,
      width: spec.width ?? 100,
      height: spec.height ?? 100,
      visible: spec.visible ?? true,
      opacity: spec.opacity ?? 1,
      parent,
    };
    if (spec.type !== 'GROUP') {
      node.resize = function (w, h) {
        this.width = w;
        this.height = h;
      };
    }
    if (WITH_PAINT.has(spec.type)) {
      let fills = frozenCopy(spec.fill ? solid(spec.fill) : []);
      let strokes = frozenCopy(spec.stroke ? solid(spec.stroke) : []);
      Object.defineProperty(node, 'fills', { enumerable: true, get: () => fills, set: (v) => { fills = frozenCopy(v); } });
      Object.defineProperty(node, 'strokes', { enumerable: true, get: () => strokes, set: (v) => { strokes = frozenCopy(v); } });
      node.strokeWeight = spec.strokeWeight ?? 1;
    }
    if (WITH_CORNERS.has(spec.type)) node.cornerRadius = spec.cornerRadius ?? 0;
    if (WITH_LAYOUT.has(spec.type)) {
      Object.assign(node, {
        layoutMode: spec.layoutMode ?? 'NONE', itemSpacing: spec.itemSpacing ?? 0,
        paddingTop: 0, paddingRight: 0, paddingBottom: 0, paddingLeft: 0,
        overflowDirection: spec.overflowDirection ?? 'NONE', clipsContent: spec.clipsContent ?? false,
      });
    }
    if (spec.type === 'TEXT') {
      let characters = spec.characters ?? '';
      let fontSize = spec.fontSize ?? 16;
      node.fontName = { family: 'Inter', style: 'Regular' };
      const needFont = () => {
        if (!loadedFonts.has('Inter/Regular')) throw new Error('Cannot write to node with unloaded font "Inter Regular"');
      };
      Object.defineProperty(node, 'characters', { enumerable: true, get: () => characters, set: (v) => { needFont(); characters = String(v); } });
      Object.defineProperty(node, 'fontSize', { enumerable: true, get: () => fontSize, set: (v) => { needFont(); fontSize = v; } });
    }
    if (CONTAINERS.has(spec.type)) {
      node.children = (spec.children || []).map((c) => build(c, node));
      node.findAll = (fn) => findAll(node, fn);
    }
    nodes.set(node.id, node);
    return node;
  }

  const page = { id: '0:1', type: 'PAGE', name: 'Page 1', selection: [], children: [] };
  page.children = pageChildren.map((c) => build(c, page));
  page.findAll = (fn) => findAll(page, fn);
  figma.currentPage = page;

  return {
    figma,
    node: (id) => nodes.get(id),
    select: (...ids) => {
      page.selection = ids.map((id) => nodes.get(id));
    },
  };
}

/** The test design: a phone screen with a blue button, a promo banner whose cards spill out sideways, and a title. */
export function sampleDesign() {
  return makeFigma([
    {
      id: '1:1', type: 'FRAME', name: 'Home', x: 0, y: 0, width: 390, height: 844, fill: '#FFFFFF',
      children: [
        {
          id: '1:2', type: 'FRAME', name: 'Buy button', x: 20, y: 700, width: 160, height: 48, fill: '#0A84FF', cornerRadius: 8,
          children: [{ id: '1:3', type: 'TEXT', name: 'Label', x: 40, y: 14, width: 80, height: 20, fill: '#FFFFFF', characters: 'Buy now', fontSize: 16 }],
        },
        {
          id: '1:4', type: 'FRAME', name: 'Promo banner', x: 0, y: 100, width: 390, height: 120, fill: '#F2F2F7',
          children: [0, 1, 2, 3].map((i) => ({
            id: `1:${10 + i}`, type: 'RECTANGLE', name: `Card ${i + 1}`, x: 16 + i * 176, y: 10, width: 160, height: 100, fill: '#FFCC00', cornerRadius: 12,
          })),
        },
        { id: '1:5', type: 'TEXT', name: 'Title', x: 20, y: 40, width: 200, height: 30, fill: '#000000', characters: 'Hello', fontSize: 28 },
        { id: '1:6', type: 'GROUP', name: 'Icons', x: 300, y: 40, width: 60, height: 24, children: [] },
        { id: '1:7', type: 'FRAME', name: 'Settings list', x: 0, y: 300, width: 390, height: 360, fill: '#FFFFFF', children: [] },
      ],
    },
  ]);
}

/**
 * Connects a FigmaLink to the real plugin code over a fake socket. Calls run one at a time, in order,
 * exactly like the plugin's queue inside Figma.
 */
export function connectPlugin(link, fake) {
  const bridge = plugin.createBridge(fake.figma);
  const listeners = { message: [], close: [] };
  let queue = Promise.resolve();
  const socket = {
    sent: [],
    send(text) {
      const msg = JSON.parse(text);
      socket.sent.push(msg);
      if (msg.type !== 'call') return;
      queue = queue.then(() => bridge.handle(msg.op, msg.args).then(
        (value) => ({ type: 'result', rid: msg.rid, ok: true, value }),
        (error) => ({ type: 'result', rid: msg.rid, ok: false, error: error.message }),
      )).then((reply) => {
        for (const fn of listeners.message) fn(JSON.stringify(reply));
      });
    },
    on(event, fn) {
      listeners[event].push(fn);
    },
    close() {
      for (const fn of listeners.close) fn();
    },
  };
  link.attach(socket);
  return { socket, bridge };
}
