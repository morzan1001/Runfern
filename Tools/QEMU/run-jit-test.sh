#!/bin/bash
#
# Starts the installed Debug build on a connected iPad with the given launch arguments, attaches
# LLDB in place of StikDebug, and answers QEMU's `brk #0x69` (see lldb_txm_jit.py).
#
# Usage: run-jit-test.sh <device-udid> <log-prefix> [detach] -- <app arguments...>
# Output: <log-prefix>-app.log (app console) and <log-prefix>-lldb.log (debugger)

set -euo pipefail

DEVICE="$1"; PREFIX="$2"; shift 2
DETACH=""
if [ "${1:-}" = "detach" ]; then DETACH="detach"; shift; fi
[ "${1:-}" = "--" ] && shift
SCRIPT="$(cd "$(dirname "$0")" && pwd)/lldb_txm_jit.py"

nohup xcrun devicectl device process launch --device "$DEVICE" --terminate-existing --start-stopped \
    --console nrw.cyber.runfern -- "$@" > "$PREFIX-app.log" 2>&1 &

PID=""
for _ in $(seq 1 30); do
    sleep 1
    PID="$(xcrun devicectl device info processes --device "$DEVICE" 2>/dev/null \
        | awk '/Runfern.app\/Runfern[[:space:]]*$/ { print $1 }' | head -1)"
    [ -n "$PID" ] && break
done
[ -n "$PID" ] || { echo "App did not start"; exit 1; }
echo "App started stopped as pid $PID"

PYTHONUNBUFFERED=1 nohup xcrun lldb --batch \
    -o "device select $DEVICE" \
    -o "device process attach --pid $PID" \
    -o "process handle SIGURG SIGPIPE SIGUSR1 SIGUSR2 -n false -p true -s false" \
    -o "command script import $SCRIPT" \
    -o "txm_run 40 $DETACH" > "$PREFIX-lldb.log" 2>&1 &
echo "Debugger attached; logs in $PREFIX-app.log and $PREFIX-lldb.log"
