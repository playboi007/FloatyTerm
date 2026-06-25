#!/usr/bin/env bash
# FloatyTerm — shell helper that opens a side-by-side diff in a new app tab
# instead of dumping `diff -u` text into the terminal.
#
# Source this from your ~/.zshrc or ~/.bashrc:
#
#     source /path/to/FloatyTerm/scripts/floaty-diff.sh
#
# Then:
#
#     ftdiff old.swift new.swift
#
# It POSTs the two paths to FloatyTerm's loopback relay (127.0.0.1:7777),
# which resolves them (relative paths against your current $PWD) and opens a
# Diff tab. Loopback-only: nothing leaves your machine.
#
# Optional — make plain `diff` open the viewer when given exactly two file
# args, and fall through to the real /usr/bin/diff otherwise:
#
#     alias diff='ftdiff'        # aggressive: always use the viewer
#   or leave `diff` alone and just use `ftdiff`.

ftdiff() {
  if [ "$#" -ne 2 ]; then
    echo "usage: ftdiff <file1> <file2>" >&2
    return 2
  fi
  if [ ! -e "$1" ]; then echo "ftdiff: no such file: $1" >&2; return 1; fi
  if [ ! -e "$2" ]; then echo "ftdiff: no such file: $2" >&2; return 1; fi

  # JSON-escape backslashes and double quotes in the paths.
  local l r
  l=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
  r=$(printf '%s' "$2" | sed 's/\\/\\\\/g; s/"/\\"/g')
  local cwd
  cwd=$(printf '%s' "$PWD" | sed 's/\\/\\\\/g; s/"/\\"/g')

  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST "http://127.0.0.1:7777/diff" \
    -H 'Content-Type: application/json' \
    --data "{\"left\":\"$l\",\"right\":\"$r\",\"cwd\":\"$cwd\"}" 2>/dev/null)

  case "$code" in
    200) ;;  # opened
    000) echo "ftdiff: FloatyTerm isn't running (relay unreachable)" >&2; return 1 ;;
    *)   echo "ftdiff: FloatyTerm rejected the request (HTTP $code)" >&2; return 1 ;;
  esac
}
