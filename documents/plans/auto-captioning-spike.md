# Spike: Auto-Captioning VLM Evaluation

## Goal
Determine whether on-device auto-captioning is viable for the no-prompt experience, or if we need server-side captioning.

## Prerequisites
- Latency budget for caption: 200ms (see `AppCoordinator.swift` for current timing)
- Module structure: see `CLAUDE.md` and `ios/Packages/` source

## Questions to Answer
1. Can a distilled BLIP-2 model run on-device in <200ms on iPad Air M1?
2. Is Apple's built-in VLM API available in iPadOS 18 and suitable for sketch captioning?
3. What is the caption quality for rough sketches (blobs, stick figures, outlines)?
4. What is the model size and memory impact on the app?

## Tasks
- [ ] Convert distilled BLIP-2 to Core ML format using coremltools
- [ ] Benchmark latency on 3 iPad models: iPad 9th gen, iPad Air M1, iPad Pro M4
- [ ] Test caption quality on 20 sketch types (rough blobs, stick figures, architecture, animals, faces, landscapes, abstract, etc.)
- [ ] Evaluate Apple's on-device VLM APIs if available in iPadOS 18
- [ ] Measure memory impact (model size in RAM during inference)
- [ ] Test fallback behavior when caption confidence is low

## Decision Criteria
- **Go (on-device):** <200ms on iPad Air M1, acceptable captions for 80%+ of test sketches, model size <200MB
- **Pivot (server-side):** If latency >500ms or caption quality insufficient, implement as backend endpoint alongside generation request
- **Hybrid option:** On-device for fast devices (M1+), server-side for older iPads

## Deliverable
- Benchmark report with latency data across devices
- Caption quality assessment (10 sample sketches with generated captions)
- Go/no-go recommendation with implementation plan

## Timebox
3 days

## Status
Not started — schedule for Phase 2, Week 5
