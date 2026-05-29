## 1. Dependency and Provider Refactor

- [ ] 1.1 Inspect package manifests, lockfiles, source files, and configuration for existing AI provider dependencies and settings
- [ ] 1.2 Add or confirm the `ai-powered` npm dependency through the package manager
- [ ] 1.3 Replace all AI calls with a single `ai-powered` integration path
- [ ] 1.4 Remove Augment Code AI and all other external AI service SDKs, API key settings, and provider-specific configuration
- [ ] 1.5 Add a static verification check that fails if disallowed AI provider references return

## 2. Launcher Foundation

- [ ] 2.1 Create `scripts/launch.ps1` with comment-based help and switches for `-Update`, `-Remove`, `-Version`, `-Debug`, `-MaxRuntimeMinutes`, and `-MaxRuntimePerHourMinutes`
- [ ] 2.2 Implement robust path resolution for checkout root, wrapper install root, upstream clone root, config path, state path, shortcut path, and log path
- [ ] 2.3 Implement structured logging with minimal console output by default and JSON Lines output when `-Debug` is active
- [ ] 2.4 Implement runtime configuration loading, command-line override validation, and default values

## 3. Installation and Clone Management

- [ ] 3.1 Implement self-copy from any non-installed path into `%LOCALAPPDATA%\Programs\myTech.Today\autoresearch-karpathy`
- [ ] 3.2 Exclude `.git`, `node_modules`, logs, temporary files, cache folders, and build output from the self-copy operation
- [ ] 3.3 Relaunch the installed `scripts/launch.ps1` with the original switches and safely exit the original process
- [ ] 3.4 Implement upstream clone creation at `%LOCALAPPDATA%\Programs\myTech.Today\autoresearch`
- [ ] 3.5 Validate existing upstream clone remotes and refuse to overwrite unrelated user data

## 4. Windows Integration

- [ ] 4.1 Implement idempotent registration for the `\myTech.Today\autoresearch-karpathy` scheduled task
- [ ] 4.2 Configure task author, description, idle trigger, idle settings, action, and security options according to the spec
- [ ] 4.3 Handle privilege failures with a clear administrator or UAC path and no duplicate task definitions
- [ ] 4.4 Implement idempotent Start Menu shortcut creation at `%APPDATA%\Microsoft\Windows\Start Menu\Programs\myTech.Today\autoresearch.lnk`

## 5. Runtime Governance

- [ ] 5.1 Implement single-instance detection for upstream autoresearch processes
- [ ] 5.2 Implement graceful stop and safe forced termination for existing or over-budget processes
- [ ] 5.3 Implement rolling-hour runtime history in `%LOCALAPPDATA%\myTech.Today\autoresearch-karpathy\state.json`
- [ ] 5.4 Enforce the default 5 minute per-run limit and 5 minute rolling-hour budget
- [ ] 5.5 Log start time, stop time, elapsed runtime, remaining budget, skipped runs, crashes, and termination decisions
- [ ] 5.6 Add health-check handling for upstream processes that fail within the first 60 seconds

## 6. Update, Removal, and Diagnostics

- [ ] 6.1 Implement `-Update` to clone or pull upstream autoresearch, update the wrapper when possible, install npm dependencies, and run smoke validation
- [ ] 6.2 Preserve wrapper-only files and local config/state/log data during update sync operations
- [ ] 6.3 Implement `-Remove` to delete the scheduled task, remove the shortcut, stop running instances, and confirm before deleting managed install directories
- [ ] 6.4 Implement `-Version` to report wrapper version, `ai-powered` version, and last update timestamp without launching upstream autoresearch

## 7. Tests and Validation

- [ ] 7.1 Add tests for provider exclusivity and dependency manifest correctness
- [ ] 7.2 Add PowerShell tests or scripted checks for parameter validation, path handling, logging, and state pruning
- [ ] 7.3 Add Windows integration checks for scheduled task registration, shortcut creation, and repeated idempotent runs
- [ ] 7.4 Add update and removal smoke tests using temporary per-user paths or mocks where direct system mutation is unsafe
- [ ] 7.5 Run the smallest relevant tests first, then run the full validation suite before marking the change complete