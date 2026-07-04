#!/usr/bin/env zsh
# Test suite for zsh-history-archive.zsh.
#
# Each test drives a real interactive zsh over a pty (zsh/zpty), sources the
# archive script, replays a scenario, and asserts on the JSONL records the
# session leaves behind plus on side effects inside the session.  Run from
# anywhere:
#
#   zsh tests/run.zsh
#
# Exit status 0 iff every check passed.  Requires the zsh/zpty module (it is
# a stock zsh module; the suite skips with status 0 if it cannot be loaded,
# so CI on exotic builds does not hard-fail).  python3, when present, is
# additionally used to validate that every record parses as strict JSON.

emulate -L zsh

typeset -g  ZHA_ROOT="${0:A:h:h}"
typeset -g  ZHA_SRC="$ZHA_ROOT/zsh-history-archive.zsh"
typeset -g  ZHA_WORK=""
typeset -gi ZHA_CHECKS=0
typeset -gi ZHA_FAILS=0

# Record one check result, our assert primitive.
#   $1: 0 for pass, nonzero for fail (typically the $? of a test predicate).
#   $2: human-readable description of the invariant being checked.
# Returns $1 unchanged so callers can chain on it.
zha_check() {
  local rc="$1" desc="$2"
  (( ZHA_CHECKS++ ))
  if (( rc != 0 )); then
    (( ZHA_FAILS++ ))
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
zha_settle() {
  local name="$1" chunk
  local -i idle=0
  repeat 100; do
    if zpty -rt "$name" chunk 2>/dev/null; then
      idle=0
    else
      (( idle++ ))
    fi
    (( idle >= 6 )) && break
    sleep 0.1
  done
}

# Run one scripted interactive session against the archive script.
#   $1:    session name; the archive dir is $ZHA_WORK/$1 and the same path
#          is exported to the inner shell as both ZSH_HISTORY_ARCHIVE_DIR
#          and ZHA_DIR (handy for probes that write files).
#   $2...: command lines typed into the session, in order, each followed by
#          a settle wait.  The literal line 'SOURCE' types the source
#          command for the archive script.
# The session always ends with `exit`.  Sets REPLY to the JSONL file the
# session produced, or "" if none was created.
zha_session() {
  local name="$1" dir="$ZHA_WORK/$1" cmd chunk
  shift
  mkdir -p -- "$dir"
  zpty -b "$name" env ZSH_HISTORY_ARCHIVE_DIR="$dir" ZHA_DIR="$dir" zsh -f -i
  zha_settle "$name"
  for cmd in "$@"; do
    if [[ $cmd == SOURCE ]]; then
      zpty -w "$name" "source ${(q)ZHA_SRC}"
    else
      zpty -w "$name" "$cmd"
    fi
    zha_settle "$name"
  done
  zpty -w "$name" "exit"
  while zpty -r "$name" chunk 2>/dev/null; do :; done
  zpty -d "$name" 2>/dev/null
  local -a files
  files=( "$dir"/hist.*.jsonl(N) )
  REPLY="${files[1]-}"
}

# Find the first record of a given type in a JSONL file.
#   $1: JSONL file path.
#   $2: record type, e.g. async_end.
#   $3: optional extra fixed substring the line must also contain.
# Sets REPLY to the matching line, or "" if none.  Returns 0 iff found.
zha_first_record() {
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
zha_count_records() {
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
zha_field() {
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
zha_json_valid() {
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
  zha_session t1 SOURCE 'echo hello-archive'
  file="$REPLY"
  [[ -n $file && -s $file ]]
  zha_check $? "t1: session produced a non-empty JSONL file"
  [[ -n $file ]] || return 1
  zha_json_valid "$file"
  zha_check $? "t1: every record line parses as strict JSON"
  first="$(head -1 -- "$file")"
  last="$(tail  -1 -- "$file")"
  [[ $first == *'"type":"session_start"'* ]]
  zha_check $? "t1: first record is session_start"
  [[ $last == *'"type":"session_end"'* ]]
  zha_check $? "t1: last record is session_end"
  zha_first_record "$file" command_start 'hello-archive'; cs="$REPLY"
  zha_check $? "t1: command_start recorded for the echo"
  zha_field "$cs" id; cs_id="$REPLY"
  zha_first_record "$file" command_end "\"id\":\"$cs_id\""; ce="$REPLY"
  zha_check $? "t1: command_end with the matching id"
  zha_field "$ce" status
  zha_check $(( REPLY != 0 )) "t1: command_end status is 0"
}

# T2: the histcmd field (fixed from the always-0 zle-only HISTNO) is a
# positive integer that advances between commands.
test_histcmd() {
  print -r -- "T2 histcmd"
  local file c1 c2 h1 h2
  zha_session t2 SOURCE 'echo first-cmd' 'echo second-cmd'
  file="$REPLY"
  zha_first_record "$file" command_start 'first-cmd';  c1="$REPLY"
  zha_first_record "$file" command_start 'second-cmd'; c2="$REPLY"
  zha_field "$c1" histcmd; h1="$REPLY"
  zha_field "$c2" histcmd; h2="$REPLY"
  [[ -n $h1 && $h1 != *[!0-9]* ]] && (( h1 > 0 ))
  zha_check $? "t2: histcmd present and positive (got '$h1')"
  [[ -n $h2 && $h2 != *[!0-9]* ]] && (( h2 > h1 ))
  zha_check $? "t2: histcmd advances between commands ($h1 -> $h2)"
}

# T3: a pre-existing list-form CHLD trap disables background tracking and
# survives the source unclobbered (the old `trap -p` guard never fired and
# TRAPCHLD() replaced the trap).
test_list_trap_conflict() {
  print -r -- "T3 list-form CHLD trap conflict"
  local file ss
  zha_session t3 \
    'trap ": user chld" CHLD' \
    SOURCE \
    'builtin trap > "$ZHA_DIR/traps.txt"'
  file="$REPLY"
  zha_first_record "$file" session_start; ss="$REPLY"
  [[ $ss == *'"background_tracking":false'* ]]
  zha_check $? "t3: session_start reports background_tracking:false"
  grep -q 'trap -- .: user chld. CHLD' "$ZHA_WORK/t3/traps.txt"
  zha_check $? "t3: user list trap still installed after source"
}

# T4: a pre-existing function-form TRAPCHLD is chained: it keeps running,
# and background tracking still works.
test_function_trap_chain() {
  print -r -- "T4 TRAPCHLD chaining"
  local file ss
  zha_session t4 \
    'TRAPCHLD() { print -n . >> "$ZHA_DIR/usermark" }' \
    SOURCE \
    'sleep 0.3 &' \
    'sleep 0.8'
  file="$REPLY"
  zha_first_record "$file" session_start; ss="$REPLY"
  [[ $ss == *'"background_tracking":true'* ]]
  zha_check $? "t4: background tracking enabled with function trap present"
  [[ -s $ZHA_WORK/t4/usermark ]]
  zha_check $? "t4: chained user TRAPCHLD still runs"
  zha_first_record "$file" async_end
  zha_check $? "t4: async_end recorded for the background job"
}

# T5: adoption.  A job that starts and finishes within one command line --
# invisible to precmd because zsh deletes done jobs before precmd hooks
# run -- gets async_start/async_end under the spawning command's id,
# exactly once, and is listed in that command's async_jobs.
test_adoption() {
  print -r -- "T5 short-lived job adoption"
  local file cs cs_id as ae ce
  zha_session t5 SOURCE 'sleep 0.3 & sleep 0.9'
  file="$REPLY"
  zha_first_record "$file" command_start 'sleep 0.3'; cs="$REPLY"
  zha_field "$cs" id; cs_id="$REPLY"
  zha_first_record "$file" async_start "\"id\":\"$cs_id\""
  zha_check $? "t5: async_start attributed to the spawning command"
  zha_first_record "$file" async_end "\"id\":\"$cs_id\""; ae="$REPLY"
  zha_check $? "t5: async_end attributed to the spawning command"
  zha_field "$ae" status
  zha_check $(( REPLY != 0 )) "t5: async_end status is 0"
  zha_count_records "$file" async_start
  zha_check $(( REPLY != 1 )) "t5: exactly one async_start (no precmd duplicate), got $REPLY"
  zha_first_record "$file" command_end "\"id\":\"$cs_id\""; ce="$REPLY"
  zha_field "$ce" async_jobs
  [[ ${REPLY} == '[1]' ]]
  zha_check $? "t5: command_end async_jobs lists the adopted job (got '$REPLY')"
}

# T6: signal deaths decode to 128+signum with status_kind "signaled"
# (previously status:null kind:"unknown").
test_signal_status() {
  print -r -- "T6 signal-death status"
  local file ae
  zha_session t6 SOURCE 'sleep 5 &' 'kill %1' 'sleep 0.5'
  file="$REPLY"
  zha_first_record "$file" async_end; ae="$REPLY"
  zha_check $? "t6: async_end recorded for the killed job"
  [[ $ae == *'"status":143'* && $ae == *'"status_kind":"signaled"'* ]]
  zha_check $? "t6: SIGTERM decodes to status 143 / kind signaled"
}

# T7: nonzero exit codes of background jobs are reported verbatim (the
# removed >255 heuristic must not have taken honest codes with it).
test_exit_status() {
  print -r -- "T7 background exit code"
  local file ae
  zha_session t7 SOURCE 'zsh -c "exit 3" &' 'sleep 0.5'
  file="$REPLY"
  zha_first_record "$file" async_end; ae="$REPLY"
  zha_check $? "t7: async_end recorded"
  [[ $ae == *'"status":3'* && $ae == *'"status_kind":"exit"'* ]]
  zha_check $? "t7: exit 3 reported as status 3 / kind exit"
}

# T8: the classic cross-prompt lifecycle still works after the adoption
# change: async_start at the spawning command's precmd, async_end from the
# CHLD trap during a later command.
test_cross_prompt() {
  print -r -- "T8 cross-prompt background job"
  local file cs cs_id
  zha_session t8 SOURCE 'sleep 0.5 &' 'sleep 1'
  file="$REPLY"
  zha_first_record "$file" command_start 'sleep 0.5'; cs="$REPLY"
  zha_field "$cs" id; cs_id="$REPLY"
  zha_first_record "$file" async_start "\"id\":\"$cs_id\""
  zha_check $? "t8: async_start under the spawning command's id"
  zha_first_record "$file" async_end "\"id\":\"$cs_id\""
  zha_check $? "t8: async_end under the spawning command's id"
  zha_count_records "$file" async_lost
  zha_check $(( REPLY != 0 )) "t8: no async_lost records, got $REPLY"
}

# T9: hooks no longer clobber the user's REPLY/REPLY2.
test_reply_preserved() {
  print -r -- "T9 REPLY preservation"
  zha_session t9 SOURCE \
    'REPLY=keepme; REPLY2=metoo' \
    'sleep 0.2 & sleep 0.5' \
    'print -r -- "PROBE:[$REPLY][$REPLY2]" > "$ZHA_DIR/probe.txt"'
  grep -q 'PROBE:\[keepme\]\[metoo\]' "$ZHA_WORK/t9/probe.txt"
  zha_check $? "t9: REPLY/REPLY2 survive prompt cycles and bg jobs"
}

# Entry point: run every test against a scratch dir and report a summary.
main() {
  if ! zmodload zsh/zpty 2>/dev/null; then
    print -r -- "SKIP: zsh/zpty unavailable; cannot drive a pty session"
    exit 0
  fi
  if [[ ! -r $ZHA_SRC ]]; then
    print -r -- "ERROR: cannot read $ZHA_SRC"
    exit 2
  fi
  ZHA_WORK="$(mktemp -d)"
  test_basic
  test_histcmd
  test_list_trap_conflict
  test_function_trap_chain
  test_adoption
  test_signal_status
  test_exit_status
  test_cross_prompt
  test_reply_preserved
  print -r -- "----"
  print -r -- "checks: $ZHA_CHECKS  failures: $ZHA_FAILS"
  if (( ZHA_FAILS != 0 )); then
    print -r -- "artifacts kept for inspection under: $ZHA_WORK"
    return 1
  fi
  rm -rf -- "$ZHA_WORK"
  return 0
}

main "$@"
