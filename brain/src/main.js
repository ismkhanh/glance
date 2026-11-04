#!/usr/bin/env node
// Glance brain. Started by the Glance app (or by hand: `npm start` in this folder).
import { MuseClient, museKey } from './muse.js';
import { FigmaLink } from './figmaLink.js';
import { Orchestrator } from './orchestrator.js';
import { startServer } from './server.js';

const log = (line) => console.log(`[brain] ${line}`);

// A stray rejected promise in one task must not take every other task down with it: it is logged.
// A thrown error leaves the process in an unknown state: it is logged and the brain exits; the app starts it again.
process.on('unhandledRejection', (error) => log(`unhandled rejection: ${error?.stack || error}`));
process.on('uncaughtException', (error) => {
  log(`uncaught exception, stopping: ${error?.stack || error}`);
  process.exit(1);
});

const key = museKey();
if (!key) log('No MUSE_API_KEY found (environment or the .env file in the Glance folder). Tasks will not run until it is set.');

const muse = new MuseClient({ key, baseUrl: process.env.MUSE_BASE_URL || 'https://api.meta.ai/v1', log });
const figma = new FigmaLink({ log });
const orchestrator = new Orchestrator({
  muse,
  figma,
  log,
  useMuseReview: process.env.GLANCE_MUSE_REVIEW !== '0',
});

const port = Number(process.env.GLANCE_PORT || 47800);
try {
  const server = await startServer({ orchestrator, figma, port, token: process.env.GLANCE_TOKEN || null, log });
  log(`Listening on ws://localhost:${server.port} (app: /app, Figma plugin: /figma).`);
  const stop = async () => {
    await server.close();
    process.exit(0);
  };
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
  // When the Glance app that started us goes away, so do we.
  if (process.env.GLANCE_PARENT_PID) {
    const parent = Number(process.env.GLANCE_PARENT_PID);
    setInterval(() => {
      try {
        process.kill(parent, 0);
      } catch {
        stop();
      }
    }, 2000).unref();
  }
} catch (error) {
  if (error.code === 'EADDRINUSE') {
    log(`Port ${port} is busy: another Glance brain is probably running already. Using that one is fine.`);
    process.exit(0);
  }
  throw error;
}
