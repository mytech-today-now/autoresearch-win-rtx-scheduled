# IdleOnly disposable Windows VM verification

Status: **NOT RUN**. No Scheduled Task has been registered or changed for this check. Do not claim Task Scheduler descendant behavior until this procedure passes in a disposable Windows VM.

## Purpose

Verify that the `IdleOnly` task starts only under the configured idle condition and that, with `StopOnIdleEnd=true`, activity stops the active worker process tree within the defined grace period. Record whether Task Scheduler terminates the supervisor, worker, or both, and whether the launcher can complete cleanup. Pester fake-provider tests cover launcher state transitions; this VM check covers real Task Scheduler behavior and process ancestry.

## Procedure

1. Create a disposable Windows 10/11 VM snapshot with an interactive test account. Keep the VM isolated from production data and do not use the production task name `Autoresearch-Train`.
2. Create a unique temporary task name, for example `Autoresearch-IdlePolicy-Probe-<guid>`, plus a scratch directory inside the VM. Prepare a harmless supervisor/worker pair that records its PIDs, writes a heartbeat, samples Windows idle state, and invokes the reviewed `Stop-AutoresearchProcessTree` implementation when idle state is active or unavailable. The worker must not train, access a provider, or write to the repository's `results.tsv` or checkpoint directory.
3. Register the temporary task with a one-time trigger and the same relevant settings as production: `RunOnlyIfIdle=true`, idle duration `PT5M`, wait timeout `PT1H`, and `StopOnIdleEnd=true`. Keep the action, principal, logs, and all files in the disposable VM. Read the task XML back and confirm those values before starting the probe.
4. Let the task start after the VM has been idle for at least five minutes. Confirm the supervisor and worker PID markers exist and the worker heartbeat advances.
5. Use the VM console to generate keyboard or mouse activity. Record whether Task Scheduler stops the supervisor, worker, or both. Confirm the supervisor records no next-iteration marker when it remains able to run, and all recorded worker descendants exit within 15 seconds of cleanup starting or the activity transition.
6. Confirm no process from the probe remains, the prior-results and checkpoint fixture hashes are unchanged, and Task Scheduler history records the stop. Record the read-back XML, supervisor log, PID list, timestamps, and fixture hashes. If the supervisor is terminated before cleanup can run and any worker remains, the check fails.
7. Optionally repeat with a second uniquely named probe task whose only difference is `StopOnIdleEnd=false`. Record how that setting changes supervisor and worker termination. This control characterizes scheduler descendant handling; it does not replace the `true` production-config check.
8. In a `finally` block, unregister only the temporary task names created by this run and remove only their scratch directory. Revert the VM snapshot after collecting evidence.

## Pass criteria

- The `StopOnIdleEnd=true` task starts under idle conditions and produces readable task history after activity resumes.
- The complete worker process tree is gone within the 15-second cleanup grace period or by the recorded idle-end transition.
- No next iteration starts, prior results remain unchanged, and checkpoint data is left available.
- Task XML readback and Task Scheduler history match the recorded outcome.

If Task Scheduler terminates the supervisor before launcher cleanup can run, or any worker descendant remains, the VM check fails. Keep scheduler descendant behavior marked **NOT VERIFIED** until the failure is corrected and the procedure passes.
