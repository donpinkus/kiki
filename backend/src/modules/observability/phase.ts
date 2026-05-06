/**
 * Cross-stack `phase` log attribute — TS-side mechanism.
 *
 * Same vocabulary as the pod's `flux-klein-server/sentry_init.py` and iOS's
 * `Phase.swift` — `preparing | drawing | animating | reconnecting | session_ending`.
 * The active phase is read at log-emit time by the `beforeSendLog` hook in
 * `index.ts` and attached to every Sentry log entry as `phase: <value>`.
 *
 * Set the active phase by wrapping a section of code in `withPhase('drawing', async () => { ... })`.
 * Async children inherit the value via Node's AsyncLocalStorage; nested
 * `withPhase` blocks override their parent and restore on exit.
 *
 * Logs emitted outside any `withPhase` block carry no `phase` attribute,
 * filterable as `!has:phase` in Sentry's Logs UI.
 */
import { AsyncLocalStorage } from 'node:async_hooks';

export type Phase =
  | 'preparing'
  | 'drawing'
  | 'animating'
  | 'reconnecting'
  | 'session_ending';

export const phaseStorage = new AsyncLocalStorage<Phase>();

export function withPhase<T>(phase: Phase, fn: () => Promise<T>): Promise<T> {
  return phaseStorage.run(phase, fn);
}

export function getActivePhase(): Phase | undefined {
  return phaseStorage.getStore();
}
