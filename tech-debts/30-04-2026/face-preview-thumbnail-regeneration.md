# Face Preview Thumbnail Regeneration

## Context

Face reference and suggestion cards render cropped face previews. Timeline thumbnails can also fail for assets such as motion/live photos. When a preview URL fails, the current UI can enqueue Immich's existing asset thumbnail regeneration job for the related assets.

## Debt

The available job regenerates asset thumbnails, not a dedicated face-preview artifact. This is a pragmatic recovery path for broken previews, but it does not precisely target the face crop/frame cache when the underlying issue is specific to video-frame extraction or face-preview storage.

## Risk

- A user can request regeneration and still see a broken face preview or timeline thumbnail until the related asset/frame pipeline recreates the missing artifact.
- Bulk regeneration can enqueue more work than needed because it operates at asset level.

## Proposed Fix

- Add a backend use case dedicated to face-preview regeneration by `faceId`.
- Expose a batch endpoint for `faceIds`.
- Reuse the same UI actions, but target face previews directly instead of asset thumbnail jobs when available.

## Current Mitigation

The UI exposes per-face, visible-bulk, broken-only, and per-timeline-thumbnail regeneration actions using the existing `RegenerateThumbnail` asset job. This keeps the feature safe and reversible without adding a new storage pipeline during the current iteration.
