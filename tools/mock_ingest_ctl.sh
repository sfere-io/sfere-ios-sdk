#!/bin/sh
# Start, stop or check the mock ingestion server (tools/mock_ingest.mjs). Safe to run twice:
# start reuses a mock that is already listening, and stop reports when there was nothing to stop.
# Stop kills only the PID listening on the port, after checking that its command line is this mock.
#
#   tools/mock_ingest_ctl.sh start|stop|status      port: SFERE_MOCK_PORT (default 4320)

set -u
mock_port="${SFERE_MOCK_PORT:-4320}"
tools_dir="$(cd "$(dirname "$0")" && pwd)"
mock_script="$tools_dir/mock_ingest.mjs"
log_file="${TMPDIR:-/tmp}/sfere-mock-ingest-$mock_port.log"

listening_pid() {
  lsof -nP -iTCP:"$mock_port" -sTCP:LISTEN -t 2>/dev/null | head -1
}

is_our_mock() {
  ps -o args= -p "$1" 2>/dev/null | grep -q "mock_ingest.mjs"
}

case "${1:-}" in
  start)
    pid="$(listening_pid)"
    if [ -n "$pid" ]; then
      if is_our_mock "$pid"; then
        echo "Mock ingest already running on http://127.0.0.1:$mock_port (pid $pid)"
        exit 0
      fi
      echo "Port $mock_port is taken by another process: $(ps -o args= -p "$pid")" >&2
      exit 1
    fi
    SFERE_MOCK_PORT="$mock_port" nohup node "$mock_script" >"$log_file" 2>&1 &
    attempt=0
    while [ "$attempt" -lt 50 ]; do
      if curl -fsS "http://127.0.0.1:$mock_port/__events" >/dev/null 2>&1; then
        echo "Mock ingest running on http://127.0.0.1:$mock_port (pid $(listening_pid), log $log_file)"
        exit 0
      fi
      attempt=$((attempt + 1))
      sleep 0.1
    done
    echo "Mock ingest did not start; see $log_file" >&2
    exit 1
    ;;
  stop)
    pid="$(listening_pid)"
    if [ -z "$pid" ]; then
      echo "Nothing to stop: no mock ingest on port $mock_port"
      exit 0
    fi
    if ! is_our_mock "$pid"; then
      echo "Not stopping pid $pid on port $mock_port: it is not the mock ($(ps -o args= -p "$pid"))" >&2
      exit 1
    fi
    kill "$pid"
    echo "Stopped mock ingest on port $mock_port (pid $pid)"
    ;;
  status)
    pid="$(listening_pid)"
    if [ -n "$pid" ] && is_our_mock "$pid"; then
      echo "Mock ingest running on http://127.0.0.1:$mock_port (pid $pid)"
    else
      echo "Mock ingest is not running on port $mock_port"
      exit 1
    fi
    ;;
  *)
    echo "usage: $0 start|stop|status" >&2
    exit 2
    ;;
esac
