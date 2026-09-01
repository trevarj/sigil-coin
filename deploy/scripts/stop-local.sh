#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: stop-local.sh [--mode testnet|mainnet]

Stop a run-local.sh stack whose foreground terminal was disconnected. Every
PID is matched by /proc start time and exact executable/script identity before
it is signalled. Normal operation should use Ctrl-C in the foreground terminal.
EOF
}

MODE=${MODE:-testnet}
while (($#)); do
  case $1 in
    --mode) (($# >= 2)) || { printf 'missing value for --mode\n' >&2; exit 64; }; MODE=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 64 ;;
  esac
done
[[ $MODE == testnet || $MODE == mainnet ]] || { printf 'MODE must be testnet or mainnet\n' >&2; exit 64; }

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$script_dir/../.." && pwd)
run_dir=${RUN_DIR:-$root/deploy/run/local-$MODE}
expected_stack_script=$script_dir/run-local.sh

proc_starttime() {
  local pid=$1 stat_line rest
  local -a fields
  stat_line=$(<"/proc/$pid/stat") || return 1
  rest=${stat_line##*) }
  read -r -a fields <<< "$rest"
  ((${#fields[@]} >= 20)) || return 1
  printf '%s\n' "${fields[19]}"
}

argv_path_at() {
  local pid=$1 index=$2 expected=$3 arg resolved cwd
  local -a argv
  mapfile -d '' -t argv < "/proc/$pid/cmdline"
  ((${#argv[@]} > index)) || return 1
  arg=${argv[index]}
  cwd=$(readlink -f -- "/proc/$pid/cwd") || return 1
  if [[ $arg == /* ]]; then
    resolved=$(readlink -f -- "$arg" 2>/dev/null || true)
  elif [[ $arg != -* && -e $cwd/$arg ]]; then
    resolved=$(readlink -f -- "$cwd/$arg" 2>/dev/null || true)
  else
    resolved=
  fi
  [[ $resolved == "$expected" ]]
}

record_pid=
record_start=
record_role=
record_expected=
record_exe=
record_running=no

load_record() {
  local file=$1 wanted_role=$2 current_start current_exe first_line
  local -a record
  mapfile -t record < "$file"
  if ((${#record[@]} != 5)) || [[ ! ${record[0]} =~ ^[0-9]+$ || ! ${record[1]} =~ ^[0-9]+$ ]]; then
    printf 'refusing malformed PID record: %s\n' "$file" >&2
    return 70
  fi
  record_pid=${record[0]}
  record_start=${record[1]}
  record_role=${record[2]}
  record_expected=${record[3]}
  record_exe=${record[4]}
  [[ $record_role == "$wanted_role" && $record_expected == /* && $record_exe == /* ]] || {
    printf 'refusing invalid %s identity record\n' "$wanted_role" >&2
    return 70
  }

  if ! kill -0 "$record_pid" 2>/dev/null; then
    record_running=no
    return 0
  fi
  record_running=yes
  current_start=$(proc_starttime "$record_pid" 2>/dev/null || true)
  [[ $current_start == "$record_start" ]] || {
    printf 'refusing reused %s PID %s (start time changed)\n' "$wanted_role" "$record_pid" >&2
    return 70
  }
  current_exe=$(readlink -f -- "/proc/$record_pid/exe" 2>/dev/null || true)
  [[ $current_exe == "$record_exe" ]] || {
    printf 'refusing reused %s PID %s (executable changed)\n' "$wanted_role" "$record_pid" >&2
    return 70
  }

  case $wanted_role in
    stack)
      [[ $record_expected == "$expected_stack_script" && ${current_exe##*/} == bash ]] || {
        printf 'refusing PID %s: exact run-local.sh controller identity is absent\n' "$record_pid" >&2
        return 70
      }
      ;;
    listener)
      [[ ${record_expected##*/} == sigilcoin && -x $record_expected ]] || {
        printf 'refusing PID %s: invalid listener executable\n' "$record_pid" >&2
        return 70
      }
      ;;
    explorer)
      [[ ${record_expected##*/} == sigilcoin-explorer && -x $record_expected ]] || {
        printf 'refusing PID %s: invalid explorer executable\n' "$record_pid" >&2
        return 70
      }
      ;;
  esac
  if [[ $wanted_role == stack ]]; then
    argv_path_at "$record_pid" 1 "$record_expected" || {
      printf 'refusing PID %s: run-local.sh is not the exact script command\n' "$record_pid" >&2
      return 70
    }
  elif [[ $current_exe == "$record_expected" ]]; then
    argv_path_at "$record_pid" 0 "$record_expected" || {
      printf 'refusing PID %s: executable is not the exact command\n' "$record_pid" >&2
      return 70
    }
  else
    IFS= read -r first_line < "$record_expected" || first_line=
    [[ $first_line == '#!'*bash* && ${current_exe##*/} == bash ]] || {
      printf 'refusing PID %s: command interpreter does not match %s\n' "$record_pid" "$record_expected" >&2
      return 70
    }
    argv_path_at "$record_pid" 1 "$record_expected" || {
      printf 'refusing PID %s: script is not the exact command\n' "$record_pid" >&2
      return 70
    }
  fi
}

wait_for_record_exit() {
  local pid=$1 start=$2 count current
  for ((count=0; count<100; count++)); do
    kill -0 "$pid" 2>/dev/null || return 0
    current=$(proc_starttime "$pid" 2>/dev/null || true)
    [[ $current == "$start" ]] || return 0
    sleep 0.1
  done
  return 1
}

stack_file=$run_dir/stack.pid
if [[ -e $stack_file ]]; then
  load_record "$stack_file" stack || exit $?
  if [[ $record_running == yes ]]; then
    stack_pid=$record_pid
    stack_start=$record_start
    kill -TERM "$stack_pid" 2>/dev/null || true
    if ! wait_for_record_exit "$stack_pid" "$stack_start"; then
      printf 'controller PID %s did not exit; retaining PID records\n' "$stack_pid" >&2
      exit 70
    fi
  fi
fi

# If the controller was already dead (for example after SIGKILL), validate all
# remaining children before signalling any of them.
declare -a child_pids=() child_starts=()
for name in explorer listener; do
  pid_file=$run_dir/$name.pid
  [[ -e $pid_file ]] || continue
  load_record "$pid_file" "$name" || exit $?
  if [[ $record_running == yes ]]; then
    child_pids+=("$record_pid")
    child_starts+=("$record_start")
  fi
done

for index in "${!child_pids[@]}"; do
  kill -TERM "${child_pids[index]}" 2>/dev/null || true
done
for index in "${!child_pids[@]}"; do
  if ! wait_for_record_exit "${child_pids[index]}" "${child_starts[index]}"; then
    printf 'child PID %s did not exit; retaining PID records\n' "${child_pids[index]}" >&2
    exit 70
  fi
done

rm -f -- "$run_dir/stack.pid" "$run_dir/listener.pid" "$run_dir/explorer.pid"
printf 'Local %s stack is stopped. Persistent state was not removed.\n' "$MODE"
