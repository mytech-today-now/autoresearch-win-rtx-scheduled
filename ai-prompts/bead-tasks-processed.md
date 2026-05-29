Using Augmentcode AI (with Augment-extensions) in VS Code:
- Load bead tasks using 'scripts\beads-helpers.ps1' (dot-sourceit to get the 'bd' alias: . .\scripts\beads-helpers.ps1) or call 'scripts\beads-query.ps1' directly
- Check task completion status with "bd list --status open" or "bd ready " - skip any task whose status is not open/in-progress
- For each remaining task in this batch:
    - Claim the task before starting: "bd update <id> --claim"
    - Generate production-quality code that fully satisfies the bead task requirements
    - Follow professional coding standards at all times
    - Do not use stubs, placeholders, or incomplete implementations
    - Do not hallucinate or make up functionality
    - Never reuse the same code pattern for multiple distinct tasks
    - Address every TODO in the relevant files:
        â€¢ If a TODO is relevant, implement the required change
        â€¢ If a TODO is not relevant, explicitly document why it can be ignored
    - Do not proceed until all TODOs are explicitly resolved or justified
(batch 1):
bd-banf	P1	open	autoresearch: Refactor AI provider to ai-powered only	none
bd-u73w	P1	open	autoresearch: Build launch.ps1 foundation	bd-banf
bd-dh79	P1	open	autoresearch: Implement self-installation and upstream clone management	bd-u73w
After completing the tasks above:
- Mark the processed bead task(s) as closed in '[path\to]\autoresearch\.beads\issues.jsonl'.  Do NOT delete the bead task from '[path\to]\autoresearch\.beads\issues.jsonl' â€” only mark it as closed.
- Also record completion in '[path\to]\autoresearch\completed.jsonl'

---

Using Augmentcode AI (with Augment-extensions) in VS Code:
- Load bead tasks using 'scripts\beads-helpers.ps1' (dot-sourceit to get the 'bd' alias: . .\scripts\beads-helpers.ps1) or call 'scripts\beads-query.ps1' directly
- Check task completion status with "bd list --status open" or "bd ready " - skip any task whose status is not open/in-progress
- For each remaining task in this batch:
    - Claim the task before starting: "bd update <id> --claim"
    - Generate production-quality code that fully satisfies the bead task requirements
    - Follow professional coding standards at all times
    - Do not use stubs, placeholders, or incomplete implementations
    - Do not hallucinate or make up functionality
    - Never reuse the same code pattern for multiple distinct tasks
    - Address every TODO in the relevant files:
        â€¢ If a TODO is relevant, implement the required change
        â€¢ If a TODO is not relevant, explicitly document why it can be ignored
    - Do not proceed until all TODOs are explicitly resolved or justified
(batch 2):
bd-jccc	P2	open	autoresearch: Add Scheduled Task and Start Menu integration	bd-dh79
bd-vdpl	P2	open	autoresearch: Enforce runtime governance, state, and process cycling	bd-jccc
bd-sx9a	P2	open	autoresearch: Implement update, removal, version, and diagnostics workflows	bd-vdpl
After completing the tasks above:
- Mark the processed bead task(s) as closed in '[path\to]\autoresearch\.beads\issues.jsonl'.  Do NOT delete the bead task from '[path\to]\autoresearch\.beads\issues.jsonl' â€” only mark it as closed.
- Also record completion in '[path\to]\autoresearch\completed.jsonl'

---

Using Augmentcode AI (with Augment-extensions) in VS Code:
- Load bead tasks using 'scripts\beads-helpers.ps1' (dot-sourceit to get the 'bd' alias: . .\scripts\beads-helpers.ps1) or call 'scripts\beads-query.ps1' directly
- Check task completion status with "bd list --status open" or "bd ready " - skip any task whose status is not open/in-progress
- For each remaining task in this batch:
    - Claim the task before starting: "bd update <id> --claim"
    - Generate production-quality code that fully satisfies the bead task requirements
    - Follow professional coding standards at all times
    - Do not use stubs, placeholders, or incomplete implementations
    - Do not hallucinate or make up functionality
    - Never reuse the same code pattern for multiple distinct tasks
    - Address every TODO in the relevant files:
        â€¢ If a TODO is relevant, implement the required change
        â€¢ If a TODO is not relevant, explicitly document why it can be ignored
    - Do not proceed until all TODOs are explicitly resolved or justified
(batch 3):
bd-n9cw	P2	open	autoresearch: Add acceptance tests and final validation suite
After completing the tasks above:
- Mark the processed bead task(s) as closed in '[path\to]\autoresearch\.beads\issues.jsonl'.  Do NOT delete the bead task from '[path\to]\autoresearch\.beads\issues.jsonl' â€” only mark it as closed.
- Also record completion in '[path\to]\autoresearch\completed.jsonl'
