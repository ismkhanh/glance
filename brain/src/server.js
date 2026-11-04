// WebSocket server: /app for the Glance app, /figma for the Glance Bridge plugin. Loopback only.
import http from 'node:http';
import { WebSocketServer } from 'ws';

const FIGMA_ORIGIN = /^https:\/\/([a-z0-9-]+\.)*figma\.com$/;

/** The plugin UI comes with no origin, "null", or figma.com. Anything else is a web page: refused. */
export function pluginOriginOk(origin) {
  return !origin || origin === 'null' || FIGMA_ORIGIN.test(origin);
}

/** The app never sends an Origin; a browser page always does. With a token, the token must match. */
export function appAllowed({ origin, token, expected }) {
  if (origin && origin !== 'null') return false;
  return !expected || token === expected;
}

function listen(server, port, host) {
  return new Promise((resolve, reject) => {
    const onError = (error) => {
      server.off('listening', onListening);
      reject(error);
    };
    const onListening = () => {
      server.off('error', onError);
      resolve(server.address().port);
    };
    server.once('error', onError);
    server.once('listening', onListening);
    server.listen(port, host);
  });
}

export async function startServer({ orchestrator, figma, port = 47800, hosts = ['127.0.0.1', '::1'], token = null, log = () => {} }) {
  const wss = new WebSocketServer({ noServer: true, maxPayload: 4 * 1024 * 1024 });
  let app = null;
  const servers = [];

  const sendApp = (msg) => {
    if (app && app.readyState === 1) app.send(JSON.stringify(msg));
  };

  // Orchestrator and Figma events go to the app.
  const forward = {
    tasks: (tasks) => sendApp({ type: 'tasks', tasks }),
    ask: (e) => sendApp({ type: 'ask', ...e }),
    askDone: (e) => sendApp({ type: 'askDone', ...e }),
    toast: (e) => sendApp({ type: 'toast', ...e }),
  };
  for (const [name, fn] of Object.entries(forward)) orchestrator.on(name, fn);
  const onFigmaStatus = (connected) => {
    log(connected ? 'Figma plugin connected.' : 'Figma plugin disconnected.');
    sendApp({ type: 'status', figma: connected, muse: orchestrator.muse.available });
  };
  figma.on('status', onFigmaStatus);

  async function onAppMessage(msg) {
    switch (msg.type) {
      case 'hello':
        sendApp({ type: 'hello', brain: 'glance-brain', figma: figma.connected, muse: orchestrator.muse.available });
        sendApp({ type: 'tasks', tasks: orchestrator.views() });
        break;
      case 'point':
        orchestrator.point(msg);
        break;
      case 'command':
        sendApp(await orchestrator.command(msg));
        break;
      case 'answer':
        orchestrator.answer(msg.taskId, msg.text);
        break;
      case 'control':
        await orchestrator.control(msg.taskId, msg.action);
        break;
      case 'edit':
        await orchestrator.edit(msg.taskId, msg.text);
        break;
      default:
        break;
    }
  }

  function onUpgrade(req, socket, head) {
    const url = new URL(req.url, 'http://localhost');
    const origin = req.headers.origin;
    let kind = null;
    if (url.pathname === '/app' && appAllowed({ origin, token: url.searchParams.get('token'), expected: token })) kind = 'app';
    if (url.pathname === '/figma' && pluginOriginOk(origin)) kind = 'figma';
    if (!kind) {
      log(`Refused a connection to ${url.pathname} (origin ${origin || 'none'}).`);
      socket.write('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => {
      if (kind === 'figma') {
        figma.attach(ws);
        return;
      }
      if (app && app !== ws) app.close();
      app = ws;
      log('Glance app connected.');
      ws.on('message', (data) => {
        let msg;
        try {
          msg = JSON.parse(String(data));
        } catch {
          return;
        }
        onAppMessage(msg).catch((error) => log(`app message failed: ${error.message}`));
      });
      ws.on('close', () => {
        if (app === ws) app = null;
      });
    });
  }

  let boundPort = port;
  for (const host of hosts) {
    const server = http.createServer((req, res) => {
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      res.end('Glance brain\n');
    });
    server.on('upgrade', onUpgrade);
    try {
      boundPort = await listen(server, boundPort, host);
      servers.push(server);
    } catch (error) {
      // No IPv6 loopback on this machine is fine; anything else (port in use) is not.
      if (host === '::1' && (error.code === 'EADDRNOTAVAIL' || error.code === 'EAFNOSUPPORT')) continue;
      for (const s of servers) s.close();
      throw error;
    }
  }

  return {
    port: boundPort,
    async close() {
      for (const [name, fn] of Object.entries(forward)) orchestrator.off(name, fn);
      figma.off('status', onFigmaStatus);
      for (const client of wss.clients) client.terminate();
      await Promise.all(servers.map((s) => new Promise((resolve) => s.close(resolve))));
    },
  };
}
