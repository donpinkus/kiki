# Data Models

## Client-Side (SwiftData)

### DrawingSession
```swift
@Model
class DrawingSession {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var currentPrompt: String?        // nil if no user prompt
    var currentStylePreset: String    // StylePreset enum raw value
    var currentAdherence: Float       // 0.0-1.0, default 0.7
    var currentSeed: Int?             // nil = random
    var dividerPosition: Float        // 0.0-1.0, default 0.55
}
```

### GeneratedImage
```swift
@Model
class GeneratedImage {
    var id: UUID
    var sessionId: UUID               // FK to DrawingSession
    var createdAt: Date
    var mode: String                  // "preview" or "refine"
    var prompt: String?               // User prompt (nil if auto-captioned)
    var autoCaption: String?          // VLM-generated caption
    var stylePreset: String
    var adherence: Float
    var seed: Int                     // Seed used by provider
    var sketchThumbnailPath: String   // Local file path to sketch thumbnail
    var imagePath: String             // Local file path to downloaded generated image
    var imageURL: String?             // Remote signed URL (expires in 7 days)
    var latencyMs: Int                // End-to-end generation latency
    var provider: String              // "fal" or "replicate"
    var wasSaved: Bool                // User explicitly saved to gallery
}
```

### StylePreset (Enum)
```swift
enum StylePreset: String, CaseIterable, Codable {
    case photoreal
    case anime
    case watercolor
    case storybook
    case fantasy
    case ink
    case neon
}
```

### GenerationMode (Enum)
```swift
enum GenerationMode: String, Codable {
    case preview
    case refine
}
```

## Server-Side (PostgreSQL via Drizzle ORM)

### users
```typescript
export const users = pgTable('users', {
  id: uuid('id').primaryKey().defaultRandom(),
  appleUserId: text('apple_user_id').notNull().unique(),
  tier: text('tier').notNull().default('free'), // 'free' | 'plus' | 'pro'
  createdAt: timestamp('created_at').defaultNow().notNull(),
});
```

### usage_log
```typescript
export const usageLog = pgTable('usage_log', {
  id: uuid('id').primaryKey().defaultRandom(),
  userId: uuid('user_id').references(() => users.id).notNull(),
  date: date('date').notNull(),
  previewCount: integer('preview_count').notNull().default(0),
  refineCount: integer('refine_count').notNull().default(0),
}, (table) => ({
  userDateIdx: uniqueIndex('user_date_idx').on(table.userId, table.date),
}));
```

### generation_events
```typescript
export const generationEvents = pgTable('generation_events', {
  id: uuid('id').primaryKey().defaultRandom(),
  userId: uuid('user_id').references(() => users.id).notNull(),
  sessionId: uuid('session_id').notNull(),
  requestId: uuid('request_id').notNull(),
  mode: text('mode').notNull(),         // 'preview' | 'refine'
  provider: text('provider').notNull(), // 'fal' | 'replicate'
  latencyMs: integer('latency_ms'),
  status: text('status').notNull(),     // 'completed' | 'filtered' | 'error' | 'cancelled'
  contentFilterResult: jsonb('content_filter_result'),
  createdAt: timestamp('created_at').defaultNow().notNull(),
});
```

### content_filter_log
```typescript
export const contentFilterLog = pgTable('content_filter_log', {
  id: uuid('id').primaryKey().defaultRandom(),
  generationEventId: uuid('generation_event_id').references(() => generationEvents.id).notNull(),
  filterType: text('filter_type').notNull(), // 'prompt' | 'image'
  result: text('result').notNull(),          // 'passed' | 'blocked'
  categories: jsonb('categories'),           // e.g., ["nsfw", "violence"]
  createdAt: timestamp('created_at').defaultNow().notNull(),
});
```

## Notes
- No sketch images or prompts stored server-side beyond request lifecycle (privacy by design)
- Exception: flagged content logged in `content_filter_log` for compliance auditing
- Client stores generated images locally (file path in `imagePath`) and caches remote URL
- `usage_log` is the source of truth for quota enforcement (verified server-side via Redis cache)
