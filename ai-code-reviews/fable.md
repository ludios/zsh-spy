# zsh-spy.zsh review (Claude Fable 5.1, 2026-09-13)

Method: read zsh-spy.zsh and tests/run.zsh, then drove real interactive
zsh 5.9.1 sessions over zpty (18 probe scripts) to reproduce every
suspicion, and cross-checked the trap and job-table behaviour against
zsh-5.9 Src/jobs.c and Src/exec.c.  Codex (gpt-6-astra, xhigh) reviewed
the file independently at the same time; its raw output is in
codex-gpt-6-astra.md.  Findings marked "(Codex)" were raised there first
and then reproduced here.  Every item under "Definite bugs" was
reproduced on this machine.

## Definite bugs

### 1. Foreground work is logged as background jobs

zsh runs the CHLD trap for any job other than the one it is currently
waiting on (jobs.c update_job: `if (sigtrapped[SIGCHLD] && job !=
thisjob) dotrap(SIGCHLD)`), not only for `&` jobs.  The adoption pass in
the trap (zsh-spy.zsh:740-770) treats every "done" job that was not in
the preexec snapshot as a background job.  Two shapes:

- Race: `sleep 0.2 & sleep 0.2`.  When both children are reaped in one
  handler pass with the foreground one first, the foreground job is
  "done" but not yet deleted when the background job's trap runs.  12 of
  18 such lines produced a fake async_start/async_end for the foreground
  sleep (job_text "sleep 0.2 | cat" in the pipeline variant).
- Deterministic (Codex): a pipeline whose tail runs in the current shell
  and executes an external command.  `false | { sleep 0.2; :; }`,
  `print hi | while read x; do sleep 0.2; done` and
  `cat f | { read a; sleep 0.2 }` each emit async_start/async_end for the
  pipeline head and list it in command_end.async_jobs.  `ls / | while
  read x; do :; done` does not (no external command in the tail).

Plain zsh with NOTIFY on never announces either as a done job.  The
comment at line 740 ("Foreground jobs have already been removed before
queued CHLD traps run") is false.

Observed inside the trap with NOTIFY off: the foreground job's first pid
equals the terminal's foreground process group (field tpgid of
/proc/self/stat) in every race case and in `false | { ... }`; it does
not when the current-shell tail is itself running an external command
that has taken the terminal (`cat f | while read x; do ext; done` while
ext runs).  $! only identifies the most recent `&` job, and job marks
(+/-) only the two most recent, so neither can classify the rest.

Fix: skip a done candidate whose first pid is the terminal's foreground
pgrp (Linux /proc; elsewhere keep today's behaviour).  Removes the race
shape entirely and part of the pipeline shape; document the residual.

### 2. Ctrl-C during a hook strands both locks for the session

Interrupting precmd while it held the writer and jobs locks (one-shot
busy loop injected into __zshspy_raw_write, then Ctrl-C) left
`__zshspy_jobs_busy=1 __zshspy_writing=1 __zshspy_jobs_pending=1`.
Afterwards a `sleep 0.3 &` produced no async records at all, and every
later record was appended to the in-memory queue (7 entries by exit).
The exit finalizer drains the queue, so an orderly exit loses nothing,
but a crash or SIGKILL loses everything since the Ctrl-C, and background
tracking is silently dead for the rest of the session.  SIGINT aborts
running shell code at the next statement boundary; zsh
`{ } always { }` blocks do run in that case (verified, with
TRY_BLOCK_INTERRUPT=1).  The same class covers `__zshspy_finalizing`
when a re-source is interrupted and the umask window at lines 1154-1160
(Codex).

Fix: release the locks in always blocks.

### 3. A chained user TRAPCHLD that assigns REPLY corrupts a record (Codex)

`TRAPCHLD() { REPLY=user }` installed before sourcing, plus a completion
landing between `__zshspy_json_string` and the copy of its result,
wrote `"reason":user`, an invalid JSON line.  The hooks' `local REPLY`
(intended to protect the user's REPLY, T9) is exactly the variable the
user trap overwrites, because the user trap is called from the wrapper's
dynamic scope.

Fix: use private scratch names (`__zshspy_r`, `__zshspy_r2`) instead of
REPLY/REPLY2 throughout the archive.

### 4. The user's TRAPCHLD runs under the wrapper's `emulate -L zsh` (Codex)

zsh-spy.zsh:1073.  A user trap doing `setopt noclobber; TRAPUSR1() { :; }`
keeps both without zsh-spy and loses both with it (LOCAL_OPTIONS and
LOCAL_TRAPS undo them when the wrapper returns), and it runs under zsh
emulation options rather than the user's.

Fix: call the user trap from a scope without `emulate -L`.

### 5. A user TRAPCHLD that runs `jobs` while the jobs lock is held loses the completion (Codex)

`jobs` deletes done jobs (jobs.c printjob(..., 2) -> deletejob).  When
the archive's half of the trap defers because precmd holds the lock, the
user half then removes the job, and the deferred pass writes
`async_lost missing_from_job_table` instead of async_end.  Reproduced
with an injected delay; the natural window is under a millisecond and
the trap is unusual.

Fix: snapshot the done entries of $jobstates when deferring, and
reconcile from the snapshot.  About 20 lines; documenting it may be the
better trade.

### 6. command_end.async_jobs is copied before the lock is taken (Codex)

zsh-spy.zsh:841 copies `__zshspy_cur_adopted` and line 845 takes the
lock; an adoption in between is omitted from async_jobs while its
async_start/async_end records are correct.

Fix: build the list after acquiring the lock.

### 7. NUL bytes pass through unescaped

`__zshspy_json_string $'a\0b'` keeps the raw NUL; the line is not JSON.
`${s//$'\0'/\\u0000}` works in zsh (verified).  Invalid UTF-8 still
passes through as the header says.  Everything else survived a
3000-string fuzz over all C0 controls, quotes, backslashes, DEL, and
multibyte text, decoded back by a strict parser.

### 8. Every re-source prints `__zshspy_old_umask=022` (Codex)

zsh-spy.zsh:1152 is a bare `typeset` of a parameter that already exists,
which prints it.  Cosmetic.

## Limitations worth documenting rather than fixing

- `fg` of a tracked job ends as `async_lost missing_from_job_table` even
  though it completed normally; `disown` looks the same.  The job's
  status is the `fg` command's `$?`, but no trap fires for a foreground
  completion.
- async_end.duration is measured from the spawning command line's start,
  not from the `&` (Codex): `sleep 5; sleep 0.1 &` reports about 5 s.
- `exec prog` (including `exec zsh`) leaves the file without command_end
  and session_end: zshexit never runs.  SIGHUP and a closed pty do
  produce session_end.
- Sourcing from inside a function that used `emulate -L` (LOCAL_OPTIONS
  and LOCAL_TRAPS) silently loses TRAPCHLD, NO_NOTIFY and
  EXTENDED_HISTORY while session_start still says
  background_tracking:true.  Worth a warning at source time.
- Jobs started by other precmd/preexec hooks are attributed to the
  neighbouring command or excluded depending on hook order (Codex).
- Without zsh/system the opener relies on NO_CLOBBER, which zsh enforces
  only for regular files (exec.c clobber_open), so a planted symlink or
  FIFO at the archive path would be followed.  Needs an attacker inside
  a 0700 directory guessing an unpredictable name.
- Escaping a 100 KB field that is 25% quotes takes about 0.7 s (zsh's
  global substitution is slow with many matches); ordinary pastes take
  tens of milliseconds.
- A user TRAPCHLD that re-sources zsh-spy while an archive hook is
  suspended can interleave old and new lifecycles (Codex).  Contrived.

## What checked out

All 23 exit codes tried and all 23 default-fatal signals decode
correctly; real-time signals give null as documented.  Multi-line
list-form CHLD traps are detected (zsh prints them on one line).  wait,
kill, Ctrl-Z then bg, disown, job-slot reuse, process substitution, a
30-job line plus 10 cross-prompt jobs (exactly once each), odd cwd and
alias-expanded control characters, the no-sysopen/no-syswrite and
no-strftime fallbacks, and SIGHUP all behaved.

## Test-suite gaps

The suite avoids the races by construction (0.3 s vs 0.9 s sleeps in
T5) and only injects state once (T15).  Missing: the deterministic
pipeline-head repro, a Ctrl-C injection test (one-shot busy loop in a
wrapped function, then Ctrl-C), the REPLY-clobber and `jobs`-in-trap
traps, and three property-style checks that need no timing luck: a JSON
escape fuzz (no pty needed), an exit-code and signal sweep, and an N-job
exactly-once stress.  Harness pitfall: a typed line containing `$!"` is
mangled by history expansion and wedges the session at a continuation
prompt; probes need `setopt nobanghist` first.

## Fix plan and outcome

Worked through one commit each, test first.  Status recorded after
implementation; the whole batch was reviewed by Codex (gpt-6-astra,
xhigh) against the plan first, and again over the finished commits.

1. [x] Documented the limitations in the header XXX block, and corrected
       the now-stale NUL and fallback-opener comments.
2. [x] Escape NUL as \u0000 (folded into item 11); T24 fuzzes the escaper
       without a pty and checks strict-JSON round-trips.
3. [x] Stopped the re-source `typeset __zshspy_old_umask` dump; T11 now
       asserts the terminal shows no archive parameter dump.
4. [x] Build command_end.async_jobs after taking the jobs lock; T19.
5. [x] Release the jobs lock and writer flag in `always` blocks, plus the
       finalizer and source-time umask; the lock helper sets the owner's
       local in the same statement as the lock.  T22 injects a Ctrl-C.
6. [x] Replaced REPLY/REPLY2 with __zshspy_r/__zshspy_r2 throughout; T20
       covers a user trap that assigns REPLY.
7. [x] Run the chained user TRAPCHLD outside `emulate -L`, guarding the
       deliberately nonzero status against ERR_RETURN; T21.
8. [x] Skip the adoption candidate whose leader owns the terminal (tpgid
       from /proc/self/stat); T23 asserts the deterministic half and that
       no background job is missed.  The same-instant race is documented.
9. [ ] Skipped (Codex concurred): a warning would not repair the
       misleading `background_tracking:true`, and `LOCAL_TRAPS` alone can
       lose the trap.  Documented supported sourcing instead.

Decisions:

10. Documented, not coded (bug 5): a correct snapshot needs process
    identity, text and dir, too much for an uncommon trap interaction.
11. [x] Done: single `(#m)` pass over a table built once.  Byte-identical
    to the old escaper on a 20000-string fuzz apart from the NUL fix,
    about 10x faster on plain text, and 26 lines shorter.
12. Skipped: the two reconciliation loops read clearly as they are; the
    shared version saved ~15 lines in the most delicate code.
13. Skipped (Codex concurred): a job-text heuristic has holes both ways
    and would silently drop real background work.
