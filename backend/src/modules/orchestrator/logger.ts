// Shared logger holder for the orchestrator module family.
//
// The orchestrator was split into several files (sessionStore, podBoot, broker,
// podDeath, provisioner, reaper, + the orchestrator composition layer). They all
// need the same Fastify logger that `start()` receives at boot. Rather than
// re-inject a logger into each module or thread it through ~80 call sites, every
// module imports the `log` proxy below and keeps writing `log.info(...)` as
// before. The proxy forwards each call to whichever logger `setLogger()` last
// installed, so a single `setLogger(logger)` in `start()` wires them all.
//
// Mirrors the existing inject-once idiom used by `../redis/client.js`
// (`setLogger`). Until `start()` runs, the proxy forwards to `console` (matches
// the previous `let log = console as unknown as FastifyBaseLogger` default), so
// any pre-boot diagnostic still prints instead of throwing.

import type { FastifyBaseLogger } from 'fastify';

let current: FastifyBaseLogger = console as unknown as FastifyBaseLogger;

/** Install the real Fastify logger. Called once from `start()`. */
export function setLogger(logger: FastifyBaseLogger): void {
  current = logger;
}

// Forwarding proxy: `log.info(...)` resolves `info` on the *current* logger at
// call time. Methods are bound to `current` so pino's internal `this` is correct;
// non-function props (e.g. `level`) pass through untouched.
export const log: FastifyBaseLogger = new Proxy({} as FastifyBaseLogger, {
  get(_target, prop) {
    const value = (current as unknown as Record<string | symbol, unknown>)[prop];
    return typeof value === 'function' ? value.bind(current) : value;
  },
}) as FastifyBaseLogger;
