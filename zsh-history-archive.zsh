# This is slop authored by ChatGPT 5.5 Pro on 2026-05-03, using some earlier
# inputs from ChatGPT 5.2 Thinking.

# zsh JSONL history archive
# Install: source this near the end of ~/.zshrc.
#
# Records go to one unique JSONL file per interactive zsh session:
#   ${ZSH_HISTORY_ARCHIVE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/zsh-history-archive}/hist.<session>.jsonl
#
# Record types:
#   session_start
#   command_start       before zsh executes the entered command line
#   command_end         after zsh returns from evaluating the entered command line
#   async_start         after zsh has registered a newly-created background job
#   async_end           when a tracked background job reaches zsh job-state "done"
#   async_lost          if a tracked background job disappears from zsh's job table
#   session_end
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

if [[ -o interactive && ${ZSH_SUBSHELL:-0} == 0 ]]; then
  setopt EXTENDED_HISTORY

  autoload -Uz add-zsh-hook 2>/dev/null || true

  # Remove old hooks if this file is re-sourced.
  add-zsh-hook -d preexec __zhistarchive_preexec 2>/dev/null || true
  add-zsh-hook -d precmd  __zhistarchive_precmd  2>/dev/null || true
  add-zsh-hook -d zshexit __zhistarchive_zshexit 2>/dev/null || true

  # Close old fd if this file is re-sourced.
  if (( ${+__zhistarchive_fd} && __zhistarchive_fd >= 0 )); then
    exec {__zhistarchive_fd}>&- 2>/dev/null || true
  fi

  zmodload zsh/datetime  2>/dev/null || true
  zmodload zsh/system    2>/dev/null || true
  zmodload zsh/parameter 2>/dev/null || true

  typeset -gi __zhistarchive_enabled=0
  typeset -gi __zhistarchive_have_syswrite=0
  typeset -gi __zhistarchive_have_datetime=0
  typeset -gi __zhistarchive_have_jobparams=0
  typeset -gi __zhistarchive_bg_enabled=0
  typeset -gi __zhistarchive_chld_conflict=0
  typeset -gi __zhistarchive_chained_user_chld=0
  typeset -gi __zhistarchive_notify_was_on=0
  typeset -gi __zhistarchive_fd=-1
  typeset -gi __zhistarchive_seq=0
  typeset -gi __zhistarchive_writing=0

  (( ${+builtins} && ${+builtins[syswrite]} )) && __zhistarchive_have_syswrite=1
  (( ${+epochtime} && ${+builtins} && ${+builtins[strftime]} )) && __zhistarchive_have_datetime=1
  (( ${+jobstates} && ${+jobtexts} && ${+jobdirs} )) && __zhistarchive_have_jobparams=1

  typeset -g  __zhistarchive_session_id=""
  typeset -g  __zhistarchive_file=""
  typeset -g  __zhistarchive_dir=""
  typeset -g  __zhistarchive_cur_id=""
  typeset -g  __zhistarchive_host="${HOST:-${HOSTNAME:-unknown-host}}"
  typeset -g  __zhistarchive_user="${USER:-${USERNAME:-unknown-user}}"
  typeset -g  __zhistarchive_shell_pid="$$"
  typeset -g  __zhistarchive_now_s=0
  typeset -g  __zhistarchive_now_ns=0
  typeset -g  __zhistarchive_now_ts=""
  typeset -ga __zhistarchive_queue=()
  typeset -gA __zhistarchive_cmd_start_s=()
  typeset -gA __zhistarchive_cmd_start_ns=()
  typeset -gA __zhistarchive_job_cmd_id=()
  typeset -gA __zhistarchive_job_start_s=()
  typeset -gA __zhistarchive_job_start_ns=()
  typeset -gA __zhistarchive_jobs_before_pids=()

  if (( ${+sysparams} )) && [[ -n ${sysparams[pid]-} ]]; then
    __zhistarchive_shell_pid="${sysparams[pid]}"
  fi

  __zhistarchive_now() {
    emulate -L zsh
    if (( ${+epochtime} )); then
      local -a _t
      _t=( "${epochtime[@]}" )
      typeset -g __zhistarchive_now_s="${_t[1]}"
      typeset -g __zhistarchive_now_ns="${_t[2]}"
    else
      typeset -g __zhistarchive_now_s=0
      typeset -g __zhistarchive_now_ns=0
      typeset -g __zhistarchive_now_ts=""
      return 1
    fi
    if (( ${+builtins} && ${+builtins[strftime]} )); then
      strftime -s __zhistarchive_now_ts '%Y-%m-%dT%H:%M:%S%z' "$__zhistarchive_now_s" "$__zhistarchive_now_ns" 2>/dev/null || \
        typeset -g __zhistarchive_now_ts="$__zhistarchive_now_s"
    else
      typeset -g __zhistarchive_now_ts="$__zhistarchive_now_s"
    fi
  }

  __zhistarchive_json_escape() {
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

  __zhistarchive_json_string() {
    emulate -L zsh
    __zhistarchive_json_escape "$1"
    REPLY="\"$REPLY\""
  }

  __zhistarchive_raw_write() {
    emulate -L zsh
    local line="$1"
    (( __zhistarchive_enabled && __zhistarchive_fd >= 0 )) || return 1
    if (( __zhistarchive_have_syswrite )); then
      syswrite -o "$__zhistarchive_fd" "${line}"$'\n' 2>/dev/null && return 0
    fi
    builtin print -r -u "$__zhistarchive_fd" -- "$line" 2>/dev/null && return 0
    __zhistarchive_enabled=0
    return 1
  }

  __zhistarchive_write() {
    emulate -L zsh
    (( __zhistarchive_enabled && ${ZSH_SUBSHELL:-0} == 0 )) || return 0
    local line="$1"

    if (( __zhistarchive_writing )); then
      __zhistarchive_queue+=( "$line" )
      return 0
    fi

    __zhistarchive_writing=1
    __zhistarchive_raw_write "$line" || true

    local -a q
    local queued
    while (( ${#__zhistarchive_queue[@]} )); do
      q=( "${__zhistarchive_queue[@]}" )
      __zhistarchive_queue=()
      for queued in "${q[@]}"; do
        __zhistarchive_raw_write "$queued" || true
      done
    done

    __zhistarchive_writing=0
    return 0
  }

  __zhistarchive_duration_json_fields() {
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

  typeset -gA __zhistarchive_sigmsg_num=()

  # Build the reverse map from zsh's signal-death messages to signal
  # numbers, resolved against this platform via the $signals special array
  # (signals[i] names signal number i-1: signals[1]=EXIT, signals[2]=HUP).
  # The message strings are the sig_msg[] table zsh compiles from
  # Src/signames2.awk; signals absent from that table print as SIG<NAME>
  # and are resolved separately in __zhistarchive_status_from_proc_state.
  # No arguments.  Fills __zhistarchive_sigmsg_num once per shell; entries
  # map message text -> signal number.
  __zhistarchive_init_sigmsg_map() {
    emulate -L zsh
    (( ${#__zhistarchive_sigmsg_num} == 0 )) || return 0
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
        __zhistarchive_sigmsg_num[${name_msg[$name]}]=$(( idx - 1 ))
      fi
    done
  }

  # Parse one process state from a $jobstates pid=state segment.
  #   $1: the state text, e.g. "done", "exit 2", "running", "terminated",
  #       "segmentation fault (core dumped)".
  # Sets REPLY to the JSON value for the status field (number or null) and
  # REPLY2 to the status kind:
  #   exit      normal exit; REPLY is the exit code 0..255.  zsh prints
  #             WEXITSTATUS here (pmjobstate, Src/Modules/parameter.c:1377),
  #             never the raw wait status, so no >255 decoding is needed.
  #   signaled  killed by a signal; REPLY is 128+signum in the shell's own
  #             $? convention, or null when the signal cannot be identified
  #             (real-time signals: SIGRTMIN is not knowable from zsh).
  #   unknown   anything else (running/suspended states, parse failures).
  __zhistarchive_status_from_proc_state() {
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
        REPLY=$raw
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
    __zhistarchive_init_sigmsg_map
    if [[ -n ${__zhistarchive_sigmsg_num[$base]-} ]]; then
      REPLY=$(( 128 + __zhistarchive_sigmsg_num[$base] ))
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

  __zhistarchive_job_pids_csv() {
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

  __zhistarchive_processes_json() {
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
      __zhistarchive_status_from_proc_state "$state"
      status_json="$REPLY"
      status_kind="$REPLY2"
      __zhistarchive_json_string "$state"
      qstate="$REPLY"
      case "$pid" in
        (""|*[!0-9]*)
          __zhistarchive_json_string "$pid"
          items+=( "{\"pid\":$REPLY,\"state\":$qstate,\"status\":$status_json,\"status_kind\":\"$status_kind\"}" )
          ;;
        (*)
          items+=( "{\"pid\":$pid,\"state\":$qstate,\"status\":$status_json,\"status_kind\":\"$status_kind\"}" )
          ;;
      esac
    done
    REPLY="[${(j:,:)items}]"
  }

  __zhistarchive_job_summary_fields() {
    emulate -L zsh
    local job="$1" js="$2"
    local -a parts
    local job_state mark text dir pids qjob_state qmark qtext qdir processes_json
    parts=( "${(@s.:.)js}" )
    job_state="${parts[1]-}"
    mark="${parts[2]-}"
    text="${jobtexts[$job]-}"
    dir="${jobdirs[$job]-}"
    __zhistarchive_job_pids_csv "$js"; pids="$REPLY"
    __zhistarchive_processes_json "$js"; processes_json="$REPLY"
    __zhistarchive_json_string "$job_state"; qjob_state="$REPLY"
    __zhistarchive_json_string "$mark"; qmark="$REPLY"
    __zhistarchive_json_string "$text"; qtext="$REPLY"
    __zhistarchive_json_string "$dir"; qdir="$REPLY"
    REPLY="\"job\":$job,\"job_state\":$qjob_state,\"job_mark\":$qmark,\"job_pids\":\"$pids\",\"job_text\":$qtext,\"job_dir\":$qdir,\"processes\":$processes_json"
  }

  __zhistarchive_log_session_start() {
    emulate -L zsh
    __zhistarchive_now
    local qsession qts qhost quser qfile qzver
    __zhistarchive_json_string "$__zhistarchive_session_id"; qsession="$REPLY"
    __zhistarchive_json_string "$__zhistarchive_now_ts"; qts="$REPLY"
    __zhistarchive_json_string "$__zhistarchive_host"; qhost="$REPLY"
    __zhistarchive_json_string "$__zhistarchive_user"; quser="$REPLY"
    __zhistarchive_json_string "$__zhistarchive_file"; qfile="$REPLY"
    __zhistarchive_json_string "${ZSH_VERSION:-}"; qzver="$REPLY"
    local bg_json notify_json
    (( __zhistarchive_bg_enabled )) && bg_json=true || bg_json=false
    (( __zhistarchive_notify_was_on )) && notify_json=true || notify_json=false
    __zhistarchive_write "{\"type\":\"session_start\",\"schema\":1,\"session_id\":$qsession,\"ts\":$qts,\"epoch_s\":$__zhistarchive_now_s,\"epoch_ns\":$__zhistarchive_now_ns,\"host\":$qhost,\"user\":$quser,\"shell_pid\":$__zhistarchive_shell_pid,\"zsh_version\":$qzver,\"file\":$qfile,\"background_tracking\":$bg_json,\"notify_was_on\":$notify_json}"
  }

  __zhistarchive_log_command_start() {
    emulate -L zsh
    local id="$1" typed="$2" expanded="$3" short="$4"
    local qid qsession qts qhost quser qcwd qtty qtyped qexpanded qshort
    __zhistarchive_json_string "$id"; qid="$REPLY"
    __zhistarchive_json_string "$__zhistarchive_session_id"; qsession="$REPLY"
    __zhistarchive_json_string "$__zhistarchive_now_ts"; qts="$REPLY"
    __zhistarchive_json_string "$__zhistarchive_host"; qhost="$REPLY"
    __zhistarchive_json_string "$__zhistarchive_user"; quser="$REPLY"
    __zhistarchive_json_string "$PWD"; qcwd="$REPLY"
    __zhistarchive_json_string "${TTY:-}"; qtty="$REPLY"
    __zhistarchive_json_string "$typed"; qtyped="$REPLY"
    __zhistarchive_json_string "$expanded"; qexpanded="$REPLY"
    __zhistarchive_json_string "$short"; qshort="$REPLY"
    __zhistarchive_write "{\"type\":\"command_start\",\"schema\":1,\"id\":$qid,\"session_id\":$qsession,\"seq\":$__zhistarchive_seq,\"ts\":$qts,\"epoch_s\":$__zhistarchive_now_s,\"epoch_ns\":$__zhistarchive_now_ns,\"host\":$qhost,\"user\":$quser,\"cwd\":$qcwd,\"tty\":$qtty,\"shell_pid\":$__zhistarchive_shell_pid,\"histcmd\":${HISTCMD:-0},\"command\":$qtyped,\"command_expanded\":$qexpanded,\"command_short\":$qshort}"
  }

  __zhistarchive_log_command_end() {
    emulate -L zsh
    local id="$1" _status="$2" async_jobs_json="$3" reason="${4:-precmd}"
    __zhistarchive_now
    local qid qsession qts qcwd qreason duration_fields
    __zhistarchive_json_string "$id"; qid="$REPLY"
    __zhistarchive_json_string "$__zhistarchive_session_id"; qsession="$REPLY"
    __zhistarchive_json_string "$__zhistarchive_now_ts"; qts="$REPLY"
    __zhistarchive_json_string "$PWD"; qcwd="$REPLY"
    __zhistarchive_json_string "$reason"; qreason="$REPLY"
    __zhistarchive_duration_json_fields "${__zhistarchive_cmd_start_s[$id]-}" "${__zhistarchive_cmd_start_ns[$id]-}" "$__zhistarchive_now_s" "$__zhistarchive_now_ns"
    duration_fields="$REPLY"
    [[ -z $async_jobs_json ]] && async_jobs_json="[]"
    __zhistarchive_write "{\"type\":\"command_end\",\"schema\":1,\"id\":$qid,\"session_id\":$qsession,\"ts\":$qts,\"epoch_s\":$__zhistarchive_now_s,\"epoch_ns\":$__zhistarchive_now_ns,\"status\":$_status,\"cwd\":$qcwd,\"async_jobs\":$async_jobs_json,\"reason\":$qreason,$duration_fields}"
    unset "__zhistarchive_cmd_start_s[$id]" "__zhistarchive_cmd_start_ns[$id]"
  }

  __zhistarchive_log_async_start() {
    emulate -L zsh
    local id="$1" job="$2" js="$3"
    __zhistarchive_now
    local qid qsession qts job_fields
    __zhistarchive_json_string "$id"; qid="$REPLY"
    __zhistarchive_json_string "$__zhistarchive_session_id"; qsession="$REPLY"
    __zhistarchive_json_string "$__zhistarchive_now_ts"; qts="$REPLY"
    __zhistarchive_job_summary_fields "$job" "$js"; job_fields="$REPLY"
    __zhistarchive_write "{\"type\":\"async_start\",\"schema\":1,\"id\":$qid,\"session_id\":$qsession,\"ts\":$qts,\"epoch_s\":$__zhistarchive_now_s,\"epoch_ns\":$__zhistarchive_now_ns,$job_fields}"
  }

  __zhistarchive_log_async_end() {
    emulate -L zsh
    local id="$1" job="$2" js="$3"
    __zhistarchive_now
    local qid qsession qts job_fields duration_fields last_state status_json status_kind
    local -a parts
    parts=( "${(@s.:.)js}" )
    if (( ${#parts[@]} >= 3 )); then
      last_state="${parts[-1]#*=}"
    else
      last_state=""
    fi
    __zhistarchive_status_from_proc_state "$last_state"
    status_json="$REPLY"
    status_kind="$REPLY2"
    __zhistarchive_json_string "$id"; qid="$REPLY"
    __zhistarchive_json_string "$__zhistarchive_session_id"; qsession="$REPLY"
    __zhistarchive_json_string "$__zhistarchive_now_ts"; qts="$REPLY"
    __zhistarchive_job_summary_fields "$job" "$js"; job_fields="$REPLY"
    __zhistarchive_duration_json_fields "${__zhistarchive_job_start_s[$job]-}" "${__zhistarchive_job_start_ns[$job]-}" "$__zhistarchive_now_s" "$__zhistarchive_now_ns"
    duration_fields="$REPLY"
    __zhistarchive_write "{\"type\":\"async_end\",\"schema\":1,\"id\":$qid,\"session_id\":$qsession,\"ts\":$qts,\"epoch_s\":$__zhistarchive_now_s,\"epoch_ns\":$__zhistarchive_now_ns,\"status\":$status_json,\"status_kind\":\"$status_kind\",$job_fields,$duration_fields}"
  }

  __zhistarchive_log_async_lost() {
    emulate -L zsh
    local id="$1" job="$2" reason="$3"
    __zhistarchive_now
    local qid qsession qts qreason duration_fields
    __zhistarchive_json_string "$id"; qid="$REPLY"
    __zhistarchive_json_string "$__zhistarchive_session_id"; qsession="$REPLY"
    __zhistarchive_json_string "$__zhistarchive_now_ts"; qts="$REPLY"
    __zhistarchive_json_string "$reason"; qreason="$REPLY"
    __zhistarchive_duration_json_fields "${__zhistarchive_job_start_s[$job]-}" "${__zhistarchive_job_start_ns[$job]-}" "$__zhistarchive_now_s" "$__zhistarchive_now_ns"
    duration_fields="$REPLY"
    __zhistarchive_write "{\"type\":\"async_lost\",\"schema\":1,\"id\":$qid,\"session_id\":$qsession,\"ts\":$qts,\"epoch_s\":$__zhistarchive_now_s,\"epoch_ns\":$__zhistarchive_now_ns,\"job\":$job,\"reason\":$qreason,$duration_fields}"
  }

  __zhistarchive_process_done_jobs() {
    local _save_status=$?
    emulate -L zsh
    (( __zhistarchive_enabled && __zhistarchive_bg_enabled && ${ZSH_SUBSHELL:-0} == 0 )) || return $_save_status

    local job id js job_state
    for job in "${(@k)__zhistarchive_job_cmd_id}"; do
      id="${__zhistarchive_job_cmd_id[$job]}"
      if (( ! ${+jobstates[$job]} )); then
        __zhistarchive_log_async_lost "$id" "$job" "missing_from_job_table"
        unset "__zhistarchive_job_cmd_id[$job]" "__zhistarchive_job_start_s[$job]" "__zhistarchive_job_start_ns[$job]"
        continue
      fi

      js="${jobstates[$job]}"
      job_state="${js%%:*}"
      if [[ $job_state == done ]]; then
        __zhistarchive_log_async_end "$id" "$job" "$js"
        unset "__zhistarchive_job_cmd_id[$job]" "__zhistarchive_job_start_s[$job]" "__zhistarchive_job_start_ns[$job]"
      fi
    done
    return $_save_status
  }

  __zhistarchive_preexec() {
    local _save_status=$?
    emulate -L zsh
    (( __zhistarchive_enabled && ${ZSH_SUBSHELL:-0} == 0 )) || return $_save_status

    __zhistarchive_process_done_jobs
    __zhistarchive_now

    (( __zhistarchive_seq++ ))
    local id="${__zhistarchive_session_id}.${__zhistarchive_seq}"
    local typed="$1" short="$2" expanded="$3"
    [[ -z $typed ]] && typed="$expanded"

    __zhistarchive_cur_id="$id"
    __zhistarchive_cmd_start_s[$id]="$__zhistarchive_now_s"
    __zhistarchive_cmd_start_ns[$id]="$__zhistarchive_now_ns"

    __zhistarchive_jobs_before_pids=()
    if (( __zhistarchive_bg_enabled )); then
      local j
      for j in "${(@k)jobstates}"; do
        __zhistarchive_job_pids_csv "${jobstates[$j]}"
        __zhistarchive_jobs_before_pids[$j]="$REPLY"
      done
    fi

    __zhistarchive_log_command_start "$id" "$typed" "$expanded" "$short"
    return $_save_status
  }

  __zhistarchive_precmd() {
    local last_status=$?
    emulate -L zsh
    (( __zhistarchive_enabled && ${ZSH_SUBSHELL:-0} == 0 )) || return $last_status

    local id="$__zhistarchive_cur_id"
    local -a new_jobs async_jobs
    local j current_pids before_pids js async_jobs_json

    new_jobs=()
    async_jobs=()

    if [[ -n $id ]]; then
      if (( __zhistarchive_bg_enabled )); then
        for j in "${(@k)jobstates}"; do
          __zhistarchive_job_pids_csv "${jobstates[$j]}"
          current_pids="$REPLY"
          before_pids="${__zhistarchive_jobs_before_pids[$j]-}"
          if [[ -z ${__zhistarchive_jobs_before_pids[$j]+x} || $current_pids != $before_pids ]]; then
            new_jobs+=( "$j" )
          fi
        done
      fi

      if (( ${#new_jobs[@]} )); then
        local -a items
        items=()
        for j in "${new_jobs[@]}"; do
          js="${jobstates[$j]}"
          __zhistarchive_job_cmd_id[$j]="$id"
          __zhistarchive_job_start_s[$j]="${__zhistarchive_cmd_start_s[$id]-}"
          __zhistarchive_job_start_ns[$j]="${__zhistarchive_cmd_start_ns[$id]-}"
          __zhistarchive_log_async_start "$id" "$j" "$js"
          case "$j" in
            (""|*[!0-9]*)
              __zhistarchive_json_string "$j"
              items+=( "$REPLY" )
              ;;
            (*)
              items+=( "$j" )
              ;;
          esac
        done
        async_jobs_json="[${(j:,:)items}]"
      else
        async_jobs_json="[]"
      fi

      __zhistarchive_cur_id=""
      __zhistarchive_log_command_end "$id" "$last_status" "$async_jobs_json" "precmd"
    fi

    __zhistarchive_process_done_jobs
    return $last_status
  }

  __zhistarchive_zshexit() {
    local exit_status=$?
    emulate -L zsh
    (( __zhistarchive_enabled && ${ZSH_SUBSHELL:-0} == 0 )) || return $exit_status

    if [[ -n $__zhistarchive_cur_id ]]; then
      __zhistarchive_log_command_end "$__zhistarchive_cur_id" "$exit_status" "[]" "zshexit"
      __zhistarchive_cur_id=""
    fi

    __zhistarchive_process_done_jobs

    __zhistarchive_now
    local qsession qts
    __zhistarchive_json_string "$__zhistarchive_session_id"; qsession="$REPLY"
    __zhistarchive_json_string "$__zhistarchive_now_ts"; qts="$REPLY"
    __zhistarchive_write "{\"type\":\"session_end\",\"schema\":1,\"session_id\":$qsession,\"ts\":$qts,\"epoch_s\":$__zhistarchive_now_s,\"epoch_ns\":$__zhistarchive_now_ns,\"status\":$exit_status}"

    if (( __zhistarchive_fd >= 0 )); then
      exec {__zhistarchive_fd}>&- 2>/dev/null || true
      __zhistarchive_fd=-1
    fi
    return $exit_status
  }

  __zhistarchive_trap_chld() {
    local _save_status=$?
    emulate -L zsh
    (( ${ZSH_SUBSHELL:-0} == 0 )) && __zhistarchive_process_done_jobs
    if (( ${+functions[__zhistarchive_user_TRAPCHLD]} )); then
      __zhistarchive_user_TRAPCHLD "$@" || true
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
  __zhistarchive_has_list_chld_trap() {
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
  if (( __zhistarchive_have_datetime )); then
    __zhistarchive_now
    typeset __zhistarchive_safe_host="${__zhistarchive_host//[^A-Za-z0-9_.-]/_}"
    typeset __zhistarchive_safe_user="${__zhistarchive_user//[^A-Za-z0-9_.-]/_}"
    __zhistarchive_session_id="${__zhistarchive_safe_host}.${__zhistarchive_safe_user}.${__zhistarchive_now_s}.${__zhistarchive_now_ns}.${__zhistarchive_shell_pid}.${RANDOM}${RANDOM}"
    __zhistarchive_dir="${ZSH_HISTORY_ARCHIVE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/zsh-history-archive}"
    __zhistarchive_file="${__zhistarchive_dir}/hist.${__zhistarchive_session_id}.jsonl"

    typeset __zhistarchive_old_umask
    __zhistarchive_old_umask="$(umask)"
    umask 077
    [[ -d $__zhistarchive_dir ]] || command mkdir -p -- "$__zhistarchive_dir" 2>/dev/null || true

    if [[ -d $__zhistarchive_dir ]]; then
      if (( ${+builtins} && ${+builtins[sysopen]} )); then
        sysopen -w -a -m 0600 -o create,cloexec -u __zhistarchive_fd "$__zhistarchive_file" 2>/dev/null || __zhistarchive_fd=-1
      else
        exec {__zhistarchive_fd}>>"$__zhistarchive_file" 2>/dev/null || __zhistarchive_fd=-1
      fi
    fi
    umask "$__zhistarchive_old_umask"

    if (( __zhistarchive_fd >= 0 )); then
      __zhistarchive_enabled=1
    fi
  fi

  # Enable background tracking only if we have zsh job parameters and no
  # unchainable pre-existing list-form CHLD trap.
  if (( __zhistarchive_enabled && __zhistarchive_have_jobparams )) && [[ -o monitor ]]; then
    if (( ${+functions[TRAPCHLD]} )) && [[ ${functions[TRAPCHLD]} != *__zhistarchive_trap_chld* ]]; then
      functions -c TRAPCHLD __zhistarchive_user_TRAPCHLD 2>/dev/null && __zhistarchive_chained_user_chld=1
    elif (( ! ${+functions[TRAPCHLD]} )) && __zhistarchive_has_list_chld_trap "$__zhistarchive_dir"; then
      __zhistarchive_chld_conflict=1
    fi

    if (( ! __zhistarchive_chld_conflict )); then
      __zhistarchive_bg_enabled=1
      [[ -o notify ]] && __zhistarchive_notify_was_on=1
      unsetopt NOTIFY
      TRAPCHLD() { __zhistarchive_trap_chld "$@"; }
    fi
  fi

  if (( __zhistarchive_enabled )); then
    add-zsh-hook preexec __zhistarchive_preexec
    add-zsh-hook precmd  __zhistarchive_precmd
    add-zsh-hook zshexit __zhistarchive_zshexit
    __zhistarchive_log_session_start
  fi
fi
