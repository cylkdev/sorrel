#!/bin/sh
# Runs `docker system dial-stdio` on the SSH host. If dial-stdio
# exits non-zero before producing any output, synthesizes an
# HTTP/1.1 502 Bad Gateway response so the client sees a typed
# error instead of a clean EOF. If dial-stdio produced output
# before failing, exits silently (cannot inject an HTTP response
# on top of bytes already on the wire); the client falls back to
# its in-library mid-stream detection.
set -u

tmp_out=$(mktemp -t dial-stdio.XXXXXX) || exit 1
trap 'rm -f "$tmp_out"' EXIT

docker system dial-stdio "$@" >"$tmp_out" 2>/dev/null
status=$?

if [ -s "$tmp_out" ]; then
  cat "$tmp_out"
  exit "$status"
fi

if [ "$status" -ne 0 ]; then
  body="upstream dial-stdio failed: exit ${status}"
  printf 'HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: %d\r\n\r\n%s' \
    "${#body}" "$body"
fi

exit 0
