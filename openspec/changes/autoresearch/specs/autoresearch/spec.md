## ADDED Requirements

### Requirement: Exclusive AI Provider
The system SHALL use the `ai-powered` npm package as the only AI interface and MUST remove Augment Code AI and all other external AI service API integrations.

#### Scenario: Allowed AI package is present
- **WHEN** dependencies are inspected after installation or update
- **THEN** `ai-powered` is installed and available to the autoresearch runtime

#### Scenario: Disallowed AI providers are absent
- **WHEN** package manifests, lockfiles, source files, and configuration files are checked
- **THEN** no Augment Code AI SDK, non-approved AI provider SDK, API key setting, or provider-specific client configuration remains

### Requirement: Per-User Self Installation
The launcher SHALL install the wrapper repository into `%LOCALAPPDATA%\Programs\myTech.Today\autoresearch-karpathy` when run from any other location.

#### Scenario: First launch from checkout
- **WHEN** `scripts/launch.ps1` runs outside the wrapper install root
- **THEN** it creates the install base, copies the wrapper repository excluding unsafe transient folders, relaunches the installed script with the same switches, and exits the original process after successful handoff

#### Scenario: Launch from installed path
- **WHEN** `scripts/launch.ps1` runs from `%LOCALAPPDATA%\Programs\myTech.Today\autoresearch-karpathy`
- **THEN** it continues locally without copying or relaunching itself

#### Scenario: Wrapper copy excludes transient content
- **WHEN** the wrapper tree is copied to the install root
- **THEN** `.git`, `node_modules`, logs, temporary files, cache folders, and build output are excluded unless explicitly required by the launcher

### Requirement: Upstream Clone Management
The launcher SHALL maintain Andrej Karpathy's upstream repository at `%LOCALAPPDATA%\Programs\myTech.Today\autoresearch`.

#### Scenario: Upstream clone is missing
- **WHEN** the upstream clone root does not exist
- **THEN** the launcher runs `git clone https://github.com/karpathy/autoresearch` into the expected location

#### Scenario: Existing clone has correct remote
- **WHEN** the upstream clone exists and its remote points to `https://github.com/karpathy/autoresearch`
- **THEN** the launcher updates it safely without creating duplicate directories

#### Scenario: Existing path is unsafe to overwrite
- **WHEN** the upstream clone path exists but is not a Git clone of the expected repository
- **THEN** the launcher logs a clear error and does not overwrite or delete the existing data without confirmation

### Requirement: Scheduled Task Registration
The launcher SHALL create or update one Windows Scheduled Task named `autoresearch-karpathy` under the `\myTech.Today` folder.

#### Scenario: Task is missing
- **WHEN** the launcher runs and the scheduled task does not exist
- **THEN** it creates a task authored by `myTech.Today (sales@mytech.today)` with an AI-enhanced description of the upstream repository and an idle-only trigger

#### Scenario: Task already exists with drift
- **WHEN** the task exists but any required author, description, trigger, action, idle setting, or security setting differs
- **THEN** the launcher updates the existing task instead of creating a duplicate

#### Scenario: Task action is configured
- **WHEN** the scheduled task is registered
- **THEN** its action launches the installed `%LOCALAPPDATA%\Programs\myTech.Today\autoresearch-karpathy\scripts\launch.ps1` with safe PowerShell arguments

#### Scenario: Elevation is required
- **WHEN** task registration fails because privileges are insufficient
- **THEN** the setup handles UAC or reports a user-friendly administrator privilege request without leaving duplicate or partial task definitions

### Requirement: Idle-Gated Runtime
The scheduled task SHALL run only when Windows reports that the computer is idle, and the launcher SHALL enforce runtime limits before starting upstream autoresearch.

#### Scenario: Idle trigger fires with budget available
- **WHEN** the scheduled task starts the launcher while runtime budget remains
- **THEN** the launcher starts the upstream autoresearch process from `%LOCALAPPDATA%\Programs\myTech.Today\autoresearch`

#### Scenario: Hourly budget is exhausted
- **WHEN** the rolling-hour runtime history shows that the configured per-hour limit has already been consumed
- **THEN** the launcher skips the run and logs the remaining budget decision

#### Scenario: Per-run limit is reached
- **WHEN** the upstream process reaches the configured per-run maximum runtime
- **THEN** the launcher attempts graceful shutdown, force terminates only if necessary, records elapsed runtime, and logs the termination reason

#### Scenario: Process crashes early
- **WHEN** the upstream process exits or crashes within the health-check window
- **THEN** the launcher logs the failure and does not restart during the same trigger event

### Requirement: Runtime Configuration and State
The launcher SHALL support configurable runtime limits and persist state under the per-user data area.

#### Scenario: Defaults are used
- **WHEN** no runtime settings are supplied by command line or configuration file
- **THEN** the per-run limit is 5 minutes and the rolling-hour limit is 5 minutes

#### Scenario: Command-line runtime settings are valid
- **WHEN** `-MaxRuntimeMinutes <int>` or `-MaxRuntimePerHourMinutes <int>` is supplied with a positive reasonable integer
- **THEN** the launcher applies the supplied value for the current invocation and persists preferences when configuration behavior requires it

#### Scenario: Runtime settings are invalid
- **WHEN** a runtime value is zero, negative, non-numeric, or unreasonably large
- **THEN** the launcher rejects it with a clear error message and does not start upstream autoresearch

#### Scenario: Runtime history persists
- **WHEN** a run completes, is skipped, or is terminated
- **THEN** the launcher updates `%LOCALAPPDATA%\myTech.Today\autoresearch-karpathy\state.json` so budget decisions survive future invocations

### Requirement: Process Concurrency and Cycling
The launcher SHALL prevent concurrent upstream autoresearch instances.

#### Scenario: Existing instance is running
- **WHEN** the launcher starts and an upstream autoresearch instance is already running
- **THEN** it gracefully terminates the existing instance before starting a replacement

#### Scenario: Graceful termination fails
- **WHEN** an existing instance does not exit after the configured graceful shutdown interval
- **THEN** the launcher safely force terminates it and logs the forced termination

### Requirement: Update Workflow
The launcher SHALL implement an `-Update` switch that updates the wrapper, upstream clone, and npm dependencies.

#### Scenario: Update is requested
- **WHEN** the user runs `scripts/launch.ps1 -Update`
- **THEN** the launcher ensures the upstream clone exists, pulls from `https://github.com/karpathy/autoresearch`, pulls the installed wrapper repository when it is a Git clone, updates npm dependencies including `ai-powered`, and runs a dry-run or smoke validation

#### Scenario: Wrapper and upstream files must be synchronized
- **WHEN** wrapper files need to sync from the upstream clone
- **THEN** the sync preserves wrapper-only files including `scripts/launch.ps1`, scheduled task logic, shortcut generation, local configuration, runtime state, and logs

### Requirement: Removal Workflow
The launcher SHALL implement a `-Remove` switch for idempotent cleanup.

#### Scenario: Remove is requested
- **WHEN** the user runs `scripts/launch.ps1 -Remove`
- **THEN** the launcher deletes the scheduled task, removes the Start Menu shortcut, stops running upstream autoresearch instances, and offers confirmation before deleting managed install directories

#### Scenario: Remove is repeated
- **WHEN** `-Remove` runs after the task, shortcut, or processes are already absent
- **THEN** the launcher completes successfully without reporting duplicate cleanup failures

### Requirement: Diagnostics and Version Reporting
The launcher SHALL implement `-Debug` and `-Version` diagnostics.

#### Scenario: Debug logging is active
- **WHEN** the launcher runs with `-Debug`
- **THEN** every debug log entry is appended as a valid JSON object line to `%HOMEDRIVE%\myTech.Today\logs\autoresearch-karpathy.jsonl` with `timestamp`, `level`, `message`, `source`, and optional `detail`

#### Scenario: Version is requested
- **WHEN** the user runs `scripts/launch.ps1 -Version`
- **THEN** the launcher prints the wrapper version, `ai-powered` package version, and last update timestamp without starting upstream autoresearch

### Requirement: Start Menu Shortcut
The launcher SHALL create an idempotent Windows shortcut named `autoresearch.lnk` under the user's Start Menu `myTech.Today` folder.

#### Scenario: Shortcut is missing or stale
- **WHEN** the launcher verifies shortcuts
- **THEN** it creates or updates `%APPDATA%\Microsoft\Windows\Start Menu\Programs\myTech.Today\autoresearch.lnk` to launch the installed `scripts/launch.ps1` through `powershell.exe -NoProfile -ExecutionPolicy Bypass -File`

#### Scenario: Shortcut already matches
- **WHEN** the existing shortcut target and arguments match the required configuration
- **THEN** the launcher leaves it in place and does not create duplicates

### Requirement: Error Handling and User Safety
The launcher SHALL catch and report expected failures without corrupting user data or leaving duplicate resources.

#### Scenario: Required tools are missing
- **WHEN** Git, npm, PowerShell functionality, or dependency installation is unavailable
- **THEN** the launcher logs a clear actionable error and exits without starting upstream autoresearch

#### Scenario: Paths contain spaces
- **WHEN** install, clone, shortcut, log, config, or state paths contain spaces
- **THEN** the launcher handles them using robust PowerShell path APIs and does not rely on hard-coded drive letters

#### Scenario: Repeated launches are idempotent
- **WHEN** the launcher is run multiple times with the same switches
- **THEN** it does not create duplicate scheduled tasks, shortcuts, directories, processes, logs, or configuration entries