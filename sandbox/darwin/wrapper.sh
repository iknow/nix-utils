#!/bin/bash

set -euo pipefail

# `tty` seems to return /dev/ttys000 if stdin is not a terminal, including
# when run from Eikaiwa Developer. Conditionally provide this value only after
# checking if stdin is actually a terminal.
if ! TTY=$(tty); then
  TTY=""
fi

if [ "${EIKAIWA_SANDBOX_ACTIVE:-}" = true ]; then
  exec "@command@" "$@"
fi

# We're about to apply a sandbox, of which you get exactly one. There's no way
# to also allow Chrome's sandbox.
export EIKAIWA_SANDBOX_ACTIVE=true

declare -a optional_defines

# TMPDIR is removed by `nix shell`
if [ -n "${TMPDIR:+set}" ]; then
  optional_defines+=("-D" "TMPDIR=$TMPDIR")
fi

if [ -n "$TTY" ]; then
  optional_defines+=("-D" "TTY=$TTY")
fi

state_dir="@state_dir@"

if [ -n "$state_dir" ]; then
  optional_defines+=("-D" "STATE_DIR=$state_dir")
fi

exec /usr/bin/sandbox-exec \
  -f "@profile@" \
  -D "HOME=$HOME" \
  -D "NIX_STORE=@store_dir@" \
  -D "SOURCE_ROOT=@source_root@" \
  -D "MACOS_TMPDIR=$(@get_tmpdir@)" \
  "${optional_defines[@]}" \
  "@command@" \
  "$@"
