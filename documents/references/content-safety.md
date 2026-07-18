# Content Safety

Content safety is infrastructure, not a feature. Must be operational before any external testing.

## Apple App Store Requirements

### Guideline 5.1.2(i) — Third-Party AI Disclosure (Nov 2025)
- First-launch consent screen required
- Must specifically identify: inference provider(s), what data is transmitted (sketch images, prompts)
- Generic privacy policy link is insufficient — must be explicit
- Consent screen accessible anytime via Settings

### Guideline 1.2.1(a) — Age Restrictions
- Implement age restriction based on declared user age
- Use Apple's Declared Age Range API (available late 2025)

### UGC Requirements
- Method for filtering objectionable material
- Mechanism to report offensive content
- Ability to block abusive users
- Published contact information

## Design Decisions

- **Two-layer input filtering**: regex blocklist (JSON config, hot-deployable) + text classifier for evasion. **This is the required pre-TestFlight content-safety gate.**
- **Output filtering (DROPPED 2026-06-06)**: an NSFW classifier on every generated image is *not* required. Decision made by Donald; removed from the pre-external-testing gate.
- **Filtered responses**: return 200 with `status: "filtered"` — do NOT count against quota
- **The hosted model (fal.ai FLUX.2-klein) has no content filter we control** — our backend input filter is the primary safety layer
- **User reporting**: "Report this image" button on every output → Slack channel (v1), proper moderation tool (v2)

## Privacy Commitments (must be in consent screen)

1. Sketches and prompts are sent to our server for AI processing
2. Our server forwards them to our own FLUX.2-klein servers hosted on Lambda Cloud, or to fal.ai's hosted FLUX.2-klein model as fallback (providers to disclose under guideline 5.1.2(i); video idle-state animation is archived pending a Lambda port — no RunPod)
3. A throttled sample of sketches and generated images **is stored server-side** for admin review/replay (owner decision 2026-07-15 — see CLAUDE.md constraint #6; retained ≤ `CAPTURE_RETENTION_DAYS` = 14 days), and is not used for training. The privacy policy + App Store data-collection disclosure MUST state this before any external build.
4. Generated images cached for up to 7 days for re-download
5. Your Apple sign-in identifier and email (or an Apple private-relay address, if you choose Hide My Email) are stored to manage your account. (Sign in requests the `.email` scope as of 2026-06-06; Apple returns it only on first authorization.)
6. Link to full privacy policy
