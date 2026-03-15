#!/usr/bin/env bash
# test-desktop-notify.sh — Tests for shared/desktop-notify.sh (adapter pattern)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: desktop-notify"

# ── Setup: mock directory ──
MOCK_BIN=$(mktemp -d)
MOCK_LOG=$(mktemp)
export DESKTOP_NOTIFY_MOCK_LOG="$MOCK_LOG"

cleanup() {
  rm -f "$MOCK_LOG"
  rm -rf "$MOCK_BIN"
}
trap cleanup EXIT

# Helper: create a mock executable
create_mock() {
  local name="$1"
  local body="$2"
  cat > "${MOCK_BIN}/${name}" <<MOCK
#!/usr/bin/env bash
${body}
MOCK
  chmod +x "${MOCK_BIN}/${name}"
}

# ── Test 1: desktop_notify function exists after sourcing ──
source "${CEKERNEL_DIR}/scripts/shared/desktop-notify.sh"
if declare -f desktop_notify > /dev/null 2>&1; then
  echo "  PASS: desktop_notify function exists"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: desktop_notify function should exist"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 2: desktop_notify requires title argument ──
if (desktop_notify 2>/dev/null); then
  echo "  FAIL: desktop_notify should fail when title is missing"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "  PASS: desktop_notify fails when title is missing"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# ── Test 3: desktop_notify requires message argument ──
if (desktop_notify "Title" 2>/dev/null); then
  echo "  FAIL: desktop_notify should fail when message is missing"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "  PASS: desktop_notify fails when message is missing"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# ── Test 4: macOS — osascript called with sound name Glass ──
> "$MOCK_LOG"
create_mock "uname" 'echo "Darwin"'
create_mock "osascript" 'echo "osascript called: $*" >> "${DESKTOP_NOTIFY_MOCK_LOG}"'
# Ensure /proc/version does not exist (macOS) — use a non-existent path
PATH="${MOCK_BIN}:${PATH}" desktop_notify "Test Title" "Test Message"
MOCK_OUTPUT=$(cat "$MOCK_LOG" 2>/dev/null || echo "")
assert_match "osascript called on Darwin" "osascript called:" "$MOCK_OUTPUT"
assert_match "title is passed" "Test Title" "$MOCK_OUTPUT"
assert_match "message is passed" "Test Message" "$MOCK_OUTPUT"
assert_match "sound name Glass included" "Glass" "$MOCK_OUTPUT"

# ── Test 5: macOS — url with CEKERNEL_NOTIFY_MACOS_ACTION=none (default) does not call open ──
> "$MOCK_LOG"
MOCK_OPEN_LOG=$(mktemp)
create_mock "open" 'echo "open called: $*" >> "'"${MOCK_OPEN_LOG}"'"'
unset CEKERNEL_NOTIFY_MACOS_ACTION
PATH="${MOCK_BIN}:${PATH}" desktop_notify "Title" "Message" "https://example.com"
OPEN_OUTPUT=$(cat "$MOCK_OPEN_LOG" 2>/dev/null || echo "")
if [[ -z "$OPEN_OUTPUT" ]]; then
  echo "  PASS: CEKERNEL_NOTIFY_MACOS_ACTION=none does not call open"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: CEKERNEL_NOTIFY_MACOS_ACTION=none should not call open"
  echo "    actual: ${OPEN_OUTPUT}"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi
rm -f "$MOCK_OPEN_LOG"

# ── Test 6: macOS — url with CEKERNEL_NOTIFY_MACOS_ACTION=open calls open ──
> "$MOCK_LOG"
MOCK_OPEN_LOG=$(mktemp)
create_mock "open" 'echo "open called: $*" >> "'"${MOCK_OPEN_LOG}"'"'
CEKERNEL_NOTIFY_MACOS_ACTION=open PATH="${MOCK_BIN}:${PATH}" desktop_notify "Title" "Message" "https://example.com"
OPEN_OUTPUT=$(cat "$MOCK_OPEN_LOG" 2>/dev/null || echo "")
assert_match "open called with URL" "open called:.*https://example.com" "$OPEN_OUTPUT"
rm -f "$MOCK_OPEN_LOG"

# ── Test 7: macOS — url with CEKERNEL_NOTIFY_MACOS_ACTION=pbcopy calls pbcopy ──
> "$MOCK_LOG"
MOCK_PBCOPY_LOG=$(mktemp)
create_mock "pbcopy" 'cat > /dev/null; echo "pbcopy called" >> "'"${MOCK_PBCOPY_LOG}"'"'
CEKERNEL_NOTIFY_MACOS_ACTION=pbcopy PATH="${MOCK_BIN}:${PATH}" desktop_notify "Title" "Message" "https://example.com"
PBCOPY_OUTPUT=$(cat "$MOCK_PBCOPY_LOG" 2>/dev/null || echo "")
assert_match "pbcopy called for URL" "pbcopy called" "$PBCOPY_OUTPUT"
rm -f "$MOCK_PBCOPY_LOG"

# ── Test 8: Linux — notify-send called with icon ──
> "$MOCK_LOG"
# Mock uname to return Linux, ensure not WSL
create_mock "uname" 'echo "Linux"'
create_mock "notify-send" 'echo "notify-send called: $*" >> "${DESKTOP_NOTIFY_MOCK_LOG}"'
create_mock "canberra-gtk-play" 'echo "canberra called: $*" >> "${DESKTOP_NOTIFY_MOCK_LOG}"'
# Override /proc/version check — create a mock grep that returns failure for microsoft
create_mock "grep" 'exit 1'
PATH="${MOCK_BIN}:${PATH}" desktop_notify "Linux Title" "Linux Message"
MOCK_OUTPUT=$(cat "$MOCK_LOG" 2>/dev/null || echo "")
assert_match "notify-send called on Linux" "notify-send called:" "$MOCK_OUTPUT"
assert_match "Linux title is passed" "Linux Title" "$MOCK_OUTPUT"
assert_match "Linux message is passed" "Linux Message" "$MOCK_OUTPUT"
assert_match "icon flag passed" "-i" "$MOCK_OUTPUT"
assert_match "logo.png used as icon" "logo.png" "$MOCK_OUTPUT"

# ── Test 9: Linux — canberra-gtk-play called for sound ──
assert_match "canberra-gtk-play called" "canberra called:" "$MOCK_OUTPUT"
assert_match "message-new-instant sound" "message-new-instant" "$MOCK_OUTPUT"

# ── Test 10: WSL — powershell.exe called with toast XML ──
> "$MOCK_LOG"
create_mock "uname" 'echo "Linux"'
# Mock grep to return success for microsoft (WSL detection)
create_mock "grep" 'exit 0'
create_mock "powershell.exe" 'echo "powershell called: $*" >> "${DESKTOP_NOTIFY_MOCK_LOG}"'
create_mock "wslpath" 'echo "C:\\fake\\logo.png"'
PATH="${MOCK_BIN}:${PATH}" desktop_notify "WSL Title" "WSL Message"
MOCK_OUTPUT=$(cat "$MOCK_LOG" 2>/dev/null || echo "")
assert_match "powershell.exe called on WSL" "powershell called:" "$MOCK_OUTPUT"

# ── Test 11: best-effort — does not fail when notification tool is missing ──
MOCK_BIN_EMPTY=$(mktemp -d)
create_mock "uname" 'echo "Darwin"'
# osascript not in MOCK_BIN_EMPTY
cat > "${MOCK_BIN_EMPTY}/uname" <<'MOCK'
#!/usr/bin/env bash
echo "Darwin"
MOCK
chmod +x "${MOCK_BIN_EMPTY}/uname"

if PATH="${MOCK_BIN_EMPTY}" desktop_notify "Title" "Message"; then
  echo "  PASS: desktop_notify does not fail when notification tool is missing"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: desktop_notify should not fail when notification tool is missing"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi
rm -rf "$MOCK_BIN_EMPTY"

# ── Test 12: URL is optional — no error when omitted ──
> "$MOCK_LOG"
create_mock "uname" 'echo "Darwin"'
create_mock "osascript" 'echo "osascript called: $*" >> "${DESKTOP_NOTIFY_MOCK_LOG}"'
if PATH="${MOCK_BIN}:${PATH}" desktop_notify "Title" "Message"; then
  echo "  PASS: URL is optional — no error when omitted"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: URL should be optional"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 13: backward compatibility — 2-arg call still works ──
> "$MOCK_LOG"
PATH="${MOCK_BIN}:${PATH}" desktop_notify "Compat Title" "Compat Message"
MOCK_OUTPUT=$(cat "$MOCK_LOG" 2>/dev/null || echo "")
assert_match "backward compat: osascript called" "osascript called:" "$MOCK_OUTPUT"
assert_match "backward compat: title passed" "Compat Title" "$MOCK_OUTPUT"

report_results
