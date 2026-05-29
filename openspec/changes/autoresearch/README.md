# Autoresearch OpenSpec Change

This change specifies a Windows-only idle-time autoresearch wrapper powered exclusively by the `ai-powered` npm package.

## Purpose

The implementation will install and run a managed wrapper from the user's per-user Programs area, maintain a local clone of `https://github.com/karpathy/autoresearch`, register an idle-triggered Windows Scheduled Task, and govern each upstream run with strict runtime budgets.

## Artifact Map

- `proposal.md`: Motivation, scope, capability declaration, and impact.
- `design.md`: Architecture, decisions, risks, migration plan, and open questions.
- `deltas.md`: Human-readable summary of added and removed behavior surfaces.
- `specs/autoresearch/spec.md`: Normative requirements and acceptance scenarios.
- `tasks.md`: Trackable implementation checklist.
- `examples/powershell-usage.md`: Required PowerShell usage examples for the launcher.
- `tests/acceptance-tests.md`: Acceptance test plan derived from the spec.
- `metadata.json`: Machine-readable summary of key settings and paths.

## Capability

The single capability is `autoresearch`. It covers installation, scheduling, launch behavior, runtime limits, updates, removal, diagnostics, logging, dependency rules, and acceptance tests.

## Validation

Use OpenSpec status and validation commands from the repository root:

```powershell
openspec status --change "autoresearch"
openspec validate --change "autoresearch"
```

Implementation work should not begin until `tasks.md` is complete and the change is apply-ready.