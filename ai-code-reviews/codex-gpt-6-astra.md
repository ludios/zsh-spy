# Codex review of zsh-spy.zsh (gpt-6-astra, reasoning xhigh), 2026-09-13

Raw output of `codex exec -m gpt-6-astra -c model_reasoning_effort=xhigh -s read-only`, prompted for a full review. The claims were re-verified in fable.md; not every one survived unchanged.

I found several confirmed bugs, including false background-job records, stuck locks, and JSON corruption.

Repository files are unchanged; `zsh -n zsh-spy.zsh` passed. The test suite could not run because the sandbox makes `/tmp` read-only. I instead used interactive PTY probes with archive output redirected through a test-only descriptor shim. For timing-sensitive cases, I wrapped helpers with short delays in memory to force the relevant interleaving.

The following are **definite bugs**, ordered roughly by impact.

1. **Foreground pipelines produce fictitious async lifecycles.**  
   [zsh-spy.zsh:743](/home/at/code/system/zsh-spy/zsh-spy.zsh:743) — **definite bug**

   Reproduction:
   ```zsh
   false | { sleep .1; :; }
   ```
   This produces `async_start` and `async_end` for a job whose text is `false`, with status `1`, and `command_end.async_jobs:[1]`. There was no background command; the actual foreground pipeline returns `0`.

   The assertion at lines 740–742 that foreground jobs have already disappeared is false for pipelines whose final component executes in the current shell. I also reproduced this with `print hi | while read x; do sleep .1; done`.

   **Fix:** Require independent evidence that an untracked job was backgrounded. “Done and absent from the preexec snapshot” is insufficient. If the available job parameters cannot distinguish these cases, the adoption strategy needs additional launch/foreground information or must report uncertain provenance.

2. **Ctrl-C can permanently strand both locks.**  
   [zsh-spy.zsh:304](/home/at/code/system/zsh-spy/zsh-spy.zsh:304), [zsh-spy.zsh:845](/home/at/code/system/zsh-spy/zsh-spy.zsh:845) — **definite bug**

   Neither writer ownership nor job-lock ownership has an `always` cleanup block. I inserted a one-shot sleep into `__zshspy_raw_write` and interrupted it while precmd was writing. Subsequent commands reported:
   ```text
   jobs_busy=1 writing=1 jobs_pending=1
   ```
   The queue continued growing, while background reconciliation stopped. Exit can flush queued records, but cannot reconstruct missed completions or the interrupted record.

   The same structural problem affects preexec, reconciliation, and the `finalizing` guard during interrupted re-source.

   **Fix:** Put ownership release in zsh `{ ... } always { ... }` blocks. Also repair or explicitly abandon partially updated command/job state; merely clearing flags does not make those updates transactional.

3. **A chained trap can overwrite the logger’s `REPLY` and corrupt JSON.**  
   [zsh-spy.zsh:1078](/home/at/code/system/zsh-spy/zsh-spy.zsh:1078), [zsh-spy.zsh:566](/home/at/code/system/zsh-spy/zsh-spy.zsh:566) — **definite bug**

   Install this before sourcing:
   ```zsh
   TRAPCHLD() { REPLY=user; }
   ```
   If CHLD arrives after `__zshspy_json_string` sets `REPLY`, but before its caller copies that value, the user trap overwrites the logger’s dynamically scoped local.

   Delaying that boundary while `sleep .05 &` completed produced:
   ```json
   {"type":"command_end","schema":1,"id":user,...}
   ```
   That is invalid JSON. Localizing `REPLY` inside `__zshspy_process_done_jobs` protects only the archive’s part of the trap; its scope has ended before the user trap runs.

   **Fix:** Protect scratch results across the entire trap invocation, or replace generic dynamically scoped result variables with protected, namespaced storage. Consider other generic caller locals too.

4. **Chaining changes the user trap’s option and trap semantics.**  
   [zsh-spy.zsh:1073](/home/at/code/system/zsh-spy/zsh-spy.zsh:1073) — **definite bug**

   With `SH_WORD_SPLIT` enabled before sourcing, a user CHLD trap observes it **off** after installation, because the wrapper runs `emulate -L zsh`.

   More substantially, a user trap containing:
   ```zsh
   setopt noclobber
   TRAPUSR1() { :; }
   ```
   loses both changes when the wrapper returns: `LOCAL_OPTIONS` and `LOCAL_TRAPS` undo them. I confirmed this on a real background completion.

   **Fix:** Keep emulation inside archive-only helpers and invoke the preserved trap outside that scope. Interruption of an already-emulated archive hook needs additional consideration if full transparency is required. The relevant option restoration behavior is documented in [zsh’s options manual](https://zsh.sourceforge.io/Doc/Release/Options.html).

5. **Re-source from CHLD allows an old invocation to write into the new archive.**  
   [zsh-spy.zsh:69](/home/at/code/system/zsh-spy/zsh-spy.zsh:69), [zsh-spy.zsh:305](/home/at/code/system/zsh-spy/zsh-spy.zsh:305) — **definite bug**

   A chained user trap can source the plugin while an archive hook is suspended. Shutdown finalizes the old session and initialization replaces the globals, functions, and descriptor. The suspended invocation then resumes with old local arguments and new global state.

   I forced this while precmd was writing `async_start`. The resulting sequence included:

   - Old session: `async_end` and `session_end`, before its delayed `async_start`.
   - New session: the old session’s delayed `async_start`.
   - A further `command_end` combining the old command ID with the new session ID.

   **Fix:** Defer reload until active archive invocations unwind, or use generation checks and per-generation state so an old invocation cannot write or mutate state after replacement. `finalizing` alone does not protect suspended callers.

6. **A pending flag cannot preserve a completion consumed by the user trap.**  
   [zsh-spy.zsh:653](/home/at/code/system/zsh-spy/zsh-spy.zsh:653), [zsh-spy.zsh:1075](/home/at/code/system/zsh-spy/zsh-spy.zsh:1075) — **definite bug**

   With this pre-existing trap:
   ```zsh
   TRAPCHLD() { jobs >/dev/null; }
   ```
   let a background job finish while precmd holds `__zshspy_jobs_busy`. Archive reconciliation sets `jobs_pending` and returns; the chained trap then runs `jobs`, which removes the completed entry.

   Delaying command-end logging reproduced `async_lost` instead of `async_end` for an ordinary successful completion. An unadopted job can lose its entire lifecycle this way.

   **Fix:** Capture immutable completion snapshots before calling the user trap, even while semantic reconciliation is locked. Queue the state, process identity, text, and directory—not just a Boolean request to inspect the table later.

7. **`async_jobs` is copied before taking the lock.**  
   [zsh-spy.zsh:841](/home/at/code/system/zsh-spy/zsh-spy.zsh:841) — **definite bug**

   The sequence is:

   1. Copy `__zshspy_cur_adopted` into `items`.
   2. CHLD adopts and completes another job.
   3. Acquire the lock.
   4. Skip that job because its completion fingerprint is already recorded.
   5. Emit the stale `items`.

   I delayed lock acquisition in `__zshspy_finish_current_command` while `sleep .1 &` finished. Both async records were correct, but `command_end.async_jobs` was `[]`.

   **Fix:** Acquire the semantic lock before reading the adopted list or any other command state used by this reconciliation.

8. **Interrupted initialization leaves the shell’s umask changed.**  
   [zsh-spy.zsh:1154](/home/at/code/system/zsh-spy/zsh-spy.zsh:1154) — **definite bug**

   There is no guaranteed restoration between `umask 077` and line 1160. Starting with umask `022`, I delayed `sysopen` and interrupted sourcing: the interactive shell returned with umask `077` and logging disabled.

   The fallback trap-inspection path has the same problem at [zsh-spy.zsh:1114](/home/at/code/system/zsh-spy/zsh-spy.zsh:1114).

   **Fix:** Restore the saved umask in an `always` block and clean up partially acquired descriptors there.

9. **The fallback opener does not guarantee exclusive creation.**  
   [zsh-spy.zsh:234](/home/at/code/system/zsh-spy/zsh-spy.zsh:234) — **definite bug**

   With `sysopen` disabled, `__zshspy_open_file /dev/null` returns success and an open descriptor. `NO_CLOBBER` permits existing nonregular files; it also permits following a symlink to such a file. A FIFO collision can block sourcing.

   Thus the fallback’s claimed exclusive-create/no-existing-entry guarantee is false. This behavior is explicit in [zsh’s redirection implementation](https://raw.githubusercontent.com/zsh-users/zsh/zsh-5.9/Src/exec.c).

   **Fix:** Require an opener with actual `O_EXCL` semantics, or create the archive within an atomically created private directory. A preliminary existence check alone would retain a race.

10. **Some accepted strings produce invalid JSON.**  
    [zsh-spy.zsh:156](/home/at/code/system/zsh-spy/zsh-spy.zsh:156) — **definite bug, already acknowledged in the header**

    `__zshspy_json_string $'a\0b'` retains a literal NUL. `$'a\377b'` retains invalid UTF-8. These can affect command text and filesystem-derived fields.

    **Fix:** Escape NUL as `\u0000`; adopt an explicit encoding or replacement policy for invalid UTF-8. The header documents the failure but does not make the output valid JSONL.

The following are **suspicious or dependent on the intended contract**.

11. **Async durations include unrelated foreground execution.**  
    [zsh-spy.zsh:761](/home/at/code/system/zsh-spy/zsh-spy.zsh:761), [zsh-spy.zsh:872](/home/at/code/system/zsh-spy/zsh-spy.zsh:872) — **likely bug**

    Both paths assign the spawning command’s start time as the job’s start time. With:
    ```zsh
    sleep .5; sleep .1 & sleep .2
    ```
    the `.1`-second job received a duration of approximately `.609` seconds. A longer prefix makes the error arbitrarily large.

    **Fix:** Label this as elapsed time since the command started, or report job duration as unknown/estimated when the launch time was not observed.

12. **Foregrounding a tracked job loses its completion status.**  
    [zsh-spy.zsh:715](/home/at/code/system/zsh-spy/zsh-spy.zsh:715) — **suspicious limitation**

    Run `sleep 2 &`, then `fg` before it finishes. The result is `async_start` followed by `async_lost:missing_from_job_table`, despite normal completion.

    This is consistent with the literal `async_lost` definition, so I would not call the fallback itself incorrect. However, it is a common lifecycle transition that the plugin does not fully capture.

    **Fix:** Document this explicitly, or track foreground transitions and correlate their completion with the foreground command.

13. **Attribution depends on other plugins’ hook ordering.**  
    [zsh-spy.zsh:805](/home/at/code/system/zsh-spy/zsh-spy.zsh:805), [zsh-spy.zsh:847](/home/at/code/system/zsh-spy/zsh-spy.zsh:847) — **suspicious**

    A background worker started by an earlier precmd hook is attributed to the preceding interactive command. Conversely, a worker started by an earlier preexec hook enters the “before” snapshot and is excluded. I verified both behaviors.

    **Fix:** Define whether hook-created work belongs to the command. If it does not, establish boundaries before other hooks run where possible, and use unknown/separate attribution where provenance cannot be established.

14. **`exec` leaves an unterminated session.**  
    [zsh-spy.zsh:1056](/home/at/code/system/zsh-spy/zsh-spy.zsh:1056) — **suspicious limitation**

    Successful `exec some-program` bypasses `zshexit`, leaving the command and session without terminal records. This is [documented zsh behavior](https://zsh.sourceforge.io/Doc/Release/Functions.html), rather than a trap implementation error.

    **Fix:** Document the incomplete-tail case; if supported explicitly, record an execution handoff without claiming to know the replacement program’s eventual status.

Finally, one **nit**: [zsh-spy.zsh:1152](/home/at/code/system/zsh-spy/zsh-spy.zsh:1152) prints `__zshspy_old_umask=022` on ordinary re-source because bare `typeset` displays an existing parameter unless `TYPESET_SILENT` is enabled. Initialize the declaration explicitly to avoid unsolicited terminal output.