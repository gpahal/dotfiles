#!/usr/bin/env bash
# Human-in-the-loop reproduction loop.
# Copy this file and edit the steps below. The user runs the copy in a separate
# terminal window and pastes the "--- Captured ---" block back to the agent. An agent's
# shell has no terminal the user can type into, so the script exits there.
#
# Usage:
#   bash hitl-loop.template.sh
#
# Two helpers:
#   step "<instruction>"          shows the instruction and waits for Enter
#   capture VAR "<question>"      shows the question and reads the answer into VAR
#
# Captured values are printed, so never `capture` a secret; make signing in a `step`.

set -euo pipefail

# Read answers from /dev/tty, so the loop works even when stdin is redirected.
if ! { : </dev/tty; } 2>/dev/null; then
  echo "hitl-loop: no terminal. Run this script yourself in a terminal, not from an agent's shell." >&2
  exit 1
fi

# On Ctrl+D (EOF), read fails, which would end the script under set -e. Take it as Enter, or
# as the answer typed so far, and print the newline the terminal didn't.
step() {
  printf '\n>>> %s\n' "$1"
  read -r -p "    [Enter when done] " _ </dev/tty || echo
}

capture() {
  local var="$1" question="$2" answer
  printf '\n>>> %s\n' "$question"
  read -r -p "    > " answer </dev/tty || echo
  printf -v "$var" '%s' "$answer"
}

# --- edit below ---------------------------------------------------------

step "Open the app at http://localhost:3000 and sign in."

capture ERRORED "Click the 'Export' button. Did it throw an error? (y/n)"

capture ERROR_MSG "Paste the error message (or 'none'):"

# --- edit above ---------------------------------------------------------

printf '\n--- Captured ---\n'
printf 'ERRORED=%s\n' "$ERRORED"
printf 'ERROR_MSG=%s\n' "$ERROR_MSG"
