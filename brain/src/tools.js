// The tools a worker may use in Figma, as Muse function tools, and how each maps to a plugin operation.

const COLOR_NAMES = {
  red: '#FF3B30', orange: '#FF9500', yellow: '#FFCC00', green: '#34C759', teal: '#30B0C7', blue: '#0A84FF',
  indigo: '#5856D6', purple: '#AF52DE', violet: '#AF52DE', pink: '#FF2D55', black: '#000000', white: '#FFFFFF',
  gray: '#8E8E93', grey: '#8E8E93', brown: '#A2845E',
};

/** "#f00", "FF0000", "#FF0000" or a color name → "#FF0000". Throws on anything else. */
export function normalizeColor(value) {
  const s = String(value ?? '').trim().toLowerCase();
  if (COLOR_NAMES[s]) return COLOR_NAMES[s];
  let h = s.replace(/^#/, '');
  if (/^[0-9a-f]{3}$/.test(h)) h = h.split('').map((c) => c + c).join('');
  if (/^[0-9a-f]{6}$/.test(h)) return `#${h.toUpperCase()}`;
  throw new Error(`"${value}" is not a color; use hex like #FF3B30.`);
}

function num(value, name) {
  const n = Number(value);
  if (!Number.isFinite(n)) throw new Error(`${name} must be a number, got "${value}".`);
  return n;
}

function fn(name, description, properties = {}, required = []) {
  return {
    type: 'function',
    name,
    description,
    parameters: { type: 'object', properties, required, additionalProperties: false },
  };
}

const nodeId = { type: 'string', description: 'Layer id from the facts, e.g. "12:34".' };

/**
 * Write tools: Muse name → plugin op, the layer properties it changes (what the reviewer checks),
 * and how its arguments become plugin arguments.
 */
export const WRITE_TOOLS = {
  set_fill: {
    op: 'setFill',
    tool: fn('set_fill', 'Set the fill color of a layer (for text layers, the text color).',
      { node_id: nodeId, color: { type: 'string', description: 'Hex like #FF3B30.' } }, ['node_id', 'color']),
    args: (a) => ({ id: a.node_id, color: normalizeColor(a.color) }),
    expect: (a) => [['fill', normalizeColor(a.color)]],
  },
  set_stroke: {
    op: 'setStroke',
    tool: fn('set_stroke', 'Set the border (stroke) color and, optionally, its width.',
      { node_id: nodeId, color: { type: 'string' }, weight: { type: 'number' } }, ['node_id', 'color']),
    args: (a) => ({ id: a.node_id, color: normalizeColor(a.color), weight: a.weight === undefined ? undefined : num(a.weight, 'weight') }),
    expect: (a) => [['stroke', normalizeColor(a.color)]].concat(a.weight === undefined ? [] : [['strokeWeight', num(a.weight, 'weight')]]),
  },
  set_corner_radius: {
    op: 'setCornerRadius',
    tool: fn('set_corner_radius', 'Round the corners of a frame or shape.',
      { node_id: nodeId, radius: { type: 'number' } }, ['node_id', 'radius']),
    args: (a) => ({ id: a.node_id, radius: num(a.radius, 'radius') }),
    expect: (a) => [['cornerRadius', Math.max(0, num(a.radius, 'radius'))]],
  },
  set_opacity: {
    op: 'setOpacity',
    tool: fn('set_opacity', 'Set layer opacity from 0 (invisible) to 1.',
      { node_id: nodeId, opacity: { type: 'number' } }, ['node_id', 'opacity']),
    args: (a) => ({ id: a.node_id, opacity: num(a.opacity, 'opacity') }),
    expect: (a) => [['opacity', Math.round(Math.max(0, Math.min(1, num(a.opacity, 'opacity'))) * 100) / 100]],
  },
  set_text: {
    op: 'setText',
    tool: fn('set_text', 'Replace the words of a text layer.', { node_id: nodeId, text: { type: 'string' } }, ['node_id', 'text']),
    args: (a) => ({ id: a.node_id, text: String(a.text ?? '') }),
    expect: (a) => [['text', String(a.text ?? '').slice(0, 300)]],
  },
  set_font_size: {
    op: 'setFontSize',
    tool: fn('set_font_size', 'Set the font size of a text layer.', { node_id: nodeId, size: { type: 'number' } }, ['node_id', 'size']),
    args: (a) => ({ id: a.node_id, size: num(a.size, 'size') }),
    expect: (a) => [['fontSize', Math.max(1, num(a.size, 'size'))]],
  },
  resize: {
    op: 'resize',
    tool: fn('resize', 'Set the width and height of a layer.',
      { node_id: nodeId, width: { type: 'number' }, height: { type: 'number' } }, ['node_id', 'width', 'height']),
    args: (a) => ({ id: a.node_id, width: num(a.width, 'width'), height: num(a.height, 'height') }),
    expect: (a) => [['width', num(a.width, 'width')], ['height', num(a.height, 'height')]],
  },
  set_auto_layout: {
    op: 'setAutoLayout',
    tool: fn('set_auto_layout', 'Turn on auto layout for a frame (items in a row or a column), or turn it off.', {
      node_id: nodeId,
      direction: { type: 'string', enum: ['NONE', 'HORIZONTAL', 'VERTICAL'] },
      spacing: { type: 'number', description: 'Gap between items.' },
      padding: { type: 'number', description: 'Same padding on all four sides.' },
    }, ['node_id', 'direction']),
    args: (a) => ({ id: a.node_id, direction: String(a.direction).toUpperCase(), spacing: a.spacing, padding: a.padding }),
    expect: (a) => [['layoutMode', String(a.direction).toUpperCase()]],
  },
  set_scroll: {
    op: 'setScroll',
    tool: fn('set_scroll', 'Make a frame scroll in the prototype (overflow scrolling), or stop it scrolling.', {
      node_id: nodeId,
      direction: { type: 'string', enum: ['NONE', 'HORIZONTAL', 'VERTICAL', 'BOTH'] },
    }, ['node_id', 'direction']),
    args: (a) => ({ id: a.node_id, direction: String(a.direction).toUpperCase() }),
    expect: (a) => [['overflowDirection', String(a.direction).toUpperCase()]],
  },
  set_image: {
    op: 'setImage',
    tool: fn('set_image', 'Fill a frame or shape with a new picture that Muse Image paints from a description (takes about 15 s).', {
      node_id: nodeId,
      prompt: { type: 'string', description: 'What the picture shows, in one sentence, with a style such as "travel photo".' },
    }, ['node_id', 'prompt']),
    args: (a) => ({ id: a.node_id, prompt: String(a.prompt ?? '') }),
    // The picture is painted before the plugin call, so a slow Muse Image never holds up Figma.
    prepare: async (pluginArgs, { muse, signal, step }) => {
      if (!pluginArgs.prompt.trim()) throw new Error('Say what the picture should show.');
      step('Painting the picture with Muse Image…');
      return { id: pluginArgs.id, base64: await muse.image(pluginArgs.prompt, { signal }) };
    },
    expect: () => [['image', true]],
  },
  rename: {
    op: 'rename',
    tool: fn('rename', 'Rename a layer.', { node_id: nodeId, name: { type: 'string' } }, ['node_id', 'name']),
    args: (a) => ({ id: a.node_id, name: String(a.name ?? '') }),
    expect: (a) => [['name', String(a.name ?? '')]],
  },
};

export const READ_TOOLS = {
  get_layer: {
    op: 'getNode',
    tool: fn('get_layer', 'Read a layer: its properties and children.', { node_id: nodeId }, ['node_id']),
    args: (a) => ({ id: a.node_id }),
  },
  find_layers: {
    op: 'findNodes',
    tool: fn('find_layers', 'Find layers on this page by name.', { query: { type: 'string' } }, ['query']),
    args: (a) => ({ query: String(a.query ?? '') }),
  },
};

export const ASK_TOOL = fn('ask_user',
  'Ask the user one short question when the request can be done in clearly different ways. A tooltip appears where they pointed.', {
    question: { type: 'string', description: 'Under 12 words.' },
    options: { type: 'array', items: { type: 'string' }, description: '2 to 4 short answers.' },
    recommended: { type: 'string', description: 'The option you recommend; must be one of the options.' },
    reason: { type: 'string', description: 'Why you recommend it, under 10 words.' },
  }, ['question', 'options', 'recommended', 'reason']);

export const FINISH_TOOL = fn('finish', 'Say the task is done (or cannot be done), with a one-sentence summary.',
  { summary: { type: 'string' } }, ['summary']);

export function workerTools() {
  return [
    ...Object.values(READ_TOOLS).map((t) => t.tool),
    ...Object.values(WRITE_TOOLS).map((t) => t.tool),
    ASK_TOOL,
    FINISH_TOOL,
  ];
}

export function isWrite(name) {
  return Object.prototype.hasOwnProperty.call(WRITE_TOOLS, name);
}

export function isRead(name) {
  return Object.prototype.hasOwnProperty.call(READ_TOOLS, name);
}
