#!/usr/bin/env zsh

# Model-output: Claude Fable 5.1

# Test suite for zsh-spy.zsh.
#
# Each test drives a real interactive zsh over a pty (zsh/zpty), sources the
# archive script, replays a scenario, and asserts on the JSONL records the
# session leaves behind plus on side effects inside the session.  Run from
# anywhere:
#
#   zsh tests/run.zsh                      # every test
#   zsh tests/run.zsh test_basic test_adoption  # only the named tests
#
# Exit status 0 iff every check passed.  Requires the zsh/zpty module (it is
# a stock zsh module; the suite skips with status 0 if it cannot be loaded,
# so CI on exotic builds does not hard-fail).  python3, when present, is
# additionally used to validate that every record parses as strict JSON.

emulate -L zsh

typeset -g  ZSH_SPY_ROOT="${0:A:h:h}"
typeset -g  ZSH_SPY_SRC="$ZSH_SPY_ROOT/zsh-spy.zsh"
typeset -g  ZSH_SPY_WORK=""
typeset -gi ZSH_SPY_CHECKS=0
typeset -gi ZSH_SPY_FAILS=0
# Everything the current pty session has printed (prompts, command echo,
# command output).  Reset per session; lets tests assert on terminal output,
# e.g. that stderr still reaches the terminal at all.
typeset -g  ZSH_SPY_SESSION_OUT=""

# Record one check result, our assert primitive.
#   $1: 0 for pass, nonzero for fail (typically the $? of a test predicate).
#   $2: human-readable description of the invariant being checked.
# Returns $1 unchanged so callers can chain on it.
zsh_spy_check() {
  local rc="$1" desc="$2"
  (( ZSH_SPY_CHECKS++ ))
  if (( rc != 0 )); then
    (( ZSH_SPY_FAILS++ ))
    print -r -- "FAIL: $desc"
  else
    print -r -- "  ok: $desc"
  fi
  return $rc
}

# Block until pty session $1 has produced no output for ~0.6s.  Silence is
# a heuristic, not proof the command finished: a quiet long-runner (sleep)
# releases early.  That is safe here because pty input is line-buffered and
# processed in order -- anything typed "early" is type-ahead the shell only
# reads after the running command completes -- but it does mean in-session
# waits must be generous enough for background jobs to finish before the
# session's `exit` is reached.  (A prompt-marker wait is not an option: zle
# repaints the prompt while echoing keystrokes, so any marker string shows
# up in the echo immediately.)  Times out after ~10s so a wedged session
# cannot hang the suite.
#   $1: zpty session name.
zsh_spy_settle() {
  local name="$1" chunk
  local -i idle=0
  repeat 100; do
    if zpty -rt "$name" chunk 2>/dev/null; then
      ZSH_SPY_SESSION_OUT+="$chunk"
      idle=0
    else
      (( idle++ ))
    fi
    (( idle >= 6 )) && break
    sleep 0.1
  done
}

# Wait until pty session $1's child has actually stopped, draining output as
# it arrives so a chatty command cannot fill the pty buffer.  An empty
# nonblocking read only means "no output right now"; it says nothing about
# child liveness.  Times out after ~10s.
#   $1: zpty session name.
zsh_spy_wait_exit() {
  local name="$1" chunk
  local -i ticks=0
  while zpty -t "$name" 2>/dev/null; do
    while zpty -rt "$name" chunk 2>/dev/null; do ZSH_SPY_SESSION_OUT+="$chunk"; done
    (( ++ticks >= 200 )) && return 1
    sleep 0.05
  done
  while zpty -rt "$name" chunk 2>/dev/null; do ZSH_SPY_SESSION_OUT+="$chunk"; done
  return 0
}

# Run one scripted interactive session against the archive script.
#   $1:    session name; the archive dir is $ZSH_SPY_WORK/$1 and is exported
#          to the inner shell as ZSH_SPY_DIR (handy for probes that write
#          files).
#   $2...: command lines typed into the session, in order, each followed by
#          a settle wait.  The literal line 'SOURCE' types the source
#          command for the archive script.
# The harness sends `exit` after the scripted commands unless one of them
# already stopped the shell.  Sets REPLY to the first JSONL file the session
# produced, or "" if none was created; re-source tests glob the directory to
# inspect every lifecycle file.
zsh_spy_session() {
  local name="$1" dir="$ZSH_SPY_WORK/$1" cmd
  local -i wait_rc=0
  shift
  ZSH_SPY_SESSION_OUT=""
  mkdir -p -- "$dir"
  zpty -b "$name" env ZSH_SPY_DIR="$dir" zsh -f -i
  zsh_spy_settle "$name"
  for cmd in "$@"; do
    zpty -t "$name" 2>/dev/null || break
    if [[ $cmd == SOURCE ]]; then
      zpty -w "$name" "source ${(q)ZSH_SPY_SRC}"
    else
      zpty -w "$name" "$cmd"
    fi
    zsh_spy_settle "$name"
  done
  if zpty -t "$name" 2>/dev/null; then
    zpty -w "$name" "exit"
  fi
  zsh_spy_wait_exit "$name" || wait_rc=$?
  zpty -d "$name" 2>/dev/null
  local -a files
  files=( "$dir"/hist.*.jsonl(N) )
  REPLY="${files[1]-}"
  if (( wait_rc != 0 )); then
    print -u2 -r -- "ERROR: timed out waiting for zpty session '$name' to exit"
    return $wait_rc
  fi
  return 0
}

# Find the first record of a given type in a JSONL file.
#   $1: JSONL file path.
#   $2: record type, e.g. async_end.
#   $3: optional extra fixed substring the line must also contain.
# Sets REPLY to the matching line, or "" if none.  Returns 0 iff found.
zsh_spy_first_record() {
  local file="$1" typ="$2" extra="${3-}" line
  REPLY=""
  [[ -r $file ]] || return 1
  while IFS= read -r line; do
    [[ $line == *"\"type\":\"$typ\""* ]]                || continue
    if [[ -n $extra ]]; then
      [[ $line == *"$extra"* ]] || continue
    fi
    REPLY="$line"
    return 0
  done < "$file"
  return 1
}

# Count records of a given type in a JSONL file.
#   $1: JSONL file path.
#   $2: record type.
#   $3: optional extra fixed substring the line must also contain.
# Sets REPLY to the count.
zsh_spy_count_records() {
  local file="$1" typ="$2" extra="${3-}" line
  local -i n=0
  if [[ -r $file ]]; then
    while IFS= read -r line; do
      [[ $line == *"\"type\":\"$typ\""* ]]                || continue
      if [[ -n $extra ]]; then
        [[ $line == *"$extra"* ]] || continue
      fi
      (( n++ ))
    done < "$file"
  fi
  REPLY=$n
}

# Extract the value of key $2 from single-line JSON record $1.  The records
# are machine-generated with known keys, so a cheap regex is sufficient;
# this is not a general JSON parser.
#   $1: one JSONL line.
#   $2: key name.
# Sets REPLY to the value (quotes stripped for strings), "" when absent.
zsh_spy_field() {
  local line="$1" key="$2"
  if [[ $line =~ "\"${key}\":\"([^\"]*)\"" ]]; then
    REPLY="${match[1]}"
  elif [[ $line =~ "\"${key}\":([^,}]*)" ]]; then
    REPLY="${match[1]}"
  else
    REPLY=""
  fi
}

# Validate that every line of file $1 parses as strict JSON.
# Returns 0 on success or when python3 is unavailable (check is skipped).
zsh_spy_json_valid() {
  local file="$1"
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -c 'import json,sys
for line in sys.stdin:
    json.loads(line)' < "$file" 2>/dev/null
}

# T1: core plumbing.  session_start is first, session_end is last, a
# command gets paired start/end records with matching ids, and every line
# is valid JSON.
test_basic() {
  print -r -- "T1 basic records"
  local file first last cs ce cs_id ce_id
  zsh_spy_session t1 SOURCE 'echo hello-archive'
  file="$REPLY"
  [[ -n $file && -s $file ]]
  zsh_spy_check $? "t1: session produced a non-empty JSONL file"
  [[ -n $file ]] || return 1
  zsh_spy_json_valid "$file"
  zsh_spy_check $? "t1: every record line parses as strict JSON"
  first="$(head -1 -- "$file")"
  last="$(tail  -1 -- "$file")"
  [[ $first == *'"type":"session_start"'* ]]
  zsh_spy_check $? "t1: first record is session_start"
  [[ $last == *'"type":"session_end"'* ]]
  zsh_spy_check $? "t1: last record is session_end"
  zsh_spy_first_record "$file" command_start 'hello-archive'; cs="$REPLY"
  zsh_spy_check $? "t1: command_start recorded for the echo"
  zsh_spy_field "$cs" id; cs_id="$REPLY"
  zsh_spy_first_record "$file" command_end "\"id\":\"$cs_id\""; ce="$REPLY"
  zsh_spy_check $? "t1: command_end with the matching id"
  zsh_spy_field "$ce" status
  zsh_spy_check $(( REPLY != 0 )) "t1: command_end status is 0"
}

# T2: the histcmd field (fixed from the always-0 zle-only HISTNO) is a
# positive integer that advances between commands.
test_histcmd() {
  print -r -- "T2 histcmd"
  local file c1 c2 h1 h2
  zsh_spy_session t2 SOURCE 'echo first-cmd' 'echo second-cmd'
  file="$REPLY"
  zsh_spy_first_record "$file" command_start 'first-cmd';  c1="$REPLY"
  zsh_spy_first_record "$file" command_start 'second-cmd'; c2="$REPLY"
  zsh_spy_field "$c1" histcmd; h1="$REPLY"
  zsh_spy_field "$c2" histcmd; h2="$REPLY"
  [[ -n $h1 && $h1 != *[!0-9]* ]] && (( h1 > 0 ))
  zsh_spy_check $? "t2: histcmd present and positive (got '$h1')"
  [[ -n $h2 && $h2 != *[!0-9]* ]] && (( h2 > h1 ))
  zsh_spy_check $? "t2: histcmd advances between commands ($h1 -> $h2)"
}

# T3: a pre-existing list-form CHLD trap disables background tracking and
# survives the source unclobbered (the old `trap -p` guard never fired and
# TRAPCHLD() replaced the trap).
test_list_trap_conflict() {
  print -r -- "T3 list-form CHLD trap conflict"
  local file ss
  zsh_spy_session t3 \
    'trap ": user chld" CHLD' \
    SOURCE \
    'builtin trap > "$ZSH_SPY_DIR/traps.txt"'
  file="$REPLY"
  zsh_spy_first_record "$file" session_start; ss="$REPLY"
  [[ $ss == *'"background_tracking":false'* ]]
  zsh_spy_check $? "t3: session_start reports background_tracking:false"
  grep -q 'trap -- .: user chld. CHLD' "$ZSH_SPY_WORK/t3/traps.txt"
  zsh_spy_check $? "t3: user list trap still installed after source"
}

# T4: a pre-existing function-form TRAPCHLD is chained: it keeps running,
# and background tracking still works.
test_function_trap_chain() {
  print -r -- "T4 TRAPCHLD chaining"
  local file ss
  zsh_spy_session t4 \
    'TRAPCHLD() { print -n . >> "$ZSH_SPY_DIR/usermark" }' \
    SOURCE \
    'sleep 0.3 &' \
    'sleep 0.8'
  file="$REPLY"
  zsh_spy_first_record "$file" session_start; ss="$REPLY"
  [[ $ss == *'"background_tracking":true'* ]]
  zsh_spy_check $? "t4: background tracking enabled with function trap present"
  [[ -s $ZSH_SPY_WORK/t4/usermark ]]
  zsh_spy_check $? "t4: chained user TRAPCHLD still runs"
  zsh_spy_first_record "$file" async_end
  zsh_spy_check $? "t4: async_end recorded for the background job"
}

# T5: adoption.  A job that starts and finishes within one command line --
# invisible to precmd because zsh deletes done jobs before precmd hooks
# run -- gets async_start/async_end under the spawning command's id,
# exactly once, and is listed in that command's async_jobs.
test_adoption() {
  print -r -- "T5 short-lived job adoption"
  local file cs cs_id as ae ce
  zsh_spy_session t5 SOURCE 'sleep 0.3 & sleep 0.9'
  file="$REPLY"
  zsh_spy_first_record "$file" command_start 'sleep 0.3'; cs="$REPLY"
  zsh_spy_field "$cs" id; cs_id="$REPLY"
  zsh_spy_first_record "$file" async_start "\"id\":\"$cs_id\""
  zsh_spy_check $? "t5: async_start attributed to the spawning command"
  zsh_spy_first_record "$file" async_end "\"id\":\"$cs_id\""; ae="$REPLY"
  zsh_spy_check $? "t5: async_end attributed to the spawning command"
  zsh_spy_field "$ae" status
  zsh_spy_check $(( REPLY != 0 )) "t5: async_end status is 0"
  zsh_spy_count_records "$file" async_start
  zsh_spy_check $(( REPLY != 1 )) "t5: exactly one async_start (no precmd duplicate), got $REPLY"
  zsh_spy_first_record "$file" command_end "\"id\":\"$cs_id\""; ce="$REPLY"
  zsh_spy_field "$ce" async_jobs
  [[ ${REPLY} == '[1]' ]]
  zsh_spy_check $? "t5: command_end async_jobs lists the adopted job (got '$REPLY')"
}

# T6: signal deaths decode to 128+signum with status_kind "signaled"
# (previously status:null kind:"unknown").
test_signal_status() {
  print -r -- "T6 signal-death status"
  local file ae
  zsh_spy_session t6 SOURCE 'sleep 5 &' 'kill %1' 'sleep 0.5'
  file="$REPLY"
  zsh_spy_first_record "$file" async_end; ae="$REPLY"
  zsh_spy_check $? "t6: async_end recorded for the killed job"
  [[ $ae == *'"status":143'* && $ae == *'"status_kind":"signaled"'* ]]
  zsh_spy_check $? "t6: SIGTERM decodes to status 143 / kind signaled"
}

# T7: nonzero exit codes of background jobs are reported verbatim (the
# removed >255 heuristic must not have taken honest codes with it).
test_exit_status() {
  print -r -- "T7 background exit code"
  local file ae
  zsh_spy_session t7 SOURCE 'zsh -c "exit 3" &' 'sleep 0.5'
  file="$REPLY"
  zsh_spy_first_record "$file" async_end; ae="$REPLY"
  zsh_spy_check $? "t7: async_end recorded"
  [[ $ae == *'"status":3'* && $ae == *'"status_kind":"exit"'* ]]
  zsh_spy_check $? "t7: exit 3 reported as status 3 / kind exit"
}

# T8: the classic cross-prompt lifecycle still works after the adoption
# change: async_start at the spawning command's precmd, async_end from the
# CHLD trap during a later command.
test_cross_prompt() {
  print -r -- "T8 cross-prompt background job"
  local file cs cs_id
  zsh_spy_session t8 SOURCE 'sleep 0.5 &' 'sleep 1'
  file="$REPLY"
  zsh_spy_first_record "$file" command_start 'sleep 0.5'; cs="$REPLY"
  zsh_spy_field "$cs" id; cs_id="$REPLY"
  zsh_spy_first_record "$file" async_start "\"id\":\"$cs_id\""
  zsh_spy_check $? "t8: async_start under the spawning command's id"
  zsh_spy_first_record "$file" async_end "\"id\":\"$cs_id\""
  zsh_spy_check $? "t8: async_end under the spawning command's id"
  zsh_spy_count_records "$file" async_lost
  zsh_spy_check $(( REPLY != 0 )) "t8: no async_lost records, got $REPLY"
}

# T9: hooks no longer clobber the user's REPLY/REPLY2.
test_reply_preserved() {
  print -r -- "T9 REPLY preservation"
  zsh_spy_session t9 SOURCE \
    'REPLY=keepme; REPLY2=metoo' \
    'sleep 0.2 & sleep 0.5' \
    'print -r -- "PROBE:[$REPLY][$REPLY2]" > "$ZSH_SPY_DIR/probe.txt"'
  grep -q 'PROBE:\[keepme\]\[metoo\]' "$ZSH_SPY_WORK/t9/probe.txt"
  zsh_spy_check $? "t9: REPLY/REPLY2 survive prompt cycles and bg jobs"
}

# T10: repeat the exact orderly-exit invariant that used to flake.  The
# harness must wait for the zpty child to stop before deleting the pty; an
# empty nonblocking read is not evidence that zshexit has run.
test_session_end_stress() {
  print -r -- "T10 repeated session_end tail"
  local file last name
  local -i i=0 rc=0
  repeat 8; do
    (( ++i ))
    name="t10_$i"
    zsh_spy_session "$name" SOURCE 'echo tail-probe'
    file="$REPLY"
    last=""
    rc=0
    [[ -n $file && -s $file ]] || rc=1
    if (( rc == 0 )); then
      zsh_spy_json_valid "$file" || rc=1
      last="$(tail -n 1 -- "$file")"
      [[ $last == *'"type":"session_end"'* ]] || rc=1
    fi
    zsh_spy_check $rc "t10: iteration $i is valid JSONL with session_end last"
  done
}

# T11: re-sourcing splits the archive into two complete lifecycles instead of
# silently closing the old descriptor.  Both files must have strict tails, and
# exactly one must carry each termination reason.
test_reload_lifecycle() {
  print -r -- "T11 re-source lifecycle"
  local file first last
  local -a files
  local -i valid=1 reload_count=0 exit_count=0
  zsh_spy_session t11 SOURCE 'echo before-reload' SOURCE 'echo after-reload'
  files=( "$ZSH_SPY_WORK/t11"/hist.*.jsonl(N) )
  (( ${#files[@]} == 2 ))
  zsh_spy_check $? "t11: re-source produced exactly two lifecycle files"
  for file in "${files[@]}"; do
    zsh_spy_json_valid "$file" || valid=0
    first="$(head -n 1 -- "$file")"
    last="$(tail -n 1 -- "$file")"
    [[ $first == *'"type":"session_start"'* ]] || valid=0
    [[ $last == *'"type":"session_end"'* ]] || valid=0
    [[ $last == *'"reason":"archive_reloaded"'* ]] && (( ++reload_count ))
    [[ $last == *'"reason":"zshexit"'* ]] && (( ++exit_count ))
  done
  (( valid && reload_count == 1 && exit_count == 1 ))
  zsh_spy_check $? "t11: both files are complete; reload/zshexit reasons are unique"
  # A bare `typeset name` of an existing parameter prints it, so the
  # re-source used to echo `__zshspy_old_umask=022` at the user.
  [[ $ZSH_SPY_SESSION_OUT != *__zshspy_*=* ]]
  zsh_spy_check $? "t11: re-source prints no archive parameter dump"
  if (( ${#files[@]} )); then
    grep -q 'before-reload' "${files[@]}" && grep -q 'after-reload' "${files[@]}"
    zsh_spy_check $? "t11: commands on both sides of the reload were captured"
  else
    zsh_spy_check 1 "t11: commands on both sides of the reload were captured"
  fi
}

# T12: the wrapper must present the interrupted status to a chained user trap,
# return the user's trap status (zero here, meaning CHLD was handled), and
# survive a re-source without recursion or stale wrapper chaining.
test_trap_status_across_reload() {
  print -r -- "T12 TRAPCHLD status across re-source"
  local actual expected file="$ZSH_SPY_WORK/t12/chld-status"
  expected=$'user:1\nwrapper:0\nuser:1\nwrapper:0'
  zsh_spy_session t12 \
    'TRAPCHLD() { print -r -- "user:$?" >> "$ZSH_SPY_DIR/chld-status" }' \
    SOURCE \
    'false; TRAPCHLD; print -r -- "wrapper:$?" >> "$ZSH_SPY_DIR/chld-status"' \
    SOURCE \
    'false; TRAPCHLD; print -r -- "wrapper:$?" >> "$ZSH_SPY_DIR/chld-status"'
  actual="$(cat -- "$file" 2>/dev/null)"
  [[ $actual == "$expected" ]]
  zsh_spy_check $? "t12: user sees status 1; wrapper returns handled status 0 twice"
}

# T13: deleting the installed wrapper is an explicit user replacement.  A
# later re-source must not resurrect the function that predated the archive.
test_removed_trap_not_resurrected() {
  print -r -- "T13 removed TRAPCHLD stays removed"
  zsh_spy_session t13 \
    'TRAPCHLD() { print -r -- old >> "$ZSH_SPY_DIR/oldmark" }' \
    SOURCE \
    'unfunction TRAPCHLD; : > "$ZSH_SPY_DIR/oldmark"' \
    SOURCE \
    'TRAPCHLD'
  [[ ! -s $ZSH_SPY_WORK/t13/oldmark ]]
  zsh_spy_check $? "t13: re-source did not resurrect a stale user trap"
}

# T14: a user trap body may legitimately mention the archive helper name.  Body
# substring matching must not mistake it for an already-installed wrapper.
test_trap_body_substring() {
  print -r -- "T14 TRAPCHLD body substring"
  zsh_spy_session t14 \
    'TRAPCHLD() { : __zshspy_trap_chld; print -r -- user >> "$ZSH_SPY_DIR/usermark" }' \
    SOURCE \
    'TRAPCHLD'
  grep -qx user "$ZSH_SPY_WORK/t14/usermark"
  zsh_spy_check $? "t14: function trap mentioning helper name is still chained"
}

# T15: force the finalizer down its reentrant queue path.  session_end and the
# in-flight command_end must be flushed before the descriptor is disabled.
test_queued_finalizer() {
  print -r -- "T15 queued finalizer"
  local file last
  zsh_spy_session t15 SOURCE \
    '__zshspy_writing=1; __zshspy_write "{\"type\":\"probe\"}"; exit 7'
  file="$REPLY"
  zsh_spy_json_valid "$file"
  zsh_spy_check $? "t15: forced queued-finalizer output is valid JSONL"
  grep -qx '{"type":"probe"}' "$file"
  zsh_spy_check $? "t15: pre-existing queued record was flushed"
  last="$(tail -n 1 -- "$file")"
  [[ $last == *'"type":"session_end"'* && $last == *'"status":7'* ]]
  zsh_spy_check $? "t15: queued session_end is the strict tail with status 7"
  zsh_spy_first_record "$file" command_end '"reason":"zshexit"'
  zsh_spy_check $? "t15: in-flight exit command received command_end"
}

# T16: hook coexistence.  zsh runs every function in a hook array even when an
# earlier one returns nonzero, and restores $? between the calls (verified
# empirically on zsh 5.9.1), so a hook's return value can neither stop later
# hooks nor change the status they observe.  Assert that user-visible contract
# anyway: with the archive's hooks installed first, later user hooks must still
# run and still see the failed command's status and the nonzero shell exit.
test_hook_chain_status() {
  print -r -- "T16 hook-chain status"
  local file="$ZSH_SPY_WORK/t16/hooks"
  zsh_spy_session t16 SOURCE \
    'later_preexec() { print -r -- "preexec:$?" >> "$ZSH_SPY_DIR/hooks" }; later_precmd() { print -r -- "precmd:$?" >> "$ZSH_SPY_DIR/hooks" }; later_zshexit() { print -r -- "zshexit:$?" >> "$ZSH_SPY_DIR/hooks" }; add-zsh-hook preexec later_preexec; add-zsh-hook precmd later_precmd; add-zsh-hook zshexit later_zshexit' \
    'false' \
    'exit 7'
  grep -qx 'precmd:1' "$file"
  zsh_spy_check $? "t16: later precmd hook observed failed-command status 1"
  grep -qx 'preexec:1' "$file"
  zsh_spy_check $? "t16: later preexec hook ran after the failed command"
  grep -qx 'zshexit:7' "$file"
  zsh_spy_check $? "t16: later zshexit hook observed exit status 7"
}

# T17: an active job cannot continue across an archive re-source because its
# command id belongs to the old session.  Close that lifecycle explicitly with
# async_lost rather than leaving an unmatched async_start.
test_reload_with_active_job() {
  print -r -- "T17 re-source with active job"
  local file lost=""
  local -a files
  zsh_spy_session t17 SOURCE 'sleep 5 &' SOURCE 'kill %1; wait %1 2>/dev/null || true'
  files=( "$ZSH_SPY_WORK/t17"/hist.*.jsonl(N) )
  for file in "${files[@]}"; do
    if zsh_spy_first_record "$file" async_lost '"reason":"archive_reloaded_while_running"'; then
      lost="$REPLY"
      break
    fi
  done
  [[ -n $lost ]]
  zsh_spy_check $? "t17: old lifecycle closes its running job as async_lost"
}

# T18: the session's stderr must keep flowing to the terminal.  Redirections
# attached to exec are permanent, so a stray 2>/dev/null on the fd-close and
# fd-open execs in the source/reload paths used to point the shell's fd 2 --
# and every child's -- at /dev/null for the rest of the session.  The markers
# are computed at runtime so the pty's echo of the typed command line cannot
# satisfy the checks.
test_stderr_visible() {
  print -r -- "T18 stderr visibility"
  zsh_spy_session t18 SOURCE \
    'print -u2 STDERR-$((1000+1))' \
    'command ls /nonexistent-zzz-$((2000+2))' \
    SOURCE \
    'print -u2 STDERR-$((3000+3))'
  [[ $ZSH_SPY_SESSION_OUT == *STDERR-1001* ]]
  zsh_spy_check $? "t18: shell builtin stderr reaches the terminal after source"
  [[ $ZSH_SPY_SESSION_OUT == *"No such file"* ]]
  zsh_spy_check $? "t18: child process stderr reaches the terminal"
  [[ $ZSH_SPY_SESSION_OUT == *STDERR-3003* ]]
  zsh_spy_check $? "t18: stderr still reaches the terminal after a re-source"
}

# T19: command_end.async_jobs must be assembled under the jobs lock.  A
# CHLD trap that adopts a job between the old early copy of the adopted
# list and the lock acquisition used to leave the job out of async_jobs
# while its async_start/async_end records were correct.  The wrapped lock
# helper busy-waits before locking on precmd's second call, i.e. during
# the command line that spawns the job.
test_async_jobs_under_lock() {
  print -r -- "T19 async_jobs assembled under the lock"
  local file ce
  zsh_spy_session t19 SOURCE \
    'functions -c __zshspy_jobs_lock __orig_lock; typeset -gi __n=0; __zshspy_jobs_lock() { if [[ $funcstack[2] == __zshspy_finish_current_command ]] && (( ++__n == 2 )); then repeat 2000000; do :; done; fi; __orig_lock "$@" }' \
    'sleep 0.4 & sleep 0.1' \
    'sleep 0.5'
  file="$REPLY"
  zsh_spy_count_records "$file" async_start
  zsh_spy_check $(( REPLY != 1 )) "t19: exactly one async_start, got $REPLY"
  zsh_spy_first_record "$file" command_end '"async_jobs":[1]'
  zsh_spy_check $? "t19: command_end lists the job adopted before the lock was taken"
}

# T20: the archive must not pass results through REPLY, because a chained
# user TRAPCHLD runs in the wrapper's dynamic scope and can assign REPLY
# between a helper setting it and its caller reading it.  The wrapped
# helper busy-waits at exactly that point while a background job completes;
# the record used to come out as `"reason":user`, which is not JSON.  The
# user trap's own assignment must still land in the user's REPLY.
test_user_trap_reply_clobber() {
  print -r -- "T20 user trap assigning REPLY"
  local file
  zsh_spy_session t20 'TRAPCHLD() { REPLY=user }' SOURCE \
    'functions -c __zshspy_json_string __orig_js; __zshspy_json_string() { __orig_js "$@"; if [[ $1 == precmd ]]; then repeat 2000000; do :; done; fi }' \
    'sleep 0.3 & sleep 0.1' \
    'sleep 0.6' \
    'print -r -- "REPLY:$REPLY" > "$ZSH_SPY_DIR/reply.txt"'
  file="$REPLY"
  zsh_spy_json_valid "$file"
  zsh_spy_check $? "t20: every record is valid JSON with a REPLY-assigning user trap"
  zsh_spy_first_record "$file" command_start 'sleep 0.3 & sleep 0.1'
  zsh_spy_field "$REPLY" id
  zsh_spy_first_record "$file" command_end "\"id\":\"$REPLY\"" && [[ $REPLY == *'"reason":"precmd"'* ]]
  zsh_spy_check $? "t20: the interleaved command_end kept its reason"
  grep -qx 'REPLY:user' "$ZSH_SPY_WORK/t20/reply.txt"
  zsh_spy_check $? "t20: the user trap's REPLY assignment reaches the user's shell"
}

# T21: the chained user TRAPCHLD must run as the user wrote it.  The
# wrapper used to call it under `emulate -L zsh`, whose LOCAL_OPTIONS and
# LOCAL_TRAPS undid any setopt or trap the user trap made.  Without the
# emulation the deliberately nonzero status handed to the user trap must
# not trip ERR_RETURN before the trap is called.
test_user_trap_isolation() {
  print -r -- "T21 user trap runs under the user's options"
  zsh_spy_session t21 \
    'TRAPCHLD() { setopt noclobber; TRAPUSR1() { :; } }' SOURCE \
    'sleep 0.2 &' 'sleep 0.5' \
    'print -r -- "clobber=$options[clobber] usr1=${+functions[TRAPUSR1]}" > "$ZSH_SPY_DIR/opts.txt"'
  grep -qx 'clobber=off usr1=1' "$ZSH_SPY_WORK/t21/opts.txt"
  zsh_spy_check $? "t21: setopt and trap made by the user trap persist"
  zsh_spy_session t21b \
    'setopt errreturn; TRAPCHLD() { print -r -- "user:$?" >> "$ZSH_SPY_DIR/chld.txt" }' SOURCE \
    'sleep 0.3 & false; sleep 0.6'
  grep -qx 'user:1' "$ZSH_SPY_WORK/t21b/chld.txt"
  zsh_spy_check $? "t21: user trap still called with the interrupted status under ERR_RETURN"
}

# T22: Ctrl-C aborts running hook code at the next statement boundary.  An
# interrupt landing while precmd held the writer flag and the jobs lock
# used to leave both set for the rest of the session: no async records
# were ever produced again and every record piled up in the in-memory
# queue.  The wrapped writer busy-waits once (during the arming line's own
# command_end) so the harness can land the interrupt inside the locks.
test_interrupted_hook_recovers() {
  print -r -- "T22 hook interrupted by Ctrl-C"
  local file
  zsh_spy_session t22 SOURCE \
    'functions -c __zshspy_raw_write __orig_raw_write; typeset -gi __spun=0; __zshspy_raw_write() { if (( ! __spun )); then __spun=1; repeat 4000000; do :; done; fi; __orig_raw_write "$@" }' \
    $'\x03' \
    'sleep 0.3 &' \
    'sleep 0.8' \
    'print -r -- "busy=$__zshspy_jobs_busy writing=$__zshspy_writing queue=${#__zshspy_queue}" > "$ZSH_SPY_DIR/locks.txt"'
  file="$REPLY"
  grep -qx 'busy=0 writing=0 queue=0' "$ZSH_SPY_WORK/t22/locks.txt"
  zsh_spy_check $? "t22: locks released and queue empty after the interrupt (got '$(cat "$ZSH_SPY_WORK/t22/locks.txt" 2>/dev/null)')"
  zsh_spy_first_record "$file" async_end
  zsh_spy_check $? "t22: a background job started after the interrupt is still tracked"
  zsh_spy_first_record "$file" command_end '"reason":"precmd"' && zsh_spy_first_record "$file" command_start 'sleep 0.8'
  zsh_spy_check $? "t22: commands after the interrupt are still logged"
  zsh_spy_json_valid "$file" && [[ "$(tail -n 1 -- "$file")" == *'"type":"session_end"'* ]]
  zsh_spy_check $? "t22: file is valid JSONL ending in session_end"
}

# T23: zsh runs the CHLD trap for every job except the one it is waiting
# on, so a finished foreground job can still sit in the job table when a
# background job's trap runs.  Adoption used to log such a job as
# background.  The terminal's owning process group tells the two apart for
# a pipeline whose head is the group leader (a background pipeline keeps
# running; a foreground one still owns the terminal), which is the
# deterministic, reproducible half of the bug.  Assert that half here, and
# that no real background job is ever missed; the residual same-instant
# foreground/background race is documented, not asserted (it would flap).
test_foreground_not_adopted() {
  print -r -- "T23 foreground pipelines are not adopted"
  local file
  local -a cmds
  # Foreground pipelines whose head is a distinct process: never background.
  cmds=( 'false | { sleep 0.2; :; }' 'print hi | { read a; sleep 0.2 }' )
  # Ten genuine background jobs that must all be captured.
  repeat 10; do cmds+=( 'sleep 0.2 & sleep 0.5' ); done
  # A genuine background pipeline that must be captured.
  cmds+=( 'sleep 0.2 | cat & sleep 0.5' )
  zsh_spy_session t23 SOURCE "${cmds[@]}"
  file="$REPLY"
  zsh_spy_count_records "$file" async_start '"job_text":"false"'
  local -i n_false=$REPLY
  zsh_spy_count_records "$file" async_start '"job_text":"print hi"'
  zsh_spy_check $(( n_false + REPLY != 0 )) "t23: foreground pipeline heads are not adopted (got $n_false, $REPLY)"
  zsh_spy_count_records "$file" async_end '"job_text":"sleep 0.2"'
  zsh_spy_check $(( REPLY < 10 )) "t23: every background job is captured (>=10), got $REPLY"
  zsh_spy_count_records "$file" async_end '"job_text":"sleep 0.2 | cat"'
  zsh_spy_check $(( REPLY != 1 )) "t23: a background pipeline is still captured, got $REPLY"
  zsh_spy_json_valid "$file"
  zsh_spy_check $? "t23: every record parses as strict JSON"
}

# T24: JSON escaping is exhaustive and reversible.  No pty: source the
# archive in an interactive -c shell (the helpers are only defined under
# `[[ -o interactive ]]`) and fuzz __zshspy_json_string over every C0
# control, quote, backslash, DEL and some multibyte text, then check each
# escaped record is strict JSON that decodes back to the original.  NUL is
# checked separately because it also serves as the raw-string separator.
test_json_escape() {
  print -r -- "T24 JSON escaping"
  local dir="$ZSH_SPY_WORK/t24"
  mkdir -p -- "$dir"
  if ! command -v python3 >/dev/null 2>&1; then
    zsh_spy_check 0 "t24: skipped (python3 unavailable)"
    return 0
  fi
  env ZSH_SPY_DIR="$dir" ZSH_SPY_SRC="$ZSH_SPY_SRC" zsh -f -i -c 'source "$ZSH_SPY_SRC"
typeset -a pool
typeset -i i n
for i in {1..31} {34..47} {58..64} {91..96} {123..126} 127; do pool+=( "${(#)i}" ); done
pool+=( a z 0 9 " " "\\" "\"" / "é" "日本" "😀" )
: > "$ZSH_SPY_DIR/in.bin"; : > "$ZSH_SPY_DIR/out.txt"
repeat 4000; do
  s=""; n=$(( RANDOM % 12 ))
  repeat $n; do s+="${pool[RANDOM % ${#pool} + 1]}"; done
  __zshspy_json_string "$s"
  print -rn -- "$s${(#)0}" >> "$ZSH_SPY_DIR/in.bin"
  print -r  -- "$__zshspy_r" >> "$ZSH_SPY_DIR/out.txt"
done
'
  D="$dir" python3 -c 'import json,sys,os
d=os.environ["D"]
raw=open(d+"/in.bin","rb").read().split(b"\0")[:-1]
esc=open(d+"/out.txt","rb").read().decode("utf-8","surrogateescape").splitlines()
assert len(raw)==len(esc),(len(raw),len(esc))
for r,e in zip(raw,esc):
    assert json.loads(e)==r.decode("utf-8","surrogateescape"),(r,e)
'
  zsh_spy_check $? "t24: fuzzed strings escape to strict JSON that round-trips"
  local out
  out="$(env ZSH_SPY_DIR="$dir" ZSH_SPY_SRC="$ZSH_SPY_SRC" zsh -f -i -c 'source "$ZSH_SPY_SRC"; __zshspy_json_string "a${(#)0}b"; print -r -- "$__zshspy_r"')"
  [[ $out == '"a\u0000b"' ]]
  zsh_spy_check $? "t24: NUL escapes to \\u0000 (got $out)"
}

# T25: status decoding sweep.  Background jobs that exit with assorted
# codes must report those codes verbatim (kind "exit"), and jobs killed by
# a signal must report 128+signum (kind "signaled"); a real-time signal,
# which zsh cannot name, must report null.  This is a property check over
# many values, not a single case.
test_status_decoding() {
  print -r -- "T25 status decoding sweep"
  local file ae
  local -a codes; codes=( 0 1 2 42 126 127 255 )
  local -a sigs;  sigs=( HUP INT KILL TERM USR1 SEGV )
  local -a cmds; cmds=()
  # Each killed job gets a unique numeric duration so its record is easy to
  # find; "sleep 300.<n>" is a valid, safely long interval.
  local c s; local -i idx=0
  for c in "${codes[@]}"; do cmds+=( "zsh -c 'exit $c' & sleep 0.4" ); done
  for s in "${sigs[@]}"; do
    (( idx++ )); cmds+=( "sleep 300.$idx & sleep 0.15; kill -$s %1; sleep 0.4" )
  done
  cmds+=( "sleep 300.99 & sleep 0.15; kill -34 %1; sleep 0.4" )
  zsh_spy_session t25 SOURCE "${cmds[@]}"
  file="$REPLY"
  local -i fails=0 num
  for c in "${codes[@]}"; do
    zsh_spy_first_record "$file" async_end "\"job_text\":\"zsh -c 'exit $c'\""; ae="$REPLY"
    [[ $ae == *"\"status\":$c,\"status_kind\":\"exit\""* ]] || { (( fails++ )); print -r -- "  exit $c: ${ae:-<none>}"; }
  done
  zsh_spy_check $fails "t25: exit codes decode verbatim ($fails mismatches)"
  fails=0; idx=0
  for s in "${sigs[@]}"; do
    (( idx++ )); num=$(( ${signals[(i)$s]} - 1 ))
    zsh_spy_first_record "$file" async_end "\"job_text\":\"sleep 300.$idx\""; ae="$REPLY"
    [[ $ae == *"\"status\":$(( 128 + num )),\"status_kind\":\"signaled\""* ]] || { (( fails++ )); print -r -- "  $s: ${ae:-<none>}"; }
  done
  zsh_spy_check $fails "t25: signal deaths decode to 128+signum ($fails mismatches)"
  zsh_spy_first_record "$file" async_end '"job_text":"sleep 300.99"'; ae="$REPLY"
  [[ $ae == *'"status":null,"status_kind":"signaled"'* ]]
  zsh_spy_check $? "t25: a real-time signal reports null / signaled"
}

# T26: exactly-once invariants under many jobs.  Every background job that
# the archive records must get exactly one async_start and one async_end
# and never async_lost; no (id, job) pair may repeat.  These hold over
# whatever was captured.  Exact totals are deliberately not asserted: a
# burst of jobs exiting in the same instant can coalesce their SIGCHLD and
# occasionally outrun observation, a documented loss (see the header), so
# the test asserts a generous floor rather than a precise count.
test_many_jobs() {
  print -r -- "T26 exactly-once under many jobs"
  local file
  zsh_spy_session t26 SOURCE \
    'for i in {10..29}; do sleep 0.$i & done; sleep 2.5' \
    'for i in {1..8}; do sleep 1.$i & done' \
    'sleep 3.5' \
    'zsh -c "exit 9" & zsh -c "exit 7" & sleep 1'
  file="$REPLY"
  zsh_spy_json_valid "$file"
  zsh_spy_check $? "t26: every record parses as strict JSON"
  local -i starts ends lost uniq_start uniq_end
  zsh_spy_count_records "$file" async_start; starts=$REPLY
  zsh_spy_count_records "$file" async_end;   ends=$REPLY
  zsh_spy_count_records "$file" async_lost;  lost=$REPLY
  uniq_start=$(grep '"type":"async_start"' "$file" | sed -E 's/.*"id":"([^"]*)".*"job":([0-9]+).*/\1 \2/' | sort -u | wc -l)
  uniq_end=$(grep '"type":"async_end"' "$file" | sed -E 's/.*"id":"([^"]*)".*"job":([0-9]+).*/\1 \2/' | sort -u | wc -l)
  zsh_spy_check $(( starts != ends )) "t26: async_start and async_end counts match ($starts vs $ends)"
  zsh_spy_check $(( lost != 0 )) "t26: no async_lost, got $lost"
  zsh_spy_check $(( uniq_start != starts || uniq_end != ends )) "t26: no duplicate (id,job) records ($uniq_start/$starts start, $uniq_end/$ends end)"
  zsh_spy_check $(( starts < 28 )) "t26: the vast majority of 30 jobs were captured, got $starts"
}

# T27: session_start identifies its writers.  zsh_version is the running
# shell's $ZSH_VERSION, and zsh_spy_version is the literal the archive source
# declares, read from the source text rather than from the session so a
# mangled declaration cannot be echoed back as a match.  (An integer typeset
# of "2026.09.16" is a math error that aborts the entire source.)
test_session_start_versions() {
  print -r -- "T27 session_start version fields"
  local file ss got want
  zsh_spy_session t27 SOURCE \
    'print -r -- "$ZSH_VERSION" > "$ZSH_SPY_DIR/zsh_version.txt"'
  file="$REPLY"
  zsh_spy_first_record "$file" session_start; ss="$REPLY"
  [[ -n $ss ]]
  zsh_spy_check $? "t27: session_start recorded"
  zsh_spy_field "$ss" zsh_version; got="$REPLY"
  want="$(<"$ZSH_SPY_WORK/t27/zsh_version.txt")"
  [[ -n $want && $got == "$want" ]]
  zsh_spy_check $? "t27: zsh_version is the session's ZSH_VERSION (got '$got', want '$want')"
  zsh_spy_field "$ss" zsh_spy_version; got="$REPLY"
  want=""
  [[ "$(<"$ZSH_SPY_SRC")" =~ 'typeset -g[[:alpha:]]* +__zshspy_version="([^"]*)"' ]] && want="${match[1]}"
  [[ -n $want && $got == "$want" ]]
  zsh_spy_check $? "t27: zsh_spy_version is the declared version (got '$got', want '$want')"
}

# Entry point: run the named tests, or every test, against a scratch dir and
# report a summary.
#   $@: test function names to run; empty means all of them.
main() {
  if ! zmodload zsh/zpty 2>/dev/null; then
    print -r -- "SKIP: zsh/zpty unavailable; cannot drive a pty session"
    exit 0
  fi
  if [[ ! -r $ZSH_SPY_SRC ]]; then
    print -r -- "ERROR: cannot read $ZSH_SPY_SRC"
    exit 2
  fi
  ZSH_SPY_WORK="$(mktemp -d)"
  local -a all_tests
  all_tests=(
    test_basic
    test_histcmd
    test_list_trap_conflict
    test_function_trap_chain
    test_adoption
    test_signal_status
    test_exit_status
    test_cross_prompt
    test_reply_preserved
    test_session_end_stress
    test_reload_lifecycle
    test_trap_status_across_reload
    test_removed_trap_not_resurrected
    test_trap_body_substring
    test_queued_finalizer
    test_hook_chain_status
    test_reload_with_active_job
    test_stderr_visible
    test_async_jobs_under_lock
    test_user_trap_reply_clobber
    test_user_trap_isolation
    test_interrupted_hook_recovers
    test_foreground_not_adopted
    test_json_escape
    test_status_decoding
    test_many_jobs
    test_session_start_versions
  )
  local -a tests
  if (( $# )); then
    local sel
    for sel in "$@"; do
      if (( ! ${all_tests[(Ie)$sel]} )); then
        print -u2 -r -- "ERROR: unknown test '$sel'"
        return 2
      fi
    done
    tests=( "$@" )
  else
    tests=( "${all_tests[@]}" )
  fi
  local t
  for t in "${tests[@]}"; do "$t"; done
  print -r -- "----"
  print -r -- "checks: $ZSH_SPY_CHECKS  failures: $ZSH_SPY_FAILS"
  if (( ZSH_SPY_FAILS != 0 )); then
    print -r -- "artifacts kept for inspection under: $ZSH_SPY_WORK"
    return 1
  fi
  rm -rf -- "$ZSH_SPY_WORK"
  return 0
}

main "$@"
