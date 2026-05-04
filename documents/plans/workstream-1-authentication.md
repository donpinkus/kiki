# Workstream 1: Authentication

Part of the [scale-to-100-users roadmap](./scale-to-100-users.md).

## 1. Context

Kiki today ships a `?session=<uuid>` query-param "session identity" generated on first launch in `UserDefaults` and stored unauthenticated. Anyone who observes or guesses a UUID can open a WebSocket to `/v1/stream` and cause the backend to rent a ~$0.55/hr RTX 5090 pod for up to 10 minutes after the last frame. The roadmap names this as blocker #1 for scaling to 100 concurrent users: it is both a cost-containment problem (unauthenticated GPU vouchers) and a TestFlight gating problem (the App Store age gate per guideline 1.2.1(a) and AI-disclosure consent per 5.1.2(i) called out in `CLAUDE.md` both presuppose a stable user identity, not a per-install UUID). Authentication is sequenced first because every other workstream (cost monitoring, rate limits, Redis registry, per-user quotas) needs a `userId` that the backend trusts.

## 2. Current state

**Present:**
- Fastify auth stub at `backend/src/modules/auth/index.ts:9-22` that decorates `request.userId` with the literal string `'mock-user-id'` after skipping `/health`. Has an explicit TODO for Phase 2 JWT validation.
- WebSocket route `backend/src/routes/stream.ts:109-115` extracts `session` via `extractSessionId(request.url)` and closes with `1008 "missing session"` if absent — this is the only gate today.
- Orchestrator registry `backend/src/modules/orchestrator/orchestrator.ts:49` is `Map<string, Session>` keyed by `sessionId`, with `getOrProvisionPod(sessionId, onStatus)` at line 100 as the single entry point.
- iOS side: `ios/Packages/NetworkModule/Sources/NetworkModule/SessionIdentity.swift:12-19` reads/generates a UUID in `UserDefaults` under key `"kiki.sessionId"`. Used once in `AppCoordinator.swift:369` as the sole query item on the WS URL.
- Fastify already has `@fastify/cors` and `@fastify/websocket` registered. `request.userId` is already a typed decoration.
- `backend/src/config/index.ts` validates required env on boot and throws if missing. Good hook point for `JWT_*` and `APPLE_*` variables.
- Error types: `AppError`, `RateLimitedError` (429 + Retry-After), `ProviderError` in `backend/src/errors.ts`.

**Absent:**
- Zero JWT dependencies installed.
- No Apple Sign In on iOS (no `AuthenticationServices` imports).
- No user-model persistence on backend. No user table. No Keychain storage on iOS.
- No rate limiting of any kind.
- `authPlugin` is registered but does not gate WebSocket handshakes.

## 3. Detailed design

### 3.1 End-to-end flow

```
[iPad]                                                  [Railway backend]                    [Apple]
  │                                                            │                                 │
  │  SignInWithAppleButton → ASAuthorizationAppleIDProvider    │                                 │
  │  ───── identityToken (JWS signed by Apple) ──────────────▶ │                                 │
  │                                                            │   verify JWS against            │
  │                                                            │   https://appleid.apple.com/    │
  │                                                            │   auth/keys (JWKS, cached)      │
  │                                                            │   → extract `sub` = Apple userID│
  │                                                            │   upsert user row / memory map  │
  │  ◀──── { accessToken (JWT, 1h), refreshToken (30d) } ──────│                                 │
  │  store both in Keychain (kSecClassGenericPassword)         │                                 │
  │                                                            │                                 │
  │  WSS /v1/stream (Authorization: Bearer <accessToken>)      │                                 │
  │  ─────────────────────────────────────────────────────▶    │   verify HS256, check exp,      │
  │                                                            │   extract userId, use as registry key
```

### 3.2 New HTTP endpoints (backend)

Add `backend/src/routes/auth.ts`:

- `POST /v1/auth/apple` — body `{ identityToken, nonce? }` → `{ accessToken, refreshToken, expiresIn, userId }`
- `POST /v1/auth/refresh` — body `{ refreshToken }` → `{ accessToken, refreshToken, expiresIn }`
- `POST /v1/auth/logout` (optional v1) — header `Authorization: Bearer <accessToken>` → 204

`POST /v1/auth/apple` flow:
1. Fetch + cache Apple's JWKS from `https://appleid.apple.com/auth/keys` (cache 24h, `kid`-indexed).
2. Verify the incoming `identityToken` signature, `aud` = our bundle ID, `iss` = `https://appleid.apple.com`, `exp` not expired.
3. Extract `sub` (Apple's opaque stable user ID) and optional `email`.
4. Upsert into an in-memory `Map<appleSub, User>` for v1. A User row is `{ userId: UUIDv4, appleSub, email?, createdAt, ageGateAcceptedAt?, aiConsentAcceptedAt? }`. Persist to SQLite or JSON later.
5. Issue `{ accessToken, refreshToken }` and return.

### 3.3 Backend module additions

Add `backend/src/modules/auth/jwt.ts`:

```ts
export interface AccessClaims {
  sub: string;        // our internal userId (UUIDv4)
  typ: 'access';
  iat: number;
  exp: number;
  jti: string;
}
export interface RefreshClaims { sub: string; typ: 'refresh'; iat: number; exp: number; jti: string; }
export function signAccess(userId: string): string;
export function signRefresh(userId: string): string;
export function verifyAccess(token: string): AccessClaims;  // throws on invalid
export function verifyRefresh(token: string): RefreshClaims;
```

Add `backend/src/modules/auth/appleVerifier.ts`:

```ts
export async function verifyAppleIdentityToken(
  identityToken: string,
): Promise<{ appleSub: string; email?: string }>;
```

Rewrite `backend/src/modules/auth/index.ts` to gate non-public HTTP paths with a `preHandler` that verifies `Authorization: Bearer <jwt>` and sets `req.userId`. WS gate is done explicitly inside `stream.ts` because `preHandler` + `@fastify/websocket` is awkward.

### 3.4 Token-over-WebSocket: which channel?

Three options considered:

- **A. `Authorization` header on the upgrade request.** Cleanest. `URLSessionWebSocketTask` on iOS supports this via `URLRequest`. Recommended.
- **B. `Sec-WebSocket-Protocol` subprotocol (`bearer.<token>`).** Leaks tokens into intermediate proxy logs. Reject.
- **C. First-message auth.** Requires the backend to provision/queue before auth — defeats the whole point. Reject.

**Decision: A.** `URLSessionWebSocketTask` constructed from a `URLRequest` carrying `Authorization: Bearer <jwt>`. Fastify reads `request.headers.authorization` inside the WS handler.

The `?session=<uuid>` query param is **removed**. The backend keys everything on `userId` from the JWT.

### 3.5 iOS changes

Add `ios/Packages/NetworkModule/Sources/NetworkModule/AuthService.swift`:

```swift
public actor AuthService {
    public struct TokenBundle: Codable, Sendable {
        public let accessToken: String
        public let refreshToken: String
        public let expiresAt: Date
        public let userId: String
    }
    public init(backendURL: URL, keychain: KeychainStore = .default)
    public func signInWithApple(identityToken: String, nonce: String?) async throws -> TokenBundle
    public func currentAccessToken() async throws -> String   // auto-refreshes if <60s to expiry
    public func signOut() async
}
```

Add `ios/Packages/NetworkModule/Sources/NetworkModule/KeychainStore.swift` — thin wrapper over `SecItemAdd/Copy/Delete` for `kSecClassGenericPassword` with service `"com.donpinkus.kiki.auth"`.

Add `ios/Kiki/App/SignInView.swift` — `SignInWithAppleButton` (AuthenticationServices). Gate `AppCoordinator.currentScreen` on auth state. Age-gate + AI-disclosure consent render after sign-in and before first drawing; their accepted-at timestamps go back to the backend.

Modify `AppCoordinator.swift:365-382` to:
1. Fetch current access token via `AuthService.currentAccessToken()`.
2. Build `URLRequest` with `Authorization: Bearer <token>` header.
3. Remove the `?session=` query item.

Update `StreamWebSocketClient.init` to accept a `URLRequest` instead of `URL`. Delete `SessionIdentity.swift`.

### 3.6 Two-devices-per-Apple-ID — DECIDED: one pod per user, last-connect wins

When device B opens a WebSocket for a userId that already has an active session:
1. Look up existing `Session`; if `status === 'ready'`, close device A's relay socket with `1000 "replaced by newer session"`.
2. Attach device B's socket to the same pod.
3. Device A's client shows "session moved to another device" banner.

Why:
- Kiki is a single-canvas-per-user experience. Two devices drawing on the same pod concurrently interleave frames → garbage output.
- Two pods per user = 2× cost with no UX upside.
- Keeps the registry 1:1 `userId → Session`.

## 4. JWT specifics

| Field | Value |
|---|---|
| Access token algorithm | HS256 (symmetric, single secret on Railway) |
| Refresh token algorithm | HS256, different secret (`JWT_REFRESH_SECRET`) |
| Access token TTL | 1 hour |
| Refresh token TTL | 30 days |
| Rotation | Refresh endpoint returns a **new** refresh token; old `jti` added to in-memory revocation set (graduates to Redis when WS5 lands) |
| Secret source | Railway env: `JWT_ACCESS_SECRET` + `JWT_REFRESH_SECRET` (32+ random bytes each, different). Validated at boot like existing `RUNPOD_*` vars. |
| Secret rotation | Support two secrets simultaneously (`*_SECRET` + `*_SECRET_PREVIOUS`): sign with current, verify against both. |
| Claims (access) | `{ sub: userId, typ: 'access', iat, exp, jti }` |
| Claims (refresh) | `{ sub: userId, typ: 'refresh', iat, exp, jti }` |
| Clock skew | ±30s |

`sub` is our minted UUID, not Apple's `sub` (Apple's `sub` is opaque per (team, app); if we ever add another auth provider, we don't want provider-specific identifiers leaking). Mapping table: `Map<appleSub, userId>` owned by auth module.

HS256 over RS256: single backend instance signing + verifying, no third-party token consumer; simpler; smaller tokens. HS256 still works at horizontal scale (all instances share the same env secret).

Library choice: **`jose`**. Better ESM/TS ergonomics than `jsonwebtoken`; `createRemoteJWKSet` covers Apple identity-token verification.

## 5. Registry key change

Rename `sessionId` → `userId` throughout:

- `orchestrator.ts:36` — rename field in `Session` interface
- `orchestrator.ts:49` — `const registry = new Map<string /* userId */, Session>()`
- `orchestrator.ts:100` — `getOrProvisionPod(userId, onStatus)`
- `orchestrator.ts:162,167` — `touch(userId)`, `sessionClosed(userId)`
- `orchestrator.ts:270` — pod naming: `${POD_PREFIX}${userId.slice(0, 16)}`. Keep `kiki-session-` prefix for backward compat with reconcile + `stop-pods.yml`.
- `stream.ts` — every `sessionId` reference becomes `userId`
- Rename log field `sessionId` → `userId` throughout

**Migration:** there's no persistent state. In-memory registry drops every redeploy; `reconcileOrphanPods()` kills `kiki-session-*` pods at boot. So deploying the auth-gated backend = clean slate. Users re-auth silently (Apple Sign In is silent after first consent). Announce in beta Slack.

## 5.5 Paid tier entitlement (NEW — decided during planning)

Users get **1 free hour of GPU time**, then must subscribe to `Kiki+` at **$5/month** via Apple IAP (StoreKit 2) to continue. Full billing integration lives in Workstream 8 — this section covers only what Workstream 1 needs to provide.

### Backend entitlement check

`getOrProvisionPod` calls a new `entitlement.check(userId)` gate before acquiring the semaphore:

```ts
// backend/src/modules/entitlement/index.ts (new)
export interface EntitlementStatus {
  allowed: boolean;
  reason?: 'free_exhausted' | 'subscription_expired' | 'account_disabled';
  freeHoursRemaining?: number;
  subscriptionActive?: boolean;
}
export async function checkEntitlement(userId: string): Promise<EntitlementStatus>;
```

Gate logic:
- If user has `> 0` free hours remaining → allow, note `free_tier`
- Else if user has active subscription → allow, note `subscription`
- Else → deny with `reason: 'free_exhausted'`, client shows paywall modal

### Per-user hour tracking

Track cumulative GPU-seconds consumed per user. On pod termination (reaper or replacement), compute `uptimeSeconds` × `1/3600` → subtract from free-hour budget or log against subscription.

Storage: in-memory Map<userId, { totalSeconds, freeHoursGrantedAt, subscriptionId? }> for v1 (lives in entitlement module). When Workstream 5 lands, this moves to Redis alongside session data.

### Interface with IAP (Workstream 8)

Apple sends StoreKit 2 server-side notifications (`APP_STORE_SERVER_NOTIFICATIONS_V2`) to a webhook we'll add in WS8. Webhook updates the entitlement map with `subscriptionActive: true/false`.

For this workstream: just stub the subscription side — `subscriptionActive` always returns `false` so the gate only honors the free hour. WS8 wires the real subscription check.

### Env knob for adjustability

`FREE_TIER_SECONDS` env var, default `3600` (1 hour). Lets you bump the free tier to 2 hours etc. without a code change.

## 6. Per-user rate limiting

**Approach: in-memory token bucket, one entry per user.**

Add `backend/src/modules/auth/rateLimiter.ts`:

```ts
export function checkProvisionQuota(userId: string): { allowed: boolean; retryAfterSec?: number };
export function registerActivePod(userId: string): void;
export function releaseActivePod(userId: string): void;
export function getActivePodCount(userId: string): number;
```

Starting limits:

| Limit | Value | Why |
|---|---|---|
| Max active pods per user | 1 | One canvas per user |
| Provisions per user per hour | 5 | Preemption + reconnect cluster; 5 absorbs with headroom |
| Provisions per user per 24h | 30 | Daily spend cap: ~30 × $0.20 ≈ $6/day per user |
| Global concurrent cold-starts | 5 (existing `MAX_CONCURRENT_PROVISIONS`) | Unchanged |

Integration: `getOrProvisionPod` calls `checkProvisionQuota(userId)` first; throws `RateLimitedError` if denied. `stream.ts` catches this and sends `{ type: 'error', code: 'rate_limited', retryAfterSec }` before closing 1008. Client surfaces dedicated "too many sessions" UI rather than generic reconnect.

When WS5 lands, rate-limit state moves to Redis `INCR` + `EXPIRE`.

## 7. Test plan

**Automated (backend):**
- `jwt.test.ts` — `signAccess` → `verifyAccess` round-trip; reject expired, wrong-alg (`alg: 'none'`), tampered tokens
- `appleVerifier.test.ts` — mock JWKS; verify signature, issuer, audience, expiry
- `rateLimiter.test.ts` — bucket refills over time; 5 in one hour succeed; 6th denied; 24h cap
- `stream.test.ts` — WS upgrade without/with invalid/valid `Authorization` behaves correctly
- `auth.test.ts` — `/v1/auth/apple` happy path, refresh rotation, refresh-reuse denied

**Automated (iOS):**
- `AuthServiceTests.swift` — Keychain round-trip, auto-refresh at expiry, refresh failure propagates

**Manual end-to-end:**
1. Fresh install → sign in with Apple → sign-in view dismisses
2. Enter drawing → WS connects with `Authorization` header (check logs for `userId`)
3. Force-quit → relaunch → silent resume (token in Keychain)
4. Sign out → Keychain cleared, sign-in view returns
5. Second simulator same Apple ID → device A's session closes with 1000, device B resumes
6. Modify system clock +2h → access token auto-refreshes on stream start
7. Spam 6 rapid session starts → 6th hits rate-limit UI
8. Modify Keychain token → 1008 close + clean sign-in prompt

## 8. Rollout

**Deploy order: backend first (dual-mode), client second, flip flag third.**

Phase 1 — Backend dual-mode:
- Backend supports **both** `?session=<uuid>` AND `Authorization: Bearer <jwt>`
- If JWT present, validate, use `userId` as key
- If `?session=` present and `AUTH_REQUIRED=false`, fall back to today's behavior
- `/v1/auth/apple` + `/v1/auth/refresh` live from day one

Phase 2 — iOS TestFlight:
- Sign-in-with-Apple screen + Keychain + JWT-bearing WebSocket
- Backend still accepts both; old installs keep working

Phase 3 — Flip:
- After TestFlight adoption verified (~48h or <5% legacy in logs), set `AUTH_REQUIRED=true` on Railway
- Legacy clients get 401 + "please update"

**Rollback:**
- Phase 1: `railway variable set "AUTH_REQUIRED=false"` + redeploy previous backend. Zero user impact.
- Phase 2: previous TestFlight build remains installable. Remote Config flag (`enforceAuthentication`) can tell clients to skip sign-in if backend is broken.
- Phase 3: flip `AUTH_REQUIRED` back to `false`.

## 9. Open questions

### DECIDED
- **Anonymous fallback:** ❌ Apple Sign In only for v1. Hard-require.
- **Age gate:** 17+.
- **Device policy:** One pod per user, last-connect wins.

### Still open
1. **Email collection.** Apple optionally returns email on first consent. Recommend no for beta (simpler privacy story).
2. **Session UUID persistence for analytics.** Today's UUID doubles as install ID. Recommend delete; userId is a superset.
3. **Refresh token biometric protection?** Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` is fine for beta; skip biometric for v1.
4. **Logout semantics.** Immediate pod terminate or let idle out? Recommend immediate terminate — explicit user intent.
5. **Device B takeover UX copy.** Confirm message text for device A ("Kiki is now active on another iPad" or similar).

## 10. Dependencies

**Blocks:**
- **Workstream 4 (Cost monitoring):** `/v1/ops/cost` auth gating needs JWT middleware from this workstream
- **Workstream 5 (Redis registry):** Redis keys are `session:<userId>` — needs `userId` to exist
- **Per-user quotas / paid tiers (post-100):** All downstream monetization assumes `userId`
- **TestFlight submission:** Age gate + AI-disclosure consent attached to User record

**Blocked by:** Nothing. This is the root of the dependency graph.

**Other workstreams will also touch:**
- `backend/src/modules/orchestrator/orchestrator.ts` — WS5 replaces in-memory `Map`. Coordinate: WS5 assumes userId keys. WS6/WS7 also touch this file.
- `backend/src/routes/stream.ts` — WS7 modifies preemption handling here; merge-conflict surface is the `relay.onClose` block.
- `backend/src/config/index.ts` — WS4 adds webhook config; WS5 adds Redis URL. Land in dependency order.
- `ios/Packages/NetworkModule` — this workstream adds AuthService + KeychainStore.

## Critical files

- `/Users/donald/Desktop/kiki_root/backend/src/modules/auth/index.ts` (rewrite)
- `/Users/donald/Desktop/kiki_root/backend/src/modules/auth/jwt.ts` (new)
- `/Users/donald/Desktop/kiki_root/backend/src/modules/auth/appleVerifier.ts` (new)
- `/Users/donald/Desktop/kiki_root/backend/src/modules/auth/rateLimiter.ts` (new)
- `/Users/donald/Desktop/kiki_root/backend/src/routes/auth.ts` (new)
- `/Users/donald/Desktop/kiki_root/backend/src/routes/stream.ts` (JWT extraction + key rename)
- `/Users/donald/Desktop/kiki_root/backend/src/modules/orchestrator/orchestrator.ts` (sessionId → userId rename)
- `/Users/donald/Desktop/kiki_root/backend/src/config/index.ts` (add JWT secrets, `AUTH_REQUIRED`)
- `/Users/donald/Desktop/kiki_root/ios/Packages/NetworkModule/Sources/NetworkModule/AuthService.swift` (new)
- `/Users/donald/Desktop/kiki_root/ios/Packages/NetworkModule/Sources/NetworkModule/KeychainStore.swift` (new)
- `/Users/donald/Desktop/kiki_root/ios/Packages/NetworkModule/Sources/NetworkModule/StreamWebSocketClient.swift` (accept URLRequest)
- `/Users/donald/Desktop/kiki_root/ios/Kiki/App/SignInView.swift` (new)
- `/Users/donald/Desktop/kiki_root/ios/Kiki/App/AppCoordinator.swift` (fetch JWT before stream start)
- Delete: `/Users/donald/Desktop/kiki_root/ios/Packages/NetworkModule/Sources/NetworkModule/SessionIdentity.swift`
