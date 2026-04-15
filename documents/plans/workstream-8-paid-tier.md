# Workstream 8: Paid tier + billing

Part of the [scale-to-100-users roadmap](./scale-to-100-users.md). **Stub plan** — surfaced during the open-questions pass on the other seven workstreams. Full plan to be drafted when this workstream is prioritized for implementation.

## 1. Context

Product decision made during scale-to-100 planning: **users get 1 free hour of GPU time, then must subscribe to `Kiki+` at $5/month** to continue generating. This closes the uncapped-free-usage threat that made Workstream 1's per-user quotas critical, and provides the revenue stream that funds the $5k/mo GPU budget.

App Store policy (guideline 3.1.1) requires Apple In-App Purchase for digital subscriptions on iOS apps. Stripe / web checkout isn't an option for this use case. The subscription is auto-renewing, handled entirely by Apple — our backend just verifies entitlement via Apple's StoreKit server-side notifications.

## 2. Scope

Three things have to happen together:

1. **Client-side subscription UI.** "Start your free hour" → draw → "Your hour is up. Subscribe for $5/month" paywall modal → Apple IAP sheet → entitlement active.
2. **Backend entitlement check.** Workstream 1 already provisions the hook (`checkEntitlement(userId)` before semaphore acquire). Workstream 8 wires the real implementation:
   - Per-user GPU-seconds ledger (starts as in-memory Map, moves to Redis with WS5).
   - Apple server-to-server notifications webhook (`POST /v1/auth/apple/notifications`) that updates subscription state.
   - Receipt validation for subscription purchase confirmation.
3. **App Store Connect setup.** Create the `kiki.plus.monthly` auto-renewable subscription product, price tier, localized descriptions, tax category. One-time task per region.

## 3. Dependencies

- **WS1 (Auth) — blocker.** Entitlement is keyed on `userId`. Can't ship WS8 without it.
- **WS5 (Redis registry) — recommended-before.** Per-user hour ledger should live in Redis so deploys don't reset everyone's free hour. Shippable on in-memory storage first if WS5 slips.
- **WS4 (Cost monitoring).** `/v1/ops/cost` should break down cost by (user has subscription vs free-tier) so we can verify unit economics (MRR > GPU spend).

## 4. Open questions (to answer before full plan)

1. **Free hour semantics.** 60 minutes of *active GPU time* (what we bill for) or 60 minutes of *calendar time from first use* (what users intuitively expect)? Leaning: active GPU time — aligns with our cost model.
2. **Paywall UX.** Hard stop at 60 min ("subscribe to continue") or grace ("you've used your free hour — subscribe to keep going")? Affects first-impression UX.
3. **Annual plan?** Apple IAP supports multiple durations. Add `$50/year` (save $10) at launch or wait for data? Lean: skip for v1.
4. **Free trial on the paid plan?** Apple supports "7-day free trial → $5/mo." Different from the free hour. Overlapping free gives double coverage; one-free-hour-only gives cleaner accounting.
5. **Regional pricing / tax.** Apple auto-handles most of this but we need to pick tier (e.g. Tier 5 = $4.99 in most regions).
6. **Refund policy.** Apple handles refund requests; we just see the notification. How do we react (restore free hour? block user?).
7. **What happens to pods when subscription lapses mid-session?** Let the session finish, or kill the pod immediately? Lean: let the session finish (one final frame isn't expensive).

## 5. Rough effort

~2–3 days. Apple IAP is well-documented but server-side verification + webhook signing are finicky to get right the first time. StoreKit 2 (iOS 15+) massively simplifies the client side vs the old StoreKit — good news since we're iPadOS 17+ only.

## Critical files (projected)

- `backend/src/modules/entitlement/index.ts` (new — scaffolded by WS1, real impl here)
- `backend/src/routes/auth.ts` (add `/v1/auth/apple/notifications` webhook + `/v1/auth/receipt` validation)
- `backend/src/modules/auth/appleStoreKit.ts` (new — receipt validation, notification verification)
- `ios/Kiki/App/PaywallView.swift` (new)
- `ios/Packages/NetworkModule/Sources/NetworkModule/SubscriptionService.swift` (new — StoreKit 2 wrapper)
- `ios/Kiki/App/AppCoordinator.swift` (gate entry to drawing on entitlement)

## Status

This is a stub — enough to capture scope and open questions. Full detailed plan (design, test plan, rollout) to be written when this workstream is picked up for implementation.
