#!/bin/sh
set -e

INK=${INK:-zig-out/bin/ink}

$INK test/server.k &
SERVER_PID=$!

sleep 0.1

$INK test/client.k
CLIENT_RC=$?

wait $SERVER_PID
SERVER_RC=$?

if [ $CLIENT_RC -ne 0 ] || [ $SERVER_RC -ne 0 ]; then
  echo "ipc test FAILED (client=$CLIENT_RC server=$SERVER_RC)"
  exit 1
fi

echo "ipc test passed"
