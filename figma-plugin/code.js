// Glance Bridge: a Figma plugin that lets the Glance brain read and change the layer you point at.
// It runs inside Figma (desktop app). ui.html holds the WebSocket to the brain and relays messages here.
//
// Written in plain ES2017 (no ?. or ??) because the plugin sandbox is stricter than a browser.
// The same file is loaded by the Node tests with a fake `figma` object (see brain/test).

(function () {
  var SCROLL_DIRECTIONS = ['NONE', 'HORIZONTAL', 'VERTICAL', 'BOTH'];
  var LAYOUT_DIRECTIONS = ['NONE', 'HORIZONTAL', 'VERTICAL'];
  var SCROLLABLE_TYPES = ['FRAME', 'COMPONENT', 'COMPONENT_SET', 'INSTANCE'];

  function round(n) {
    return Math.round(n * 100) / 100;
  }

  function hexToRgb(hex) {
    var h = String(hex || '').trim().replace(/^#/, '');
    if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2];
    if (!/^[0-9a-fA-F]{6}$/.test(h)) throw new Error('Color must look like #FF3B30, got "' + hex + '".');
    return {
      r: parseInt(h.slice(0, 2), 16) / 255,
      g: parseInt(h.slice(2, 4), 16) / 255,
      b: parseInt(h.slice(4, 6), 16) / 255,
    };
  }

  function rgbToHex(c) {
    function part(v) {
      var s = Math.round(Math.max(0, Math.min(1, v)) * 255).toString(16).toUpperCase();
      return s.length === 1 ? '0' + s : s;
    }
    return '#' + part(c.r) + part(c.g) + part(c.b);
  }

  function clone(value) {
    return JSON.parse(JSON.stringify(value));
  }

  function createBridge(figma) {
    function isMixed(v) {
      return figma.mixed !== undefined && v === figma.mixed;
    }

    function firstSolid(paints) {
      if (!paints || isMixed(paints)) return null;
      for (var i = 0; i < paints.length; i++) {
        var p = paints[i];
        if (p.type === 'SOLID' && p.visible !== false) return p;
      }
      return null;
    }

    function summary(node) {
      return { id: node.id, name: node.name, type: node.type,
               x: round(node.x || 0), y: round(node.y || 0),
               width: round(node.width || 0), height: round(node.height || 0) };
    }

    /// How the children sit compared to the frame: do they spill out sideways or downwards?
    function hints(node) {
      var kids = node.children || [];
      var overflowX = false;
      var overflowY = false;
      for (var i = 0; i < kids.length; i++) {
        var k = kids[i];
        if (k.visible === false) continue;
        if (k.x < -0.5 || k.x + k.width > node.width + 0.5) overflowX = true;
        if (k.y < -0.5 || k.y + k.height > node.height + 0.5) overflowY = true;
      }
      var overflow = overflowX && overflowY ? 'BOTH' : overflowX ? 'HORIZONTAL' : overflowY ? 'VERTICAL' : 'NONE';
      var recommended;
      var why;
      if (overflow !== 'NONE') {
        recommended = overflow;
        why = 'content already spills out ' + (overflow === 'BOTH' ? 'both ways' : overflow.toLowerCase() + 'ly');
      } else if (node.layoutMode === 'HORIZONTAL') {
        recommended = 'HORIZONTAL';
        why = 'its items sit in a row';
      } else if (node.layoutMode === 'VERTICAL') {
        recommended = 'VERTICAL';
        why = 'its items sit in a column';
      } else if (node.width >= 2 * node.height) {
        recommended = 'HORIZONTAL';
        why = 'it is wide and short, like a banner';
      } else {
        recommended = 'VERTICAL';
        why = 'it is taller than a banner';
      }
      return { contentOverflow: overflow, recommendedScroll: recommended, recommendedScrollWhy: why };
    }

    /// Everything Muse needs to know about a layer, small enough to send with every step.
    function describe(node, withChildren) {
      var d = summary(node);
      d.visible = node.visible !== false;
      if (node.opacity !== undefined) d.opacity = round(node.opacity);
      if ('fills' in node) {
        var fill = firstSolid(node.fills);
        d.fill = fill ? rgbToHex(fill.color) : null;
        d.fillCount = isMixed(node.fills) ? 'mixed' : node.fills.length;
        d.image = !isMixed(node.fills) && node.fills.some(function (p) { return p.type === 'IMAGE' && p.visible !== false; });
      }
      if ('strokes' in node) {
        var stroke = firstSolid(node.strokes);
        d.stroke = stroke ? rgbToHex(stroke.color) : null;
        if (node.strokeWeight !== undefined) d.strokeWeight = isMixed(node.strokeWeight) ? 'mixed' : node.strokeWeight;
      }
      if ('cornerRadius' in node) d.cornerRadius = isMixed(node.cornerRadius) ? 'mixed' : node.cornerRadius;
      if ('layoutMode' in node) {
        d.layoutMode = node.layoutMode;
        if (node.layoutMode !== 'NONE') {
          d.itemSpacing = node.itemSpacing;
          d.padding = [node.paddingTop, node.paddingRight, node.paddingBottom, node.paddingLeft];
        }
      }
      if ('overflowDirection' in node) d.overflowDirection = node.overflowDirection;
      if ('clipsContent' in node) d.clipsContent = node.clipsContent;
      if (node.type === 'TEXT') {
        d.text = String(node.characters || '').slice(0, 300);
        d.fontSize = isMixed(node.fontSize) ? 'mixed' : node.fontSize;
      }
      if (node.parent && node.parent.type !== 'PAGE' && node.parent.type !== 'DOCUMENT') {
        d.parent = { id: node.parent.id, name: node.parent.name, type: node.parent.type };
      }
      if (node.children) {
        d.childCount = node.children.length;
        if (withChildren) d.children = node.children.slice(0, 20).map(summary);
        if (SCROLLABLE_TYPES.indexOf(node.type) >= 0) d.hints = hints(node);
      }
      return d;
    }

    async function nodeById(id) {
      var node = await figma.getNodeByIdAsync(String(id));
      if (!node) throw new Error('No layer with id ' + id + '.');
      if (node.type === 'PAGE' || node.type === 'DOCUMENT') throw new Error('That is a page, not a layer.');
      return node;
    }

    function needs(node, prop, what) {
      if (!(prop in node)) throw new Error(node.type.toLowerCase() + ' "' + node.name + '" has no ' + what + '.');
    }

    async function loadFonts(node) {
      if (node.type !== 'TEXT') return;
      if (isMixed(node.fontName)) {
        var len = String(node.characters || '').length;
        var seen = {};
        for (var i = 0; i < len; i++) {
          var f = node.getRangeFontName(i, i + 1);
          var key = f.family + '/' + f.style;
          if (!seen[key]) {
            seen[key] = true;
            await figma.loadFontAsync(f);
          }
        }
      } else {
        await figma.loadFontAsync(node.fontName);
      }
    }

    /// The properties Glance may change, saved so a task can be undone exactly.
    var SAVED = ['name', 'visible', 'opacity', 'fills', 'strokes', 'strokeWeight', 'cornerRadius', 'layoutMode',
                 'itemSpacing', 'paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft', 'overflowDirection',
                 'clipsContent', 'characters', 'fontSize'];

    function snapshot(node) {
      var props = {};
      for (var i = 0; i < SAVED.length; i++) {
        var p = SAVED[i];
        if (!(p in node)) continue;
        var v = node[p];
        if (isMixed(v)) continue;          // cannot restore a mixed value as one value; leave it alone
        props[p] = clone(v);
      }
      return { id: node.id, width: node.width, height: node.height, props: props };
    }

    async function restore(snap) {
      var node = await nodeById(snap.id);
      var p = snap.props || {};
      if ('characters' in p || 'fontSize' in p) await loadFonts(node);
      // Layout first: auto layout can resize the frame, so size and padding come after it.
      var order = ['layoutMode'].concat(SAVED.filter(function (k) { return k !== 'layoutMode'; }));
      for (var i = 0; i < order.length; i++) {
        var k = order[i];
        if (k in p && k in node) node[k] = clone(p[k]);
      }
      if (typeof node.resize === 'function' && (node.width !== snap.width || node.height !== snap.height)) {
        node.resize(snap.width, snap.height);
      }
      return describe(node, false);
    }

    function selectionSummary() {
      return figma.currentPage.selection.map(function (n) { return describe(n, false); });
    }

    var ops = {
      getSelection: async function () {
        return selectionSummary();
      },
      getNode: async function (a) {
        return describe(await nodeById(a.id), true);
      },
      findNodes: async function (a) {
        var q = String(a.query || '').toLowerCase().trim();
        if (!q) throw new Error('Say what to look for.');
        var scope = a.scopeId ? await nodeById(a.scopeId) : figma.currentPage;
        var found = scope.findAll(function (n) { return String(n.name || '').toLowerCase().indexOf(q) >= 0; });
        return found.slice(0, 15).map(summary);
      },
      snapshot: async function (a) {
        return snapshot(await nodeById(a.id));
      },
      restore: async function (a) {
        return restore(a.snapshot);
      },
      setFill: async function (a) {
        var node = await nodeById(a.id);
        needs(node, 'fills', 'fill');
        var paint = { type: 'SOLID', color: hexToRgb(a.color) };
        if (a.opacity !== undefined && a.opacity !== null) paint.opacity = Math.max(0, Math.min(1, Number(a.opacity)));
        var others = isMixed(node.fills) ? [] : node.fills.filter(function (p) { return p.type !== 'SOLID'; });
        node.fills = [paint].concat(clone(others));
        return describe(node, false);
      },
      setStroke: async function (a) {
        var node = await nodeById(a.id);
        needs(node, 'strokes', 'stroke');
        node.strokes = [{ type: 'SOLID', color: hexToRgb(a.color) }];
        if (a.weight !== undefined && a.weight !== null) node.strokeWeight = Math.max(0, Number(a.weight));
        return describe(node, false);
      },
      setCornerRadius: async function (a) {
        var node = await nodeById(a.id);
        needs(node, 'cornerRadius', 'corner radius');
        node.cornerRadius = Math.max(0, Number(a.radius));
        return describe(node, false);
      },
      setOpacity: async function (a) {
        var node = await nodeById(a.id);
        node.opacity = Math.max(0, Math.min(1, Number(a.opacity)));
        return describe(node, false);
      },
      setText: async function (a) {
        var node = await nodeById(a.id);
        if (node.type !== 'TEXT') throw new Error('"' + node.name + '" is not a text layer.');
        await loadFonts(node);
        node.characters = String(a.text);
        return describe(node, false);
      },
      setFontSize: async function (a) {
        var node = await nodeById(a.id);
        if (node.type !== 'TEXT') throw new Error('"' + node.name + '" is not a text layer.');
        await loadFonts(node);
        node.fontSize = Math.max(1, Number(a.size));
        return describe(node, false);
      },
      resize: async function (a) {
        var node = await nodeById(a.id);
        if (typeof node.resize !== 'function') throw new Error('"' + node.name + '" cannot be resized.');
        node.resize(Math.max(1, Number(a.width)), Math.max(1, Number(a.height)));
        return describe(node, false);
      },
      setAutoLayout: async function (a) {
        var node = await nodeById(a.id);
        needs(node, 'layoutMode', 'auto layout (only frames have it)');
        var dir = String(a.direction || '').toUpperCase();
        if (LAYOUT_DIRECTIONS.indexOf(dir) < 0) throw new Error('Direction must be NONE, HORIZONTAL or VERTICAL.');
        node.layoutMode = dir;
        if (dir !== 'NONE') {
          if (a.spacing !== undefined && a.spacing !== null) node.itemSpacing = Number(a.spacing);
          if (a.padding !== undefined && a.padding !== null) {
            var pad = Number(a.padding);
            node.paddingTop = pad;
            node.paddingRight = pad;
            node.paddingBottom = pad;
            node.paddingLeft = pad;
          }
        }
        return describe(node, true);
      },
      setScroll: async function (a) {
        var node = await nodeById(a.id);
        if (SCROLLABLE_TYPES.indexOf(node.type) < 0 || !('overflowDirection' in node)) {
          throw new Error('Only frames can scroll; "' + node.name + '" is a ' + node.type.toLowerCase() + '.');
        }
        var dir = String(a.direction || '').toUpperCase();
        if (SCROLL_DIRECTIONS.indexOf(dir) < 0) throw new Error('Direction must be NONE, HORIZONTAL, VERTICAL or BOTH.');
        node.overflowDirection = dir;
        if (dir !== 'NONE') node.clipsContent = true;      // content must be clipped for scrolling to show
        var d = describe(node, false);
        var spill = d.hints ? d.hints.contentOverflow : 'NONE';
        var moves = dir === 'BOTH' ? spill !== 'NONE' : spill === dir || spill === 'BOTH';
        if (dir !== 'NONE' && !moves) {
          d.note = 'Scrolling is on, but the content fits inside, so it will only move in the prototype once the ' +
                   'content is bigger than the frame.';
        }
        return d;
      },
      setImage: async function (a) {
        var node = await nodeById(a.id);
        needs(node, 'fills', 'fill');
        if (node.type === 'TEXT') throw new Error('"' + node.name + '" is text; put the picture on a frame or shape.');
        var image = figma.createImage(figma.base64Decode(String(a.base64 || '')));
        node.fills = [{ type: 'IMAGE', imageHash: image.hash, scaleMode: 'FILL' }];
        return describe(node, false);
      },
      rename: async function (a) {
        var node = await nodeById(a.id);
        node.name = String(a.name);
        return describe(node, false);
      },
      notify: async function (a) {
        if (figma.notify) figma.notify(String(a.text || '').slice(0, 120));
        return true;
      },
    };

    return {
      ops: Object.keys(ops),
      handle: async function (op, args) {
        if (!Object.prototype.hasOwnProperty.call(ops, op)) throw new Error('Unknown operation "' + op + '".');
        var value = await ops[op](args || {});
        if (op !== 'getSelection' && op !== 'getNode' && op !== 'findNodes' && op !== 'snapshot' && figma.commitUndo) {
          figma.commitUndo();             // each change is its own step in Figma's undo
        }
        return value;
      },
      selectionSummary: selectionSummary,
      describe: describe,
    };
  }

  /// "Build demo screen" in the plugin window: a small travel app screen to try Glance on (and record the demo).
  /// Cards spill out sideways on purpose, so "make it scrollable" has an obvious answer.
  async function buildDemo(figma) {
    var fonts = ['Regular', 'Semi Bold', 'Bold'];
    for (var i = 0; i < fonts.length; i++) await figma.loadFontAsync({ family: 'Inter', style: fonts[i] });

    function fill(node, hex) {
      node.fills = [{ type: 'SOLID', color: hexToRgb(hex) }];
    }
    function frame(parent, name, x, y, w, h, hex, radius) {
      var f = figma.createFrame();
      f.name = name;
      f.resize(w, h);
      f.x = x;
      f.y = y;
      if (hex) fill(f, hex); else f.fills = [];
      f.cornerRadius = radius || 0;
      parent.appendChild(f);
      return f;
    }
    function text(parent, name, chars, x, y, size, style, hex) {
      var t = figma.createText();
      t.fontName = { family: 'Inter', style: style };
      t.characters = chars;
      t.fontSize = size;
      t.name = name;
      fill(t, hex);
      parent.appendChild(t);
      t.x = x;
      t.y = y;
      return t;
    }

    // Its own page, so the canvas is empty around it and nothing of yours is touched.
    var page = figma.createPage();
    page.name = 'Glance demo';
    await figma.setCurrentPageAsync(page);
    var screen = frame(page, 'Trips app', 0, 0, 390, 844, '#F6F5F2', 36);
    screen.clipsContent = true;

    text(screen, 'Greeting', 'Good morning', 24, 64, 15, 'Regular', '#6B6B6B');
    text(screen, 'Title', 'Where to next?', 24, 86, 32, 'Bold', '#111111');
    var search = frame(screen, 'Search', 24, 144, 342, 48, '#FFFFFF', 14);
    text(search, 'Placeholder', 'Search destinations', 16, 14, 15, 'Regular', '#9A9A9A');

    text(screen, 'Section title', 'Weekend trips', 24, 222, 20, 'Semi Bold', '#111111');
    var cards = frame(screen, 'Trip cards', 0, 258, 390, 214, '#F6F5F2', 0);   // filled, so pointing between cards picks the row
    cards.clipsContent = true;
    var trips = [['Lisbon', '#E9A23B'], ['Tbilisi', '#5B8DEF'], ['Muscat', '#2BB3A3'], ['Baku', '#D9627A']];
    trips.forEach(function (trip, i) {
      var card = frame(cards, trip[0] + ' card', 24 + i * 236, 0, 220, 210, trip[1], 20);
      text(card, 'City', trip[0], 18, 150, 22, 'Bold', '#FFFFFF');
      text(card, 'Nights', '3 nights', 18, 178, 13, 'Regular', '#FFFFFF');
    });

    text(screen, 'Featured title', 'Featured', 24, 494, 20, 'Semi Bold', '#111111');
    var hero = frame(screen, 'Featured image', 24, 530, 342, 196, '#E8E4DC', 20);
    text(hero, 'Caption', 'Your next escape', 18, 160, 15, 'Semi Bold', '#5E5A52');

    var book = frame(screen, 'Book button', 24, 756, 342, 56, '#0A84FF', 16);
    var label = text(book, 'Label', 'Book a trip', 0, 0, 17, 'Semi Bold', '#FFFFFF');
    label.x = Math.round((342 - label.width) / 2);
    label.y = Math.round((56 - label.height) / 2);

    figma.currentPage.selection = [];
    figma.viewport.scrollAndZoomIntoView([screen]);
    figma.viewport.zoom = Math.min(figma.viewport.zoom, 1);
    if (figma.commitUndo) figma.commitUndo();
    return screen.id;
  }

  /// Wires the bridge to Figma's plugin UI. Only runs inside Figma.
  function start(figma) {
    var bridge = createBridge(figma);
    figma.showUI(__html__, { width: 260, height: 168, title: 'Glance Bridge', themeColors: true });

    function hello() {
      figma.ui.postMessage({ type: 'hello', plugin: 'glance-bridge', file: figma.root.name, page: figma.currentPage.name });
      figma.ui.postMessage({ type: 'selection', nodes: bridge.selectionSummary() });
    }

    // Calls run one after another, in the order they arrive: an undo never overtakes the change it undoes,
    // even when several Glance tasks work at the same time.
    var queue = Promise.resolve();
    figma.ui.onmessage = function (msg) {
      if (!msg || typeof msg !== 'object') return;
      if (msg.type === 'ui-connected') {
        hello();
        return;
      }
      if (msg.type === 'build-demo') {
        buildDemo(figma).then(function () {
          if (figma.notify) figma.notify('Demo screen ready: point at a layer and talk.');
        }, function (e) {
          if (figma.notify) figma.notify('Could not build the demo screen: ' + String((e && e.message) || e));
        });
        return;
      }
      if (msg.type !== 'call') return;
      queue = queue.then(function () {
        return bridge.handle(msg.op, msg.args).then(function (value) {
          figma.ui.postMessage({ type: 'result', rid: msg.rid, ok: true, value: value });
        }, function (e) {
          figma.ui.postMessage({ type: 'result', rid: msg.rid, ok: false, error: String((e && e.message) || e) });
        });
      });
    };
    figma.on('selectionchange', function () {
      figma.ui.postMessage({ type: 'selection', nodes: bridge.selectionSummary() });
    });
    figma.on('currentpagechange', hello);
  }

  if (typeof figma !== 'undefined' && figma && typeof figma.showUI === 'function') start(figma);
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = { createBridge: createBridge, hexToRgb: hexToRgb, rgbToHex: rgbToHex };
  }
})();
