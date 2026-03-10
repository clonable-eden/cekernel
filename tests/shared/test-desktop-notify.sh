#!/usr/bin/env bash
# test-desktop-notify.sh — Tests for shared/desktop-notify.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../helpers.sh"

CEKERNEL_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "test: desktop-notify"

# Source the helper
source "${CEKERNEL_DIR}/scripts/shared/desktop-notify.sh"

# ── Test 1: desktop_notify function exists ──
if declare -f desktop_notify > /dev/null 2>&1; then
  echo "  PASS: desktop_notify function exists"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: desktop_notify function should exist"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 2: desktop_notify calls osascript on Darwin ──
# Mock uname to return Darwin
MOCK_LOG=$(mktemp)
trap "rm -f $MOCK_LOG" EXIT

# Create mock directory
MOCK_BIN=$(mktemp -d)

# Mock osascript
cat > "${MOCK_BIN}/osascript" <<'MOCK'
#!/usr/bin/env bash
echo "osascript called: $*" >> "${DESKTOP_NOTIFY_MOCK_LOG}"
MOCK
chmod +x "${MOCK_BIN}/osascript"

# Mock uname to return Darwin
cat > "${MOCK_BIN}/uname" <<'MOCK'
#!/usr/bin/env bash
echo "Darwin"
MOCK
chmod +x "${MOCK_BIN}/uname"

export DESKTOP_NOTIFY_MOCK_LOG="$MOCK_LOG"
PATH="${MOCK_BIN}:${PATH}" desktop_notify "Test Title" "Test Message"
MOCK_OUTPUT=$(cat "$MOCK_LOG" 2>/dev/null || echo "")
assert_match "osascript called on Darwin" "osascript called:" "$MOCK_OUTPUT"
assert_match "title is passed" "Test Title" "$MOCK_OUTPUT"
assert_match "message is passed" "Test Message" "$MOCK_OUTPUT"

# ── Test 3: desktop_notify calls notify-send on Linux ──
MOCK_LOG_LINUX=$(mktemp)

# Mock notify-send
cat > "${MOCK_BIN}/notify-send" <<'MOCK'
#!/usr/bin/env bash
echo "notify-send called: $*" >> "${DESKTOP_NOTIFY_MOCK_LOG}"
MOCK
chmod +x "${MOCK_BIN}/notify-send"

# Mock uname to return Linux
cat > "${MOCK_BIN}/uname" <<'MOCK'
#!/usr/bin/env bash
echo "Linux"
MOCK
chmod +x "${MOCK_BIN}/uname"

export DESKTOP_NOTIFY_MOCK_LOG="$MOCK_LOG_LINUX"
PATH="${MOCK_BIN}:${PATH}" desktop_notify "Linux Title" "Linux Message"
LINUX_OUTPUT=$(cat "$MOCK_LOG_LINUX" 2>/dev/null || echo "")
assert_match "notify-send called on Linux" "notify-send called:" "$LINUX_OUTPUT"
assert_match "Linux title is passed" "Linux Title" "$LINUX_OUTPUT"
assert_match "Linux message is passed" "Linux Message" "$LINUX_OUTPUT"

# ── Test 4: desktop_notify is best-effort (does not fail on missing tools) ──
# Mock uname to return Darwin, but remove osascript
MOCK_BIN_EMPTY=$(mktemp -d)
cat > "${MOCK_BIN_EMPTY}/uname" <<'MOCK'
#!/usr/bin/env bash
echo "Darwin"
MOCK
chmod +x "${MOCK_BIN_EMPTY}/uname"

# osascript not present — should not fail
if PATH="${MOCK_BIN_EMPTY}" desktop_notify "Title" "Message"; then
  echo "  PASS: desktop_notify does not fail when notification tool is missing"
  TESTS_PASSED=$((TESTS_PASSED + 1))
else
  echo "  FAIL: desktop_notify should not fail when notification tool is missing"
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Test 5: desktop_notify requires title argument ──
# Missing title should cause an error (run in subshell since ${1:?} exits the shell)
if (desktop_notify 2>/dev/null); then
  echo "  FAIL: desktop_notify should fail when title is missing"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "  PASS: desktop_notify fails when title is missing"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# ── Test 6: desktop_notify requires message argument ──
if (desktop_notify "Title" 2>/dev/null); then
  echo "  FAIL: desktop_notify should fail when message is missing"
  TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "  PASS: desktop_notify fails when message is missing"
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# Cleanup
rm -f "$MOCK_LOG" "$MOCK_LOG_LINUX"
rm -rf "$MOCK_BIN" "$MOCK_BIN_EMPTY"

report_results
