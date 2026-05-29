You are a senior Windows systems automation engineer and Node.js specialist. Your task is to refactor this repository so that its core AI functionality is powered exclusively by the `ai-powered` npm package (https://www.npmjs.com/package/ai-powered), completely removing any dependencies on Augment Code AI or any other external AI service APIs.

The refactored solution must be designed to run solely as a Windows Scheduled Task that triggers only when the computer is idle. Implement the following requirements with precision, handling all edge cases, errors, and idempotency concerns.

## 1. Windows Scheduled Task Configuration
Create a scheduled task with these exact specifications:
- **Task Name:** `autoresearch-karpathy`
- **Task Folder:** `\myTech.Today`
- **Author:** `myTech.Today (sales@mytech.today)`
- **Description:** An AI-enhanced version of: "Runs Andrej Karpathy's autoresearch repository (https://github.com/karpathy/autoresearch) as a scheduled task whenever the computer is idle, on Windows."
- **Trigger:** Execute only when the computer is idle. Configure standard Windows idle detection (e.g., `IdleWaitMinutes`, `IdleDuration`).
- **Action:** Launch the installed copy of `scripts/launch.ps1` from `%LOCALAPPDATA%\Programs\myTech.Today\autoresearch-karpathy\scripts\launch.ps1`.
- **Security:** Ensure the task runs with appropriate permissions. If elevation is required, the setup process must handle UAC prompts gracefully or request administrator privileges in a user-friendly manner.
- **Idempotency:** If the scheduled task already exists, do not create a duplicate. Update the existing task if its configuration differs from the requirements above.

## 2. Self-Installation, Upstream Clone, and Per-User Program Location
The launcher must install and run from the user's per-user Programs area rather than relying on the original checkout location. It must also maintain a local clone of Andrej Karpathy's upstream `autoresearch` repository in the same per-user install base.

- **Install Base:** Use an appropriate per-user application base directory such as `%LOCALAPPDATA%\Programs\myTech.Today`.
- **Wrapper Install Root:** Copy this entire repository, including `scripts/launch.ps1`, into `%LOCALAPPDATA%\Programs\myTech.Today\autoresearch-karpathy`.
- **Upstream Autoresearch Clone Root:** Clone `https://github.com/karpathy/autoresearch` into `%LOCALAPPDATA%\Programs\myTech.Today\autoresearch`.
- **Upstream Clone Behavior:** If the upstream `autoresearch` clone does not exist, clone it automatically. If it already exists, validate that it points to `https://github.com/karpathy/autoresearch` and update it safely. If the directory exists but is not a valid git clone of that repository, log a clear error and do not overwrite user data without confirmation.
- **Self-Copy Behavior:** When `scripts/launch.ps1` is run from any other location, it must:
  1. Resolve the current repository root.
  2. Create the install base and wrapper install root if needed, then create the upstream clone root by running `git clone` when it is missing.
  3. Copy itself and the whole wrapper repository tree to the wrapper install root, excluding transient or unsafe folders such as `.git`, `node_modules`, logs, temporary files, cache folders, and build output unless those files are explicitly required.
  4. Re-launch the copied `scripts/launch.ps1` from the wrapper install root with the same command-line switches.
  5. Exit the original process after the installed copy starts successfully.
- **Idempotency:** Re-running the script must update the installed wrapper copy and upstream clone without creating duplicate directories, duplicate scheduled tasks, duplicate shortcuts, or concurrent application instances.
- **Path Safety:** Use robust PowerShell path handling for paths containing spaces. Do not hard-code drive letters. Prefer environment variables such as `$env:LOCALAPPDATA` and `$env:APPDATA`.

## 3. PowerShell Launch Script (`scripts/launch.ps1`)
Develop a robust PowerShell script located at `scripts/launch.ps1` with the following capabilities:

### Core Execution
- Launch the autoresearch application from the installed upstream clone at `%LOCALAPPDATA%\Programs\myTech.Today\autoresearch` with all dependencies satisfied.
- Verify that the `ai-powered` npm package is installed and configured correctly. If dependencies are missing, install them automatically (e.g., run `npm install` or equivalent).
- Ensure the script detects whether it is being run interactively or by the Task Scheduler and behaves appropriately in both contexts.

### Runtime Limits and Scheduling Control
- `launch.ps1` must regulate how often and how long the upstream `autoresearch` program is allowed to run.
- Default maximum runtime per invocation: **5 minutes**.
- Default maximum runtime during idle periods: **5 minutes per rolling hour**.
- The upstream `autoresearch` process must be stopped gracefully when it reaches the configured per-run limit. If graceful shutdown fails, terminate it safely and log the reason.
- Before starting `autoresearch`, the launcher must check recent runtime history and skip execution if the configured per-hour idle runtime budget has already been consumed.
- Persist runtime history in a small local state file under the per-user install or data area, such as `%LOCALAPPDATA%\myTech.Today\autoresearch-karpathy\state.json`, so limits survive process restarts and scheduled task invocations.
- Provide user-configurable settings for runtime limits, including:
  - `-MaxRuntimeMinutes <int>` to set the maximum runtime for each `autoresearch` run.
  - `-MaxRuntimePerHourMinutes <int>` to set the maximum total runtime allowed per rolling hour during idle periods.
  - A persistent configuration file, such as `%LOCALAPPDATA%\myTech.Today\autoresearch-karpathy\config.json`, so user preferences do not need to be supplied on every launch.
- Validate user-supplied runtime values. Reject zero, negative, non-numeric, or unreasonably large values with clear error messages.
- Log every runtime-limit decision, including process start time, stop time, elapsed runtime, remaining hourly budget, skipped runs, and forced termination events.

### Task Management
- **Creation:** If the `autoresearch-karpathy` scheduled task does not exist, create it automatically on first run.
- **Removal:** Provide a `-Remove` switch that deletes the `autoresearch-karpathy` scheduled task, removes the Start Menu shortcut, stops any running autoresearch instance, and optionally removes both installed per-user directories after confirmation: `%LOCALAPPDATA%\Programs\myTech.Today\autoresearch-karpathy` and `%LOCALAPPDATA%\Programs\myTech.Today\autoresearch`.
- **Cycling / Restart:** If the script is executed while the autoresearch process is already running, gracefully terminate the existing instance and restart it. Do not spawn multiple concurrent instances.

### Update Mechanism
- Implement an `-Update` switch that:
  1. Ensures the upstream clone exists at `%LOCALAPPDATA%\Programs\myTech.Today\autoresearch`, cloning `https://github.com/karpathy/autoresearch` if missing.
  2. Pulls the latest changes from `https://github.com/karpathy/autoresearch` into that upstream clone.
  3. Pulls the latest changes for this wrapper repository itself into `%LOCALAPPDATA%\Programs\myTech.Today\autoresearch-karpathy`.
  4. If the wrapper repository needs to sync code from the upstream `autoresearch` clone, perform that sync explicitly and safely, preserving wrapper-only files such as `scripts/launch.ps1`, scheduled task logic, shortcut generation, and local configuration.
  5. Re-installs or updates npm dependencies, including `ai-powered`, to their required versions in the appropriate working directory.
  6. Validates the update by performing a dry-run or smoke test before completing.

### Diagnostics & Versioning
- Implement a `-Version` switch that prints the current version of the local autoresearch wrapper, the `ai-powered` package version, and the last update timestamp.
- Implement a `-Debug` switch that:
  - Enables verbose logging.
  - Writes all debug output, errors, and diagnostic information to `%HOMEDRIVE%\myTech.Today\logs\autoresearch-karpathy.jsonl`.
  - Use structured JSON Lines format for every log entry. Each line must be a valid JSON object containing at minimum: `timestamp` (ISO 8601), `level` (DEBUG, INFO, WARN, ERROR), `message` (string), `source` (e.g., "launch.ps1", "ScheduledTask", "autoresearch"), and `detail` (optional object).
  - Ensure the log directory exists before writing.

## 4. Windows Shortcut
- Create a Windows shortcut file named `autoresearch.lnk` in the user's Start Menu under an appropriate folder such as `%APPDATA%\Microsoft\Windows\Start Menu\Programs\myTech.Today\autoresearch.lnk`.
- The shortcut must target the installed copy of `scripts/launch.ps1` in `%LOCALAPPDATA%\Programs\myTech.Today\autoresearch-karpathy\scripts\launch.ps1`.
- The shortcut should be executable with a double-click by launching through `powershell.exe` with safe arguments such as `-NoProfile`, `-ExecutionPolicy Bypass`, and `-File`.
- The shortcut generation must be idempotent: update the existing shortcut if needed, but do not create duplicates.

## 5. Runtime Behavior
- When launched by the scheduled task, the application must:
  1. Verify that the idle state is still active (or rely on the Task Scheduler's idle trigger).
  2. Check the configured per-run and per-hour runtime limits before starting the upstream `autoresearch` process.
  3. Skip the run if the per-hour idle runtime budget has already been consumed.
  4. Start the upstream `autoresearch` process only when runtime budget is available.
  5. Monitor the process for basic health (e.g., check if it crashes within the first 60 seconds).
  6. Stop the process when it reaches the configured maximum runtime, defaulting to 5 minutes.
  7. Record the completed runtime in persistent state so the total runtime does not exceed the configured per-hour limit, defaulting to 5 minutes per rolling hour.
  8. If the process exits or crashes unexpectedly, log the failure and do not restart immediately within the same trigger event. Wait for the next idle trigger.
  9. After a successful session completion, pause gracefully and release resources, waiting for the next scheduled task wake-up.

## 6. Error Handling & Logging
- All error conditions (missing dependencies, task creation failures, git pull failures, process crashes) must be caught and logged.
- When `-Debug` is active, logs go to the specified JSONL file. In non-debug mode, minimal output should go to the console or standard PowerShell streams.
- Provide clear, actionable error messages for common failure modes (e.g., "Git not found in PATH", "npm install failed", "Insufficient privileges to create scheduled task").

## 7. Assumptions & Constraints
- Target platform: Windows 10/11 with PowerShell 5.1 or later.
- The script must be idempotent: running `launch.ps1` multiple times must never create duplicate scheduled tasks or orphan processes.
- Respect the user's environment: do not modify global system settings beyond the specific scheduled task, the per-user install directory, the Start Menu shortcut, and the log directory.
- The `ai-powered` package must be the sole AI interface. Remove any legacy API keys, client libraries, or configuration files related to Augment Code AI or other providers.

## Output
- Do not output explanations, commentary, or summaries unless explicitly asked.
- Provide multiple examples of how to run the code from a PowerShell prompt, including normal launch, `-Update`, `-Remove`, `-Version`, and `-Debug` examples. Also show how to run the PS1 script without manually downloading it by using only the GitHub raw content URL.
- Provide only the complete, production-ready code and configuration files required to satisfy the above requirements.
- Ensure the `launch.ps1` script is fully self-contained for its logic, using helper functions where appropriate, and includes comment-based help (`<# .SYNOPSIS ... #>`).

