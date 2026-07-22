#!/usr/bin/env zsh

# Note: to start logging, this file must be sourced, not executed.

# This was authored by ChatGPT 5.5 Pro on 2026-05-03, using some earlier
# inputs from ChatGPT 5.2 Thinking.
#
# It was then fixed up by Claude Fable 5; audited against the zsh master source
# (5.9.999.3-test) and tested on zsh 5.9.

# zsh JSONL history archive
# Install: source this near the end of ~/.zshrc.
#
# Records go to one unique JSONL file per interactive zsh session:
#   ${ZSH_SPY_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/zsh-spy}/hist.<session>.jsonl
#
# Record types:
#   session_start
#   command_start       before zsh executes the entered command line
#   command_end         after zsh returns from evaluating the entered command line
#   async_start         after zsh has registered a newly-created background job;
#                       jobs that finish before their spawning command line does
#                       are adopted from the CHLD trap (zsh deletes done jobs
#                       before precmd hooks can run) and attributed to that
#                       command's id
#   async_end           when a tracked background job reaches zsh job-state "done"
#   async_lost          if a tracked background job disappears from zsh's job table
#   session_end
#
# Status fields: command_end.status is $?.  async_end.status is the exit
# code of the job's last process (both the raw-wait-status encoding of
# zsh <= 5.9 and the plain-code encoding of later zsh are normalized), or
# 128+signum with status_kind "signaled" for signal deaths, or null with
# status_kind "unknown" when it cannot be determined.
#
# Intentional design choices:
# - JSON Lines, one object per line.
# - One file per zsh process: no locking and no cross-shell append interleaving.
# - Background completion tracking uses zsh's job table, not PID guessing.
# - This block unsets NOTIFY so the CHLD trap can see completed jobs before zsh
#   prints/deletes them. Install this near the end of ~/.zshrc and do not setopt
#   NOTIFY afterwards if you want reliable async_end records.
#
# XXX: zsh does not expose an exact, non-consuming "wait status" for background
# pipelines. For async_end, status is the parsed status of the last process in
# the job; the full per-process state array is also logged. Simple "cmd &" jobs
# get the exact command exit status.
#
# XXX: list-form pre-existing CHLD traps are not safely chainable here. If one is
# present when this file is sourced, background completion tracking is disabled
# rather than clobbering that trap. Function-form TRAPCHLD is chained.
#
# XXX: the JSON escaping covers the C0 controls, but NUL and bytes that are
# not valid UTF-8 pass through verbatim (zsh strings are 8-bit clean), so a
# command line containing such bytes yields a record that strict JSON
# parsers reject. Recovering consumers should skip unparseable lines.
#
# XXX: without zsh/system there is no sysopen, and the plain-redirection
# fallback cannot set close-on-exec, so every child process inherits the
# archive fd. Records written by traps may also appear later in the file
# than records with earlier timestamps; order by epoch_s/epoch_ns.

if [[ -o interactive && ${ZSH_SUBSHELL:-0} == 0 ]]; then
  setopt EXTENDED_HISTORY

  autoload -Uz add-zsh-hook 2>/dev/null || true

  # Remove old hooks if this file is re-sourced.
  add-zsh-hook -d preexec __zshspy_preexec 2>/dev/null || true
  add-zsh-hook -d precmd  __zshspy_precmd  2>/dev/null || true
  add-zsh-hook -d zshexit __zshspy_zshexit 2>/dev/null || true

  # Close old fd if this file is re-sourced.
  if (( ${+__zshspy_fd} && __zshspy_fd >= 0 )); then
    exec {__zshspy_fd}>&- 2>/dev/null || true
  fi

  zmodload zsh/datetime  2>/dev/null || true
  zmodload zsh/system    2>/dev/null || true
  zmodload zsh/parameter 2>/dev/null || true

  typeset -gi __zshspy_enabled=0
  typeset -gi __zshspy_have_syswrite=0
  typeset -gi __zshspy_have_datetime=0
  typeset -gi __zshspy_have_jobparams=0
  typeset -gi __zshspy_bg_enabled=0
  typeset -gi __zshspy_chld_conflict=0
  typeset -gi __zshspy_chained_user_chld=0
  # Record the user's original NOTIFY preference exactly once per shell:
  # a re-source runs after the archive itself already did `unsetopt NOTIFY`,
  # so probing [[ -o notify ]] again would report false regardless of the
  # user's configuration.
  if (( ! ${+__zshspy_notify_was_on} )); then
    typeset -gi __zshspy_notify_was_on=0
    [[ -o notify ]] && __zshspy_notify_was_on=1
  fi
  typeset -gi __zshspy_fd=-1
  typeset -gi __zshspy_seq=0
  typeset -gi __zshspy_writing=0

  (( ${+builtins} && ${+builtins[syswrite]} )) && __zshspy_have_syswrite=1
  (( ${+epochtime} && ${+builtins} && ${+builtins[strftime]} )) && __zshspy_have_datetime=1
  (( ${+jobstates} && ${+jobtexts} && ${+jobdirs} )) && __zshspy_have_jobparams=1

  typeset -g  __zshspy_session_id=""
  typeset -g  __zshspy_file=""
  typeset -g  __zshspy_dir=""
  typeset -g  __zshspy_cur_id=""
  typeset -g  __zshspy_host="${HOST:-${HOSTNAME:-unknown-host}}"
  typeset -g  __zshspy_user="${USER:-${USERNAME:-unknown-user}}"
  typeset -g  __zshspy_shell_pid="$$"
  typeset -g  __zshspy_now_s=0
  typeset -g  __zshspy_now_ns=0
  typeset -g  __zshspy_now_ts=""
  typeset -ga __zshspy_queue=()
  typeset -gA __zshspy_cmd_start_s=()
  typeset -gA __zshspy_cmd_start_ns=()
  typeset -gA __zshspy_job_cmd_id=()
  typeset -gA __zshspy_job_start_s=()
  typeset -gA __zshspy_job_start_ns=()
  typeset -gA __zshspy_jobs_before_pids=()
  typeset -gA __zshspy_job_logged_done=()
  typeset -ga __zshspy_cur_adopted=()

  if (( ${+sysparams} )) && [[ -n ${sysparams[pid]-} ]]; then
    __zshspy_shell_pid="${sysparams[pid]}"
  fi

  __zshspy_now() {
    emulate -L zsh
    if (( ${+epochtime} )); then
      local -a _t
      _t=( "${epochtime[@]}" )
      __zshspy_now_s="${_t[1]}"
      __zshspy_now_ns="${_t[2]}"
    else
      __zshspy_now_s=0
      __zshspy_now_ns=0
      __zshspy_now_ts=""
      return 1
    fi
    if (( ${+builtins} && ${+builtins[strftime]} )); then
      strftime -s __zshspy_now_ts '%Y-%m-%dT%H:%M:%S%z' "$__zshspy_now_s" "$__zshspy_now_ns" 2>/dev/null || \
        __zshspy_now_ts="$__zshspy_now_s"
    else
      __zshspy_now_ts="$__zshspy_now_s"
    fi
  }

  __zshspy_json_escape() {
    emulate -L zsh
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\001'/\\u0001}"
    s="${s//$'\002'/\\u0002}"
    s="${s//$'\003'/\\u0003}"
    s="${s//$'\004'/\\u0004}"
    s="${s//$'\005'/\\u0005}"
    s="${s//$'\006'/\\u0006}"
    s="${s//$'\007'/\\u0007}"
    s="${s//$'\010'/\\b}"
    s="${s//$'\011'/\\t}"
    s="${s//$'\012'/\\n}"
    s="${s//$'\013'/\\u000b}"
    s="${s//$'\014'/\\f}"
    s="${s//$'\015'/\\r}"
    s="${s//$'\016'/\\u000e}"
    s="${s//$'\017'/\\u000f}"
    s="${s//$'\020'/\\u0010}"
    s="${s//$'\021'/\\u0011}"
    s="${s//$'\022'/\\u0012}"
    s="${s//$'\023'/\\u0013}"
    s="${s//$'\024'/\\u0014}"
    s="${s//$'\025'/\\u0015}"
    s="${s//$'\026'/\\u0016}"
    s="${s//$'\027'/\\u0017}"
    s="${s//$'\030'/\\u0018}"
    s="${s//$'\031'/\\u0019}"
    s="${s//$'\032'/\\u001a}"
    s="${s//$'\033'/\\u001b}"
    s="${s//$'\034'/\\u001c}"
    s="${s//$'\035'/\\u001d}"
    s="${s//$'\036'/\\u001e}"
    s="${s//$'\037'/\\u001f}"
    REPLY="$s"
  }

  __zshspy_json_string() {
    emulate -L zsh
    __zshspy_json_escape "$1"
    REPLY="\"$REPLY\""
  }

  # Close the archive descriptor exactly once.
  # No arguments.  Returns 0 even when no descriptor is open.
  __zshspy_close_fd() {
    emulate -L zsh
    if (( __zshspy_fd >= 0 )); then
      exec {__zshspy_fd}>&- 2>/dev/null || true
      __zshspy_fd=-1
    fi
    return 0
  }

  # Open a brand-new archive path without following or appending to an
  # existing entry.  Session names are designed to be unique; a collision is
  # therefore safer to reject than to merge two lifecycles or follow a
  # pre-created symlink.  The shell-redirection fallback cannot set close-on-
  # exec, but NO_CLOBBER still gives it exclusive-create semantics.
  #   $1: archive path to create.
  # Returns 0 with __zshspy_fd open, 1 on failure.
  __zshspy_open_file() {
    emulate -L zsh
    local file="$1"
    __zshspy_fd=-1
    if (( ${+builtins} && ${+builtins[sysopen]} )); then
      sysopen -w -m 0600 -o create,cloexec,excl -u __zshspy_fd "$file" 2>/dev/null || {
        __zshspy_fd=-1
        return 1
      }
    else
      unsetopt CLOBBER
      unsetopt CLOBBER_EMPTY 2>/dev/null || true
      exec {__zshspy_fd}>"$file" 2>/dev/null || {
        __zshspy_fd=-1
        return 1
      }
    fi
    return 0
  }

  # Append one record line to the archive fd.
  #   $1: complete JSONL record, without the trailing newline.
  # Returns 0 on success; on failure disables the archive and returns 1.
  # Exactly one writer is used per shell.  syswrite already retries partial
  # writes and EINTR internally (bin_syswrite, Src/Modules/system.c:261-275),
  # so a syswrite *failure* (ENOSPC, EIO) can leave a partial prefix on
  # disk; retrying the whole line with print would append the full record
  # after that prefix, corrupting the file with a garbled line plus a
  # duplicate.  Note the print fallback path (no zsh/system) leaves the fd
  # without close-on-exec, so children inherit it.
  __zshspy_raw_write() {
    emulate -L zsh
    local line="$1"
    (( __zshspy_enabled && __zshspy_fd >= 0 )) || return 1
    if (( __zshspy_have_syswrite )); then
      syswrite -o "$__zshspy_fd" "${line}"$'\n' 2>/dev/null && return 0
    else
      builtin print -r -u "$__zshspy_fd" -- "$line" 2>/dev/null && return 0
    fi
    __zshspy_enabled=0
    __zshspy_close_fd
    return 1
  }

  # Drain every currently queued record in FIFO order.  Remove one element at
  # a time instead of copying and then clearing the whole array: a CHLD trap may
  # append between any two shell statements, and a whole-array clear could erase
  # the newly appended record.
  # No arguments.  Returns 0; write errors disable the archive in raw_write.
  __zshspy_drain_queue() {
    emulate -L zsh
    local queued
    while (( ${#__zshspy_queue[@]} )); do
      queued="${__zshspy_queue[1]}"
      shift __zshspy_queue
      __zshspy_raw_write "$queued" || true
    done
    return 0
  }

  # Serialize one record to the archive, preserving lines from reentrant
  # callers.  Hooks and the CHLD trap can interrupt each other between any
  # two shell statements, so a busy flag plus a queue is used: reentrant
  # calls enqueue, the flag owner drains.  After clearing the flag the queue
  # is checked once more -- a trap firing between the end of the drain loop
  # and the flag store would otherwise strand its record in the queue until
  # some later write happened to flush it (possibly not until session_end).
  # Records may still land out of order relative to wall-clock time when a
  # trap interleaves; consumers should order by epoch_s/epoch_ns.
  #   $1: complete JSONL record, without the trailing newline.
  # Always returns 0; write errors disable the archive in raw_write.
  __zshspy_write() {
    emulate -L zsh
    (( __zshspy_enabled && ${ZSH_SUBSHELL:-0} == 0 )) || return 0
    local line="$1"

    if (( __zshspy_writing )); then
      __zshspy_queue+=( "$line" )
      return 0
    fi

    __zshspy_writing=1
    __zshspy_raw_write "$line" || true
    while true; do
      __zshspy_drain_queue
      __zshspy_writing=0
      (( ${#__zshspy_queue[@]} )) || break
      __zshspy_writing=1
    done
    return 0
  }

  __zshspy_duration_json_fields() {
    emulate -L zsh
    local start_s="$1" start_ns="$2" end_s="$3" end_ns="$4"
    local d_s d_ns
    if [[ -z $start_s || -z $start_ns || -z $end_s || -z $end_ns ]]; then
      REPLY='"duration_s":null,"duration_ns":null'
      return 0
    fi
    (( d_s = end_s - start_s ))
    (( d_ns = end_ns - start_ns ))
    if (( d_ns < 0 )); then
      (( d_s-- ))
      (( d_ns += 1000000000 ))
    fi
    if (( d_s < 0 )); then
      REPLY='"duration_s":null,"duration_ns":null'
    else
      REPLY="\"duration_s\":$d_s,\"duration_ns\":$d_ns"
    fi
  }

  typeset -gA __zshspy_sigmsg_num=()

  # Build the reverse map from zsh's signal-death messages to signal
  # numbers, resolved against this platform via the $signals special array
  # (signals[i] names signal number i-1: signals[1]=EXIT, signals[2]=HUP).
  # The message strings are the sig_msg[] table zsh compiles from
  # Src/signames2.awk; signals absent from that table print as SIG<NAME>
  # and are resolved separately in __zshspy_status_from_proc_state.
  # No arguments.  Fills __zshspy_sigmsg_num once per shell; entries
  # map message text -> signal number.
  __zshspy_init_sigmsg_map() {
    emulate -L zsh
    (( ${#__zshspy_sigmsg_num} == 0 )) || return 0
    local -A name_msg
    name_msg=(
      ABRT   'abort'
      ALRM   'alarm'
      BUS    'bus error'
      CHLD   'death of child'
      EMT    'EMT instruction'
      FPE    'floating point exception'
      FREEZE 'checkpoint freeze'
      HUP    'hangup'
      ILL    'illegal hardware instruction'
      INFO   'status request from keyboard'
      INT    'interrupt'
      IO     'i/o ready'
      IOT    'IOT instruction'
      KILL   'killed'
      LOST   'resource lost'
      PIPE   'broken pipe'
      POLL   'pollable event occurred'
      PROF   'profile signal'
      PWR    'power fail'
      QUIT   'quit'
      SEGV   'segmentation fault'
      SYS    'invalid system call'
      TERM   'terminated'
      THAW   'checkpoint thaw'
      TRAP   'trace trap'
      URG    'urgent condition'
      USR1   'user-defined signal 1'
      USR2   'user-defined signal 2'
      VTALRM 'virtual time alarm'
      WINCH  'window size changed'
      XCPU   'cpu limit exceeded'
      XFSZ   'file size limit exceeded'
      XRES   'resource control exceeded'
    )
    local name idx
    for name in "${(@k)name_msg}"; do
      idx=${signals[(i)$name]}
      if (( idx <= ${#signals} )); then
        __zshspy_sigmsg_num[${name_msg[$name]}]=$(( idx - 1 ))
      fi
    done
  }

  # Parse one process state from a $jobstates pid=state segment.
  #   $1: the state text, e.g. "done", "exit 2", "running", "terminated",
  #       "segmentation fault (core dumped)".
  # Sets REPLY to the JSON value for the status field (number or null) and
  # REPLY2 to the status kind:
  #   exit      normal exit; REPLY is the exit code 0..255.  zsh master
  #             prints WEXITSTATUS here (pmjobstate,
  #             Src/Modules/parameter.c:1377); zsh <= 5.9 prints the raw
  #             wait status, code<<8.  Both encodings are normalized to
  #             the plain code.
  #   signaled  killed by a signal; REPLY is 128+signum in the shell's own
  #             $? convention, or null when the signal cannot be identified
  #             (real-time signals: SIGRTMIN is not knowable from zsh).
  #   unknown   anything else (running/suspended states, parse failures).
  __zshspy_status_from_proc_state() {
    emulate -L zsh
    local state="$1"
    local raw base idx
    REPLY=null
    REPLY2=unknown
    if [[ $state == done ]]; then
      REPLY=0
      REPLY2=exit
      return 0
    fi
    if [[ $state == exit\ * ]]; then
      raw="${state#exit }"
      if [[ -n $raw && $raw != *[!0-9]* ]]; then
        # zsh <= 5.9 prints the raw wait status here (empirically on 5.9:
        # an exit code of 3 shows as "exit 768"); master fixed pmjobstate
        # to print WEXITSTATUS (Src/Modules/parameter.c:1377-1380,
        # zsh-workers/54560).  The encodings cannot collide: WEXITSTATUS
        # output is 1..255, while a raw wait status for a normal exit is
        # code<<8, always a positive multiple of 256.
        if (( raw > 255 && raw % 256 == 0 )); then
          REPLY=$(( raw / 256 ))
        else
          REPLY=$raw
        fi
        REPLY2=exit
      fi
      return 0
    fi
    if [[ $state == running || $state == suspended* || $state == stopped* ]]; then
      return 0
    fi
    # Everything else pmjobstate can print is sigmsg() output for a signal
    # death (Src/Modules/parameter.c:1383-1389), optionally suffixed.
    base="${state%" (core dumped)"}"
    __zshspy_init_sigmsg_map
    if [[ -n ${__zshspy_sigmsg_num[$base]-} ]]; then
      REPLY=$(( 128 + __zshspy_sigmsg_num[$base] ))
      REPLY2=signaled
    elif [[ $base == SIG[A-Z0-9]* ]]; then
      # Signals without a message entry print as SIG<NAME>
      # (Src/signames2.awk END block).
      idx=${signals[(i)${base#SIG}]}
      if (( idx <= ${#signals} )); then
        REPLY=$(( 128 + idx - 1 ))
      fi
      REPLY2=signaled
    elif [[ $base == real-time\ event\ * || $base == unknown\ signal ]]; then
      # sigmsg() output for SIGRTMIN..SIGRTMAX and out-of-range numbers
      # (Src/jobs.c:1116-1127); no portable number is derivable.
      REPLY2=signaled
    fi
  }

  __zshspy_job_pids_csv() {
    emulate -L zsh
    local js="$1"
    local -a parts pids
    local i seg pid
    parts=( "${(@s.:.)js}" )
    pids=()
    for (( i = 3; i <= ${#parts[@]}; i++ )); do
      seg="${parts[$i]}"
      pid="${seg%%=*}"
      [[ -n $pid ]] && pids+=( "$pid" )
    done
    REPLY="${(j:,:)pids}"
  }

  __zshspy_processes_json() {
    emulate -L zsh
    local js="$1"
    local -a parts items
    local i seg pid state status_json status_kind qstate
    parts=( "${(@s.:.)js}" )
    items=()
    for (( i = 3; i <= ${#parts[@]}; i++ )); do
      seg="${parts[$i]}"
      pid="${seg%%=*}"
      state="${seg#*=}"
      __zshspy_status_from_proc_state "$state"
      status_json="$REPLY"
      status_kind="$REPLY2"
      __zshspy_json_string "$state"
      qstate="$REPLY"
      case "$pid" in
        (""|*[!0-9]*)
          __zshspy_json_string "$pid"
          items+=( "{\"pid\":$REPLY,\"state\":$qstate,\"status\":$status_json,\"status_kind\":\"$status_kind\"}" )
          ;;
        (*)
          items+=( "{\"pid\":$pid,\"state\":$qstate,\"status\":$status_json,\"status_kind\":\"$status_kind\"}" )
          ;;
      esac
    done
    REPLY="[${(j:,:)items}]"
  }

  __zshspy_job_summary_fields() {
    emulate -L zsh
    local job="$1" js="$2"
    local -a parts
    local job_state mark text dir pids qjob_state qmark qtext qdir processes_json
    parts=( "${(@s.:.)js}" )
    job_state="${parts[1]-}"
    mark="${parts[2]-}"
    text="${jobtexts[$job]-}"
    dir="${jobdirs[$job]-}"
    __zshspy_job_pids_csv "$js"; pids="$REPLY"
    __zshspy_processes_json "$js"; processes_json="$REPLY"
    __zshspy_json_string "$job_state"; qjob_state="$REPLY"
    __zshspy_json_string "$mark"; qmark="$REPLY"
    __zshspy_json_string "$text"; qtext="$REPLY"
    __zshspy_json_string "$dir"; qdir="$REPLY"
    REPLY="\"job\":$job,\"job_state\":$qjob_state,\"job_mark\":$qmark,\"job_pids\":\"$pids\",\"job_text\":$qtext,\"job_dir\":$qdir,\"processes\":$processes_json"
  }

  __zshspy_log_session_start() {
    emulate -L zsh
    local REPLY REPLY2
    local __zshspy_now_s __zshspy_now_ns __zshspy_now_ts
    __zshspy_now
    local qsession qts qhost quser qfile qzver
    __zshspy_json_string "$__zshspy_session_id"; qsession="$REPLY"
    __zshspy_json_string "$__zshspy_now_ts"; qts="$REPLY"
    __zshspy_json_string "$__zshspy_host"; qhost="$REPLY"
    __zshspy_json_string "$__zshspy_user"; quser="$REPLY"
    __zshspy_json_string "$__zshspy_file"; qfile="$REPLY"
    __zshspy_json_string "${ZSH_VERSION:-}"; qzver="$REPLY"
    local bg_json notify_json
    (( __zshspy_bg_enabled )) && bg_json=true || bg_json=false
    (( __zshspy_notify_was_on )) && notify_json=true || notify_json=false
    __zshspy_write "{\"type\":\"session_start\",\"schema\":1,\"session_id\":$qsession,\"ts\":$qts,\"epoch_s\":$__zshspy_now_s,\"epoch_ns\":$__zshspy_now_ns,\"host\":$qhost,\"user\":$quser,\"shell_pid\":$__zshspy_shell_pid,\"zsh_version\":$qzver,\"file\":$qfile,\"background_tracking\":$bg_json,\"notify_was_on\":$notify_json}"
  }

  __zshspy_log_command_start() {
    emulate -L zsh
    local id="$1" typed="$2" expanded="$3" short="$4"
    local qid qsession qts qhost quser qcwd qtty qtyped qexpanded qshort
    __zshspy_json_string "$id"; qid="$REPLY"
    __zshspy_json_string "$__zshspy_session_id"; qsession="$REPLY"
    __zshspy_json_string "$__zshspy_now_ts"; qts="$REPLY"
    __zshspy_json_string "$__zshspy_host"; qhost="$REPLY"
    __zshspy_json_string "$__zshspy_user"; quser="$REPLY"
    __zshspy_json_string "$PWD"; qcwd="$REPLY"
    __zshspy_json_string "${TTY:-}"; qtty="$REPLY"
    __zshspy_json_string "$typed"; qtyped="$REPLY"
    __zshspy_json_string "$expanded"; qexpanded="$REPLY"
    __zshspy_json_string "$short"; qshort="$REPLY"
    __zshspy_write "{\"type\":\"command_start\",\"schema\":1,\"id\":$qid,\"session_id\":$qsession,\"seq\":$__zshspy_seq,\"ts\":$qts,\"epoch_s\":$__zshspy_now_s,\"epoch_ns\":$__zshspy_now_ns,\"host\":$qhost,\"user\":$quser,\"cwd\":$qcwd,\"tty\":$qtty,\"shell_pid\":$__zshspy_shell_pid,\"histcmd\":${HISTCMD:-0},\"command\":$qtyped,\"command_expanded\":$qexpanded,\"command_short\":$qshort}"
  }

  __zshspy_log_command_end() {
    emulate -L zsh
    local id="$1" _status="$2" async_jobs_json="$3" reason="${4:-precmd}"
    local __zshspy_now_s __zshspy_now_ns __zshspy_now_ts
    __zshspy_now
    local qid qsession qts qcwd qreason duration_fields
    __zshspy_json_string "$id"; qid="$REPLY"
    __zshspy_json_string "$__zshspy_session_id"; qsession="$REPLY"
    __zshspy_json_string "$__zshspy_now_ts"; qts="$REPLY"
    __zshspy_json_string "$PWD"; qcwd="$REPLY"
    __zshspy_json_string "$reason"; qreason="$REPLY"
    __zshspy_duration_json_fields "${__zshspy_cmd_start_s[$id]-}" "${__zshspy_cmd_start_ns[$id]-}" "$__zshspy_now_s" "$__zshspy_now_ns"
    duration_fields="$REPLY"
    [[ -z $async_jobs_json ]] && async_jobs_json="[]"
    __zshspy_write "{\"type\":\"command_end\",\"schema\":1,\"id\":$qid,\"session_id\":$qsession,\"ts\":$qts,\"epoch_s\":$__zshspy_now_s,\"epoch_ns\":$__zshspy_now_ns,\"status\":$_status,\"cwd\":$qcwd,\"async_jobs\":$async_jobs_json,\"reason\":$qreason,$duration_fields}"
    unset "__zshspy_cmd_start_s[$id]" "__zshspy_cmd_start_ns[$id]"
  }

  __zshspy_log_async_start() {
    emulate -L zsh
    local id="$1" job="$2" js="$3"
    local __zshspy_now_s __zshspy_now_ns __zshspy_now_ts
    __zshspy_now
    local qid qsession qts job_fields
    __zshspy_json_string "$id"; qid="$REPLY"
    __zshspy_json_string "$__zshspy_session_id"; qsession="$REPLY"
    __zshspy_json_string "$__zshspy_now_ts"; qts="$REPLY"
    __zshspy_job_summary_fields "$job" "$js"; job_fields="$REPLY"
    __zshspy_write "{\"type\":\"async_start\",\"schema\":1,\"id\":$qid,\"session_id\":$qsession,\"ts\":$qts,\"epoch_s\":$__zshspy_now_s,\"epoch_ns\":$__zshspy_now_ns,$job_fields}"
  }

  __zshspy_log_async_end() {
    emulate -L zsh
    local id="$1" job="$2" js="$3"
    local __zshspy_now_s __zshspy_now_ns __zshspy_now_ts
    __zshspy_now
    local qid qsession qts job_fields duration_fields last_state status_json status_kind
    local -a parts
    parts=( "${(@s.:.)js}" )
    if (( ${#parts[@]} >= 3 )); then
      last_state="${parts[-1]#*=}"
    else
      last_state=""
    fi
    __zshspy_status_from_proc_state "$last_state"
    status_json="$REPLY"
    status_kind="$REPLY2"
    __zshspy_json_string "$id"; qid="$REPLY"
    __zshspy_json_string "$__zshspy_session_id"; qsession="$REPLY"
    __zshspy_json_string "$__zshspy_now_ts"; qts="$REPLY"
    __zshspy_job_summary_fields "$job" "$js"; job_fields="$REPLY"
    __zshspy_duration_json_fields "${__zshspy_job_start_s[$job]-}" "${__zshspy_job_start_ns[$job]-}" "$__zshspy_now_s" "$__zshspy_now_ns"
    duration_fields="$REPLY"
    __zshspy_write "{\"type\":\"async_end\",\"schema\":1,\"id\":$qid,\"session_id\":$qsession,\"ts\":$qts,\"epoch_s\":$__zshspy_now_s,\"epoch_ns\":$__zshspy_now_ns,\"status\":$status_json,\"status_kind\":\"$status_kind\",$job_fields,$duration_fields}"
  }

  __zshspy_log_async_lost() {
    emulate -L zsh
    local id="$1" job="$2" reason="$3"
    local __zshspy_now_s __zshspy_now_ns __zshspy_now_ts
    __zshspy_now
    local qid qsession qts qreason duration_fields
    __zshspy_json_string "$id"; qid="$REPLY"
    __zshspy_json_string "$__zshspy_session_id"; qsession="$REPLY"
    __zshspy_json_string "$__zshspy_now_ts"; qts="$REPLY"
    __zshspy_json_string "$reason"; qreason="$REPLY"
    __zshspy_duration_json_fields "${__zshspy_job_start_s[$job]-}" "${__zshspy_job_start_ns[$job]-}" "$__zshspy_now_s" "$__zshspy_now_ns"
    duration_fields="$REPLY"
    __zshspy_write "{\"type\":\"async_lost\",\"schema\":1,\"id\":$qid,\"session_id\":$qsession,\"ts\":$qts,\"epoch_s\":$__zshspy_now_s,\"epoch_ns\":$__zshspy_now_ns,\"job\":$job,\"reason\":$qreason,$duration_fields}"
  }

  # Emit async_end / async_lost records for tracked background jobs, and
  # adopt completed jobs that precmd can never see.  A job spawned by the
  # in-flight command line that also finishes before that line does is
  # reported and deleted by zsh *before* any precmd hook runs: with NOTIFY
  # unset, preprompt() calls scanjobs() first and precmd hooks after
  # (Src/utils.c:1567-1576), and scanjobs -> printjob deletes done jobs
  # (Src/jobs.c:2000-2006, 1362-1373).  The CHLD trap is therefore the only
  # place such a job is still visible in $jobstates; adopt it here:
  # attribute it to $__zshspy_cur_id, emit async_start, and let the
  # regular loop below emit its async_end.  Adopted jobs are recorded in
  # __zshspy_job_logged_done (job -> pid csv, so slot reuse is
  # detected) to keep precmd from logging them a second time, and in
  # __zshspy_cur_adopted so command_end can list them.
  # No arguments; preserves $? for the surrounding hook/trap machinery.
  __zshspy_process_done_jobs() {
    local _save_status=$?
    emulate -L zsh
    local REPLY REPLY2
    (( __zshspy_enabled && __zshspy_bg_enabled && ${ZSH_SUBSHELL:-0} == 0 )) || return $_save_status

    local job id js job_state cur_pids
    for job in "${(@k)__zshspy_job_logged_done}"; do
      if (( ! ${+jobstates[$job]} )); then
        unset "__zshspy_job_logged_done[$job]"
      else
        __zshspy_job_pids_csv "${jobstates[$job]}"
        if [[ $REPLY != "${__zshspy_job_logged_done[$job]}" ]]; then
          unset "__zshspy_job_logged_done[$job]"
        fi
      fi
    done

    if [[ -n $__zshspy_cur_id ]]; then
      for job in "${(@k)jobstates}"; do
        (( ${+__zshspy_job_cmd_id[$job]} )) && continue
        js="${jobstates[$job]}"
        [[ ${js%%:*} == done ]] || continue
        __zshspy_job_pids_csv "$js"
        cur_pids="$REPLY"
        if [[ -n ${__zshspy_jobs_before_pids[$job]+x} && $cur_pids == "${__zshspy_jobs_before_pids[$job]}" ]]; then
          continue
        fi
        if [[ -n ${__zshspy_job_logged_done[$job]-} && ${__zshspy_job_logged_done[$job]} == "$cur_pids" ]]; then
          continue
        fi
        # A done job reached from here is a background job: zsh deletes the
        # foreground job before running traps queued during the wait
        # (waitjob: deletejob precedes unqueue_traps, Src/jobs.c:1746-1751),
        # and dotrap(SIGCHLD) is skipped for job == thisjob
        # (Src/jobs.c:651-652).
        __zshspy_job_cmd_id[$job]="$__zshspy_cur_id"
        __zshspy_job_start_s[$job]="${__zshspy_cmd_start_s[$__zshspy_cur_id]-}"
        __zshspy_job_start_ns[$job]="${__zshspy_cmd_start_ns[$__zshspy_cur_id]-}"
        __zshspy_log_async_start "$__zshspy_cur_id" "$job" "$js"
        __zshspy_job_logged_done[$job]="$cur_pids"
        __zshspy_cur_adopted+=( "$job" )
      done
    fi

    for job in "${(@k)__zshspy_job_cmd_id}"; do
      id="${__zshspy_job_cmd_id[$job]}"
      if (( ! ${+jobstates[$job]} )); then
        __zshspy_log_async_lost "$id" "$job" "missing_from_job_table"
        unset "__zshspy_job_cmd_id[$job]" "__zshspy_job_start_s[$job]" "__zshspy_job_start_ns[$job]"
        continue
      fi

      js="${jobstates[$job]}"
      job_state="${js%%:*}"
      if [[ $job_state == done ]]; then
        __zshspy_log_async_end "$id" "$job" "$js"
        unset "__zshspy_job_cmd_id[$job]" "__zshspy_job_start_s[$job]" "__zshspy_job_start_ns[$job]"
      fi
    done
    return $_save_status
  }

  __zshspy_preexec() {
    local _save_status=$?
    emulate -L zsh
    local REPLY REPLY2
    (( __zshspy_enabled && ${ZSH_SUBSHELL:-0} == 0 )) || return $_save_status

    __zshspy_process_done_jobs
    __zshspy_now

    (( __zshspy_seq++ ))
    local id="${__zshspy_session_id}.${__zshspy_seq}"
    local typed="$1" short="$2" expanded="$3"
    [[ -z $typed ]] && typed="$expanded"

    __zshspy_cur_id="$id"
    __zshspy_cmd_start_s[$id]="$__zshspy_now_s"
    __zshspy_cmd_start_ns[$id]="$__zshspy_now_ns"

    __zshspy_jobs_before_pids=()
    __zshspy_cur_adopted=()
    if (( __zshspy_bg_enabled )); then
      local j
      for j in "${(@k)jobstates}"; do
        __zshspy_job_pids_csv "${jobstates[$j]}"
        __zshspy_jobs_before_pids[$j]="$REPLY"
      done
    fi

    __zshspy_log_command_start "$id" "$typed" "$expanded" "$short"
    return $_save_status
  }

  __zshspy_precmd() {
    local last_status=$?
    emulate -L zsh
    local REPLY REPLY2
    (( __zshspy_enabled && ${ZSH_SUBSHELL:-0} == 0 )) || return $last_status

    local id="$__zshspy_cur_id"
    local -a new_jobs async_jobs
    local j current_pids before_pids js async_jobs_json

    new_jobs=()
    async_jobs=()

    if [[ -n $id ]]; then
      if (( __zshspy_bg_enabled )); then
        for j in "${(@k)jobstates}"; do
          __zshspy_job_pids_csv "${jobstates[$j]}"
          current_pids="$REPLY"
          before_pids="${__zshspy_jobs_before_pids[$j]-}"
          # Jobs adopted (and fully logged) by the CHLD trap for this
          # command are recognized by job number + pid csv; do not log
          # async_start for them a second time.
          if [[ -n ${__zshspy_job_logged_done[$j]-} && ${__zshspy_job_logged_done[$j]} == "$current_pids" ]]; then
            continue
          fi
          if [[ -z ${__zshspy_jobs_before_pids[$j]+x} || $current_pids != $before_pids ]]; then
            new_jobs+=( "$j" )
          fi
        done
      fi

      local -a items
      items=( "${__zshspy_cur_adopted[@]}" )
      if (( ${#new_jobs[@]} )); then
        for j in "${new_jobs[@]}"; do
          js="${jobstates[$j]}"
          __zshspy_job_cmd_id[$j]="$id"
          __zshspy_job_start_s[$j]="${__zshspy_cmd_start_s[$id]-}"
          __zshspy_job_start_ns[$j]="${__zshspy_cmd_start_ns[$id]-}"
          __zshspy_log_async_start "$id" "$j" "$js"
          case "$j" in
            (""|*[!0-9]*)
              __zshspy_json_string "$j"
              items+=( "$REPLY" )
              ;;
            (*)
              items+=( "$j" )
              ;;
          esac
        done
      fi
      async_jobs_json="[${(j:,:)items}]"

      __zshspy_cur_id=""
      __zshspy_log_command_end "$id" "$last_status" "$async_jobs_json" "precmd"
      __zshspy_cur_adopted=()
    fi

    __zshspy_process_done_jobs
    return $last_status
  }

  __zshspy_zshexit() {
    local exit_status=$?
    emulate -L zsh
    local REPLY REPLY2
    (( __zshspy_enabled && ${ZSH_SUBSHELL:-0} == 0 )) || return $exit_status

    if [[ -n $__zshspy_cur_id ]]; then
      __zshspy_log_command_end "$__zshspy_cur_id" "$exit_status" "[${(j:,:)__zshspy_cur_adopted}]" "zshexit"
      __zshspy_cur_id=""
    fi

    __zshspy_process_done_jobs

    __zshspy_now
    local qsession qts
    __zshspy_json_string "$__zshspy_session_id"; qsession="$REPLY"
    __zshspy_json_string "$__zshspy_now_ts"; qts="$REPLY"
    __zshspy_write "{\"type\":\"session_end\",\"schema\":1,\"session_id\":$qsession,\"ts\":$qts,\"epoch_s\":$__zshspy_now_s,\"epoch_ns\":$__zshspy_now_ns,\"status\":$exit_status}"

    if (( __zshspy_fd >= 0 )); then
      exec {__zshspy_fd}>&- 2>/dev/null || true
      __zshspy_fd=-1
    fi
    return $exit_status
  }

  __zshspy_trap_chld() {
    local _save_status=$?
    emulate -L zsh
    (( ${ZSH_SUBSHELL:-0} == 0 )) && __zshspy_process_done_jobs
    if (( ${+functions[__zshspy_user_TRAPCHLD]} )); then
      __zshspy_user_TRAPCHLD "$@" || true
    fi
    return $_save_status
  }

  # Report whether a list-form CHLD trap (set with `trap '...' CHLD`) exists
  # in the current shell.  zsh's trap builtin has no -p option (bin_trap,
  # Src/builtin.c), and $(trap) cannot work either: command substitution
  # enters a subshell without ESUB_KEEPTRAP, which resets every trap that is
  # not function-form or ZERR/DEBUG (entersubsh, Src/exec.c; "ZERR and DEBUG
  # traps are kept within subshells, while other traps are reset",
  # Doc/Zsh/builtins.yo).  Redirecting a builtin does not fork, so list the
  # traps into a private temp file instead and scan that.
  #   $1: directory for the temp file; must already exist with mode 0700
  #       (the archive dir qualifies), since trap bodies may be sensitive.
  # Returns 0 iff a list-form CHLD trap is present, 1 otherwise or on error
  # (callers treat errors as "no conflict", matching the old behavior).
  __zshspy_has_list_chld_trap() {
    emulate -L zsh
    local dir="$1"
    local tmpf="${dir}/.traps.$$.${RANDOM}${RANDOM}" line found=0
    [[ -d $dir ]] || return 1
    { builtin trap >| "$tmpf" } 2>/dev/null || {
      command rm -f -- "$tmpf" 2>/dev/null
      return 1
    }
    # The listing prints one line per signal: `trap -- '<body>' CHLD`.
    # Function-form traps print as function definitions and never match.
    # Anchoring on both the prefix and the suffix keeps a multi-line trap
    # body from faking a hit.
    while IFS= read -r line; do
      if [[ $line == trap\ --\ *\ CHLD ]]; then
        found=1
        break
      fi
    done < "$tmpf"
    command rm -f -- "$tmpf" 2>/dev/null
    (( found ))
  }

  # Compute session id and open the per-session file.  The archive requires
  # zsh/datetime; normal zsh history timestamping above still works without it.
  if (( __zshspy_have_datetime )); then
    __zshspy_now
    typeset __zshspy_safe_host="${__zshspy_host//[^A-Za-z0-9_.-]/_}"
    typeset __zshspy_safe_user="${__zshspy_user//[^A-Za-z0-9_.-]/_}"
    __zshspy_session_id="${__zshspy_safe_host}.${__zshspy_safe_user}.${__zshspy_now_s}.${__zshspy_now_ns}.${__zshspy_shell_pid}.${RANDOM}${RANDOM}"
    __zshspy_dir="${ZSH_SPY_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/zsh-spy}"
    __zshspy_file="${__zshspy_dir}/hist.${__zshspy_session_id}.jsonl"

    typeset __zshspy_old_umask
    __zshspy_old_umask="$(umask)"
    umask 077
    [[ -d $__zshspy_dir ]] || command mkdir -p -- "$__zshspy_dir" 2>/dev/null || true

    if [[ -d $__zshspy_dir ]]; then
      __zshspy_open_file "$__zshspy_file" || __zshspy_fd=-1
    fi
    umask "$__zshspy_old_umask"

    if (( __zshspy_fd >= 0 )); then
      __zshspy_enabled=1
    fi
  fi

  # Enable background tracking only if we have zsh job parameters and no
  # unchainable pre-existing list-form CHLD trap.
  if (( __zshspy_enabled && __zshspy_have_jobparams )) && [[ -o monitor ]]; then
    if (( ${+functions[TRAPCHLD]} )) && [[ ${functions[TRAPCHLD]} != *__zshspy_trap_chld* ]]; then
      functions -c TRAPCHLD __zshspy_user_TRAPCHLD 2>/dev/null && __zshspy_chained_user_chld=1
    elif (( ! ${+functions[TRAPCHLD]} )) && __zshspy_has_list_chld_trap "$__zshspy_dir"; then
      __zshspy_chld_conflict=1
    fi

    if (( ! __zshspy_chld_conflict )); then
      __zshspy_bg_enabled=1
      unsetopt NOTIFY
      TRAPCHLD() { __zshspy_trap_chld "$@"; }
    fi
  fi

  if (( __zshspy_enabled )); then
    add-zsh-hook preexec __zshspy_preexec
    add-zsh-hook precmd  __zshspy_precmd
    add-zsh-hook zshexit __zshspy_zshexit
    __zshspy_log_session_start
  fi
fi
