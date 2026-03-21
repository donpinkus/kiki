# Coding Conventions

## Swift (iOS)

### Language & Tooling
- Swift 5.9+ with strict concurrency checking enabled
- SwiftLint for linting, SwiftFormat for formatting
- Follow Apple's Swift API Design Guidelines

### Naming
- Types: `PascalCase` — `AppCoordinator`, `SketchSnapshot`
- Properties/methods: `camelCase` — `canvasDidChange`, `latestRequestId`
- Enum cases: `camelCase` — `StylePreset.watercolor`
- File naming: one primary type per file, file named after the type — `AppCoordinator.swift`

### Access Control
- Default to `internal` (implicit)
- `private` for implementation details
- `public` only on module boundary APIs (package public surface)
- Never use `open` unless designing for subclassing (we shouldn't be)

### Code Organization
- `// MARK: -` to section files (Properties, Lifecycle, Public API, Private, etc.)
- SwiftUI views: keep `body` under ~30 lines. Extract subviews as computed properties or separate types.
- Every SwiftUI view file must have a `#Preview` macro at the bottom

### Error Handling
- Use Swift's native `throw`/`catch`, not `Result` types
- Define module-specific error enums conforming to `Error`
- No force unwraps (`!`) except in tests
- No implicitly unwrapped optionals

### Concurrency
- All async work off main thread
- Only UI updates on `@MainActor`
- Use `actor` for shared mutable state when needed
- Prefer `async/await` over Combine. Combine only for PencilKit delegate bridging.
- Use `Task {}` for launching async work from sync contexts
- Use `TaskGroup` for parallel async operations

### Types
- Prefer value types (`struct`, `enum`) over `class` unless identity/reference semantics needed
- `@Observable` classes for ViewModels (requires reference semantics for SwiftUI)
- `@Model` classes for SwiftData entities
- Protocols define module boundaries. Use noun names (e.g., `SketchPreprocessing`)

### Documentation
- `///` doc comments on `public` APIs only
- No doc comments on `private`/`internal` unless logic is non-obvious
- Keep comments minimal — code should be self-documenting

### SwiftUI Patterns
- `@State` for view-local state
- `@Environment` for injected dependencies (AppCoordinator)
- `@Bindable` for binding to `@Observable` objects
- No `@ObservedObject` / `@StateObject` / `@Published` (those are Combine-based)

## TypeScript (Backend)

### Language & Tooling
- TypeScript strict mode — no `any` types, use `unknown` and narrow
- ESM modules (`import`/`export`), not CommonJS
- ESLint + Prettier for linting/formatting
- Node.js 20+

### Naming
- Variables/functions: `camelCase` — `generateImage`, `sessionTracker`
- Types/interfaces: `PascalCase` — `GenerateRequest`, `ProviderAdapter`
- Constants: `SCREAMING_SNAKE` — `MAX_PROMPT_LENGTH`, `STYLE_PRESETS`
- Files: `kebab-case` — `prompt-filter.ts`, `session-tracker.ts`

### Types
- Prefer `interface` over `type` for object shapes
- Use `type` for unions and intersections
- Use Fastify's schema-based validation on all route inputs — no manual validation

### Async
- `async/await` throughout — no raw callbacks, no `.then()` chains

### Error Handling
- Throw typed errors extending a base `AppError` class with HTTP status codes
- Example: `throw new QuotaExceededError(userId, tier)` → 429
- Fastify error handler maps `AppError` subclasses to HTTP responses

### Logging
- Use Fastify's built-in logger (`request.log`) — structured JSON
- Always include: `requestId`, `sessionId`, `userId`
- Log levels: `error` (failures), `warn` (degraded), `info` (key events), `debug` (dev)

### Configuration
- All env vars accessed through `src/config/index.ts` — never `process.env` directly elsewhere
- Config is validated at startup with a schema. Missing required vars = crash immediately.

### Module Pattern
- Each backend module exports a Fastify plugin
- Plugins register their own routes, hooks, and decorators
- Dependencies between plugins handled via Fastify's dependency system

### Testing
- Unit tests: Vitest
- Integration tests: Vitest + Supertest against app instance
- Mock providers in unit tests (never call real APIs in CI)
- Test files next to source: `*.test.ts` or in `tests/` directory
