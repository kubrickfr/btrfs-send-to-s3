#!/bin/bash

if ! command -v age &> /dev/null; then
  echo "command not found: age"
  exit 3
fi
if ! command -v aws &> /dev/null; then
  echo "command not found: aws"
  exit 3
fi
if ! command -v lz4 &> /dev/null; then
  echo "command not found: lz4"
  exit 3
fi
if ! command -v mbuffer &> /dev/null; then
  echo "command not found: mbuffer"
  exit 3
fi
if ! command -v split &> /dev/null; then
  echo "command not found: split"
  exit 3
fi
if ! command -v sed &> /dev/null; then
  echo "command not found: sed"
  exit 3
fi
if ! command -v btrfs &> /dev/null; then
  echo "command not found: btrfs"
  exit 3
fi

if [ "$(basename $SHELL)" != "bash" ]
  then echo "Please run in bash"
  exit 1
fi