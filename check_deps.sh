#!/bin/bash

for cmd in age aws lz4 mbuffer split sed btrfs openssl flock numfmt; do
  if ! command -v "${cmd}" &> /dev/null; then
    echo "command not found: ${cmd}" >&2
    exit 3
  fi
done
