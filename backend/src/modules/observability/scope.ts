/**
 * `inBackgroundScope(name, fn)` — wrap a periodic-interval / background-task
 * callback in its own Sentry isolation scope with no user attribution, then
 * tag every log emitted within (via AsyncLocalStorage read by `beforeSendLog`
 * in `index.ts`) with `background_task: <name>`.
 *
 * Why: Sentry's `setUser` writes to the current isolation scope, and that
 * scope's lifetime is aligned with HTTP request handlers (via
 * `fastifyIntegration`), not with long-lived contexts (WS connections,
 * background timers). When `Sentry.setUser` was being called from the WS
 * handler in `routes/stream.ts`, the user state leaked onto the global
 * scope, and every subsequent `setInterval` callback (Cost tick, reaper,
 * reconcile) inherited it — every Cost tick log row carrying the most
 * recent WS user's id, distorting `user_id:<X>` queries.
 *
 * Architectural rule: backend user attribution comes from the structured
 * `userId` Pino field (promoted to `user_id` Sentry log attribute by
 * `beforeSendLog` in `index.ts`), not from `Sentry.setUser` ambient state.
 * Background-process callbacks must run via this helper so their logs
 * never inherit ambient user state and are filterable as a class via
 * `background_task:<name>`.
 *
 * Why AsyncLocalStorage instead of just `scope.setTag`: scope tags
 * propagate to errors/spans but not to Sentry's Logs product (verified
 * empirically — Cost tick logs after the first leak-fix deploy carried no
 * `background_task` attribute despite `scope.setTag('background_task', ...)`
 * being set in this helper). Same gotcha pod-side `before_send_log`
 * already works around. Mirrors the `phase.ts` pattern.
 */
import { AsyncLocalStorage } from 'node:async_hooks';
import * as Sentry from '@sentry/node';

const backgroundTaskStorage = new AsyncLocalStorage<string>();

export function getActiveBackgroundTask(): string | undefined {
  return backgroundTaskStorage.getStore();
}

export function inBackgroundScope<T>(
  name: string,
  fn: () => Promise<T> | T,
): Promise<T> {
  return Sentry.withIsolationScope(async (scope) => {
    scope.setUser(null);
    scope.setTag('background_task', name);
    return backgroundTaskStorage.run(name, async () => fn());
  });
}
