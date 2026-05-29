# Autoresearch Delta Summary

## Source

This delta summary is derived from `refactor-autoresearch.md` and complements `proposal.md`, `design.md`, and `specs/autoresearch/spec.md`.

## Added Capability

### `autoresearch`

Adds a Windows idle-time automation wrapper for Andrej Karpathy's upstream autoresearch repository.

The new capability includes:
- Exclusive AI integration through `ai-powered`.
- Per-user wrapper installation and upstream clone management.
- Idle-only Windows Scheduled Task registration.
- Self-contained PowerShell launch, update, remove, version, and debug workflows.
- Rolling runtime budget enforcement and durable state.
- Idempotent Start Menu shortcut generation.
- Structured JSON Lines diagnostics.
- Acceptance coverage for idempotency, safety, and provider exclusivity.

## Modified Capabilities

None. There are no existing OpenSpec capabilities in `openspec/specs/` to modify.

## Removed Capability Surface

Legacy Augment Code AI and other external AI provider integrations are removed from the implementation surface. This is represented as part of the new `autoresearch` capability because there is no existing capability spec to modify.

## Archive Notes

When this change is implemented and archived, `specs/autoresearch/spec.md` is expected to become the canonical project specification for the Windows idle-time autoresearch wrapper.