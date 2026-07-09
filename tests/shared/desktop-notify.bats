#!/usr/bin/env bats
# desktop-notify.bats — bats-core tests for scripts/shared/desktop-notify.sh
#
# Verifies platform detection, backend dispatch, argument validation, and
# best-effort behavior (never fails when notification tool is missing).
# Uses PATH-shim mocks to simulate different platforms.

load '../helpers/assertions'
load '../helpers/mock-bin'

setup() {
  CEKERNEL_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  NOTIFY_SCRIPT="${CEKERNEL_DIR}/scripts/shared/desktop-notify.sh"
  MOCK_LOG="${BATS_TEST_TMPDIR}/desktop-notify-mock.log"
  export DESKTOP_NOTIFY_MOCK_LOG="$MOCK_LOG"
}

# Helper: source desktop-notify.sh with mocked PATH.
# Platform detection happens at source time. We restrict PATH to
# MOCK_BIN_DIR + system dirs during source so only explicitly mocked
# tools are detected. After sourcing, PATH is restored to include the
# original PATH for function execution.
_SYSTEM_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
setup_platform() {
  unset -f desktop_notify 2>/dev/null || true
  unset _DESKTOP_NOTIFY_PLATFORM 2>/dev/null || true
  local save_path="$PATH"
  PATH="${MOCK_BIN_DIR}:${_SYSTEM_PATH}" source "$NOTIFY_SCRIPT"
  PATH="${MOCK_BIN_DIR}:${save_path}"
}

@test "desktop_notify function exists after sourcing" {
  source "$NOTIFY_SCRIPT"
  declare -f desktop_notify > /dev/null 2>&1
}

@test "desktop_notify requires title argument" {
  source "$NOTIFY_SCRIPT"
  run desktop_notify
  assert_eq "exit non-zero" "1" "$status"
}

@test "desktop_notify requires message argument" {
  source "$NOTIFY_SCRIPT"
  run desktop_notify "Title"
  assert_eq "exit non-zero" "1" "$status"
}

# ── macOS osascript tests ──

@test "macOS: osascript called with title, message, and sound" {
  mock_bin uname 'echo "Darwin"'
  mock_bin osascript 'echo "osascript called: $*" >> "${DESKTOP_NOTIFY_MOCK_LOG}"'
  setup_platform

  > "$MOCK_LOG"
  desktop_notify "Test Title" "Test Message"
  local output
  output=$(cat "$MOCK_LOG" 2>/dev/null || echo "")
  assert_match "osascript called" "osascript called:" "$output"
  assert_match "title passed" "Test Title" "$output"
  assert_match "message passed" "Test Message" "$output"
  assert_match "Glass sound" "Glass" "$output"
}

@test "macOS: URL with default action=none does not call open" {
  mock_bin uname 'echo "Darwin"'
  mock_bin osascript 'echo "osascript called: $*" >> "${DESKTOP_NOTIFY_MOCK_LOG}"'
  local open_log="${BATS_TEST_TMPDIR}/open.log"
  mock_bin open "echo \"open called: \$*\" >> \"${open_log}\""
  setup_platform

  unset CEKERNEL_NOTIFY_MACOS_ACTION 2>/dev/null || true
  desktop_notify "Title" "Message" "https://example.com"
  local open_output
  open_output=$(cat "$open_log" 2>/dev/null || echo "")
  assert_eq "open not called" "" "$open_output"
}

@test "macOS: URL with action=open calls open" {
  mock_bin uname 'echo "Darwin"'
  mock_bin osascript 'echo "osascript called" >> "${DESKTOP_NOTIFY_MOCK_LOG}"'
  local open_log="${BATS_TEST_TMPDIR}/open.log"
  mock_bin open "echo \"open called: \$*\" >> \"${open_log}\""
  setup_platform

  CEKERNEL_NOTIFY_MACOS_ACTION=open desktop_notify "Title" "Message" "https://example.com"
  local open_output
  open_output=$(cat "$open_log" 2>/dev/null || echo "")
  assert_match "open called with URL" "https://example.com" "$open_output"
}

@test "macOS: URL with action=pbcopy calls pbcopy" {
  mock_bin uname 'echo "Darwin"'
  mock_bin osascript 'echo "osascript called" >> "${DESKTOP_NOTIFY_MOCK_LOG}"'
  local pbcopy_log="${BATS_TEST_TMPDIR}/pbcopy.log"
  mock_bin pbcopy "cat > /dev/null; echo \"pbcopy called\" >> \"${pbcopy_log}\""
  setup_platform

  CEKERNEL_NOTIFY_MACOS_ACTION=pbcopy desktop_notify "Title" "Message" "https://example.com"
  local pbcopy_output
  pbcopy_output=$(cat "$pbcopy_log" 2>/dev/null || echo "")
  assert_match "pbcopy called" "pbcopy called" "$pbcopy_output"
}

# ── macOS alerter tests ──

@test "macOS: alerter preferred over osascript" {
  mock_bin uname 'echo "Darwin"'
  mock_bin alerter 'echo "alerter called: $*" >> "${DESKTOP_NOTIFY_MOCK_LOG}"'
  mock_bin osascript 'echo "osascript called: $*" >> "${DESKTOP_NOTIFY_MOCK_LOG}"'
  setup_platform

  > "$MOCK_LOG"
  desktop_notify "Alerter Title" "Alerter Message"
  wait
  local output
  output=$(cat "$MOCK_LOG" 2>/dev/null || echo "")
  assert_match "alerter called" "alerter called:" "$output"
  assert_match "double-dash --message" "--message" "$output"
  assert_match "double-dash --title" "--title" "$output"
  assert_match "double-dash --sound" "--sound" "$output"
  if [[ "$output" == *"osascript called:"* ]]; then
    echo "FAIL: osascript should not be called when alerter is available" >&2
    return 1
  fi
}

@test "macOS: alerter + URL calls open after alerter exits" {
  mock_bin uname 'echo "Darwin"'
  mock_bin alerter 'echo "alerter called: $*" >> "${DESKTOP_NOTIFY_MOCK_LOG}"; exit 0'
  local open_log="${BATS_TEST_TMPDIR}/open-alerter.log"
  mock_bin open "echo \"open called: \$*\" >> \"${open_log}\""
  setup_platform

  > "$MOCK_LOG"
  desktop_notify "Test Title" "Test Message" "https://example.com"
  wait
  local open_output
  open_output=$(cat "$open_log" 2>/dev/null || echo "")
  assert_match "open called with URL" "https://example.com" "$open_output"
}

# ── Linux tests ──

@test "Linux: notify-send called with icon and canberra sound" {
  mock_bin uname 'echo "Linux"'
  mock_bin notify-send 'echo "notify-send called: $*" >> "${DESKTOP_NOTIFY_MOCK_LOG}"'
  mock_bin canberra-gtk-play 'echo "canberra called: $*" >> "${DESKTOP_NOTIFY_MOCK_LOG}"'
  mock_bin grep 'exit 1'  # not WSL
  setup_platform

  > "$MOCK_LOG"
  desktop_notify "Linux Title" "Linux Message"
  local output
  output=$(cat "$MOCK_LOG" 2>/dev/null || echo "")
  assert_match "notify-send called" "notify-send called:" "$output"
  assert_match "title passed" "Linux Title" "$output"
  assert_match "message passed" "Linux Message" "$output"
  assert_match "icon flag" "-i" "$output"
  assert_match "canberra called" "canberra called:" "$output"
  assert_match "message-new-instant sound" "message-new-instant" "$output"
}

# ── WSL tests ──

@test "WSL: powershell.exe called with toast containing title and message" {
  mock_bin uname 'echo "Linux"'
  mock_bin grep 'exit 0'  # WSL
  mock_bin powershell.exe 'echo "powershell called: $*" >> "${DESKTOP_NOTIFY_MOCK_LOG}"'
  mock_bin wslpath 'echo "C:\\fake\\logo.png"'
  setup_platform

  > "$MOCK_LOG"
  desktop_notify "WSL Title" "WSL Message"
  local output
  output=$(cat "$MOCK_LOG" 2>/dev/null || echo "")
  assert_match "powershell called" "powershell called:" "$output"
  assert_match "title passed" "WSL Title" "$output"
  assert_match "message passed" "WSL Message" "$output"
}

@test "WSL: uses registered PowerShell AppId (not unregistered cekernel)" {
  mock_bin uname 'echo "Linux"'
  mock_bin grep 'exit 0'  # WSL
  mock_bin powershell.exe 'echo "powershell called: $*" >> "${DESKTOP_NOTIFY_MOCK_LOG}"'
  mock_bin wslpath 'echo "C:\\fake\\logo.png"'
  setup_platform

  > "$MOCK_LOG"
  desktop_notify "WSL Title" "WSL Message"
  local output
  output=$(cat "$MOCK_LOG" 2>/dev/null || echo "")
  assert_match "registered AppId used" "1AC14E77-02E7-4E5D-B744-2EB1AE5198B7" "$output"
  if [[ "$output" == *"CreateToastNotifier('cekernel')"* ]]; then
    echo "FAIL: should not use unregistered cekernel AppId" >&2
    return 1
  fi
}

# ── General ──

@test "best-effort: does not fail when notification tool is missing" {
  local empty_bin="${BATS_TEST_TMPDIR}/empty-bin"
  mkdir -p "$empty_bin"
  printf '#!/usr/bin/env bash\necho "Darwin"\n' > "${empty_bin}/uname"
  chmod +x "${empty_bin}/uname"

  unset -f desktop_notify 2>/dev/null || true
  unset _DESKTOP_NOTIFY_PLATFORM 2>/dev/null || true
  local save_path="$PATH"
  PATH="${empty_bin}:${_SYSTEM_PATH}" source "$NOTIFY_SCRIPT"
  PATH="${empty_bin}:${_SYSTEM_PATH}"

  run desktop_notify "Title" "Message"
  PATH="$save_path"
  assert_eq "exit 0" "0" "$status"
}

@test "URL is optional — no error when omitted" {
  mock_bin uname 'echo "Darwin"'
  mock_bin osascript 'echo "osascript called" >> "${DESKTOP_NOTIFY_MOCK_LOG}"'
  setup_platform

  run desktop_notify "Title" "Message"
  assert_eq "exit 0" "0" "$status"
}
