#!/usr/bin/env bash
# test-desktop-notify-zsh-compat.sh — Verify desktop-notify.sh works when sourced in zsh
#
# When sourced in zsh (e.g., Claude Code's Bash tool), BASH_SOURCE[0] does not
# resolve correctly. The backend directory is not found, and a no-op function
# is silently loaded instead. See #403.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: desktop-notify zsh compat"

# Skip if zsh is not available
if ! command -v zsh >/dev/null 2>&1; then
  echo "  SKIP: zsh not available"
  report_results
  exit 0
fi

# ── Setup: mock directory ──
MOCK_BIN=$(mktemp -d)
MOCK_LOG=$(mktemp)
ORIG_PATH="$PATH"

cleanup() {
  rm -f "$MOCK_LOG"
  rm -rf "$MOCK_BIN"
}
trap cleanup EXIT

# Create mock uname and osascript so we can verify the backend was loaded
cat > "${MOCK_BIN}/uname" <<'MOCK'
#!/usr/bin/env bash
echo "Darwin"
MOCK
chmod +x "${MOCK_BIN}/uname"

cat > "${MOCK_BIN}/osascript" <<MOCK
#!/usr/bin/env bash
echo "osascript called: \$*" >> "${MOCK_LOG}"
MOCK
chmod +x "${MOCK_BIN}/osascript"

# ── Test 1: zsh source resolves backend directory correctly ──
RESULT=$(zsh -c "
  source '${CEKERNEL_DIR}/scripts/shared/desktop-notify.sh'
  if [[ -d \"\${_DESKTOP_NOTIFY_DIR}/desktop-notify-backend\" ]]; then
    echo 'found'
  else
    echo 'not_found'
  fi
" 2>&1)
assert_eq "zsh: _DESKTOP_NOTIFY_DIR resolves to directory with backend" "found" "$RESULT"

# ── Test 2: zsh source loads real backend (not no-op) ──
# Exclude paths where alerter may be installed (homebrew on Apple Silicon
# or Intel Mac) to force osascript fallback so the mock captures the call.
_SYSTEM_PATH=$(echo "$PATH" | tr ':' '\n' | grep -v -e homebrew -e '/usr/local/bin' | tr '\n' ':')
> "$MOCK_LOG"
ZSH_EXIT=0
zsh -c "
  export PATH='${MOCK_BIN}:${_SYSTEM_PATH}'
  export DESKTOP_NOTIFY_MOCK_LOG='${MOCK_LOG}'
  source '${CEKERNEL_DIR}/scripts/shared/desktop-notify.sh'
  desktop_notify 'ZSH Title' 'ZSH Message'
" 2>&1 || ZSH_EXIT=$?

MOCK_OUTPUT=$(cat "$MOCK_LOG" 2>/dev/null || echo "")
assert_match "zsh: osascript called (real backend loaded, not no-op)" "osascript called:" "$MOCK_OUTPUT"

# ── Test 3: bash source still works (regression) ──
> "$MOCK_LOG"
BASH_EXIT=0
bash -c "
  export PATH='${MOCK_BIN}:${_SYSTEM_PATH}'
  export DESKTOP_NOTIFY_MOCK_LOG='${MOCK_LOG}'
  source '${CEKERNEL_DIR}/scripts/shared/desktop-notify.sh'
  desktop_notify 'Bash Title' 'Bash Message'
" 2>&1 || BASH_EXIT=$?

MOCK_OUTPUT=$(cat "$MOCK_LOG" 2>/dev/null || echo "")
assert_match "bash: osascript called (regression check)" "osascript called:" "$MOCK_OUTPUT"

report_results
