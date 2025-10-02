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

exec /usr/bin/sandbox-exec \
  -f "@profile@" \
  -D "TTY=$TTY" \
  -D "HOME=$HOME" \
  -D "NIX_STORE=@store_dir@" \
  -D "SOURCE_ROOT=@source_root@" \
  -D "TMPDIR=$TMPDIR" \
  -D "MACOS_TMPDIR=$(@get_tmpdir@)" \
  -D "STATE_DIR=@state_dir@" \
  "@command@" \
  "$@"
