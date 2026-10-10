#!/bin/sh
# Stand-in for the `claude` CLI in headless tests (tests/worker_spec.lua).
# Ignores every flag except `--model`, then answers each stdin message with one
# stream-json turn whose text is that model name — so a test can tell which
# worker process produced a result. Exits when stdin closes (jobstop / nvim
# exit), so it can never outlive the test run.
model=""
while [ $# -gt 0 ]; do
  [ "$1" = "--model" ] && model="$2"
  shift
done
while IFS= read -r _; do
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"%s"}]}}\n' "$model"
  printf '{"type":"result","subtype":"success","is_error":false}\n'
done
