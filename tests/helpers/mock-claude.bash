# mock-claude.bash — canonical `claude` CLI shim for v2 spawn-path tests
# (ADR-0017 Decision 2, emulating the ADR-0016 delegated-spawn contract)
#
# Contract source: docs/claude-code-constraints.md
#   § Background Agent Sessions (`--bg` / on-demand daemon)
# Observed claude version: v2.1.201 (2026-07-06; re-verified 2026-07-07,
# #546 probe: `--bg --bare` + prompt composes; real `agents --json`
# records carry extra fields — pid, id, name, status — and a numeric
# epoch-millis startedAt, with a realpath'd cwd).
#
# STALENESS COUPLING (ADR-0017 follow-up): any PR that updates the
# "Background Agent Sessions" section of docs/claude-code-constraints.md
# MUST update this mock in the same PR. This file is the single point of
# update when the real `claude --bg` surface changes.
#
# Requires mock-bin.bash (PATH shim layer). Function overrides are banned
# — see mock-bin.bash header.
#
# Usage (in a .bats file):
#   load '../helpers/mock-bin'
#   load '../helpers/mock-claude'
#
#   setup() { mock_claude; }
#
# API:
#   mock_claude
#     Installs the `claude` PATH shim and exports MOCK_CLAUDE_STATE_DIR
#     (under BATS_TEST_TMPDIR — auto-cleaned per test, like MOCK_BIN_DIR).
#
#   mock_claude_enqueue_short_id <short-id>
#     Queues a short ID (8 hex chars) for the next `--bg` call. Each
#     `--bg` call pops one; when the queue is empty a fixed default
#     ("deadbeef") is used.
#
#   mock_claude_enqueue_agents <json>
#     Queues one full `agents --json` response body (a JSON array).
#     Each `agents --json` call consumes one queued response IN ORDER;
#     after the queue is exhausted the LAST response repeats forever.
#     This makes non-terminating sequences scriptable (e.g. a session
#     that stays `busy`, for poll-timeout branches): simply end the
#     queue with a non-terminal state. With an empty queue, `[]` is
#     emitted.
#
#   mock_claude_agent_record <sessionId> <kind> <cwd> <startedAt> <state>
#     Prints one FULL agents record as a JSON object. All five fields
#     are mandatory (ADR-0017): full records keep both normative capture
#     paths testable — short-ID prefix match against sessionId, and the
#     kind+cwd+startedAt fallback including the interactive-session
#     mis-match regression at repo root.
#     The <state> argument is the LOGICAL session state (busy|blocked|
#     done|stopped|...). It is emitted in the observed field split
#     (verified 2026-07-07, #581): live states (busy, blocked) become
#     `"status":"<state>","state":"working"`; terminal states are
#     emitted as `"state":"<state>"` with NO status field.
#     Real records carry ADDITIONAL fields (pid, id, name) and a
#     realpath'd cwd (verified 2026-07-07) — consumers MUST NOT assume
#     an exclusive field set.
#     <startedAt> is emitted UNQUOTED to match the real numeric
#     epoch-millis shape — pass numeric values (e.g. 1700000000000).
#
# Recorded state (files under MOCK_CLAUDE_STATE_DIR):
#   bg-argv.log   one line per `--bg` call: the full argv, space-joined
#   stop.log      one line per `stop <id>` call: the <id> argument
#
# Shim behavior:
#   claude ... --bg ...    → prints `backgrounded · <short-id>`, records argv
#   claude agents --json   → replays the enqueued response sequence
#   claude stop <id>       → appends <id> to stop.log
#   anything else          → diagnostic on stderr, exit 1 (Rule of Repair:
#                            argv shapes the mock does not model must fail
#                            noisily, never pass silently)

mock_claude() {
  MOCK_CLAUDE_STATE_DIR="${BATS_TEST_TMPDIR:?mock_claude requires bats (BATS_TEST_TMPDIR unset)}/mock-claude"
  mkdir -p "$MOCK_CLAUDE_STATE_DIR"
  export MOCK_CLAUDE_STATE_DIR

  # NOTE: if/elif instead of case — unquoted `)` in case patterns breaks
  # command-substitution parsing when this template is later embedded in
  # a double-quoted string (bash 3.2 compatibility).
  local shim_template
  shim_template=$(cat <<'SHIM'
if [[ "${1:-}" == "agents" ]]; then
  # Replay the enqueued response sequence: one response per call,
  # repeating the last response after the queue is exhausted.
  n=0
  [[ -f "$STATE_DIR/agents-calls" ]] && n=$(cat "$STATE_DIR/agents-calls")
  n=$((n + 1))
  echo "$n" > "$STATE_DIR/agents-calls"
  total=0
  [[ -f "$STATE_DIR/agents-enqueued" ]] && total=$(cat "$STATE_DIR/agents-enqueued")
  idx=$n
  [[ "$idx" -gt "$total" ]] && idx=$total
  if [[ "$idx" -ge 1 ]]; then
    cat "$STATE_DIR/agents-response.$idx"
  else
    echo "[]"
  fi
elif [[ "${1:-}" == "stop" ]]; then
  echo "${2:?mock-claude: stop requires an id}" >> "$STATE_DIR/stop.log"
else
  for arg in "$@"; do
    if [[ "$arg" == "--bg" ]]; then
      echo "$*" >> "$STATE_DIR/bg-argv.log"
      short_id=""
      if [[ -s "$STATE_DIR/short-ids" ]]; then
        short_id=$(head -n 1 "$STATE_DIR/short-ids")
        tail -n +2 "$STATE_DIR/short-ids" > "$STATE_DIR/short-ids.tmp"
        mv "$STATE_DIR/short-ids.tmp" "$STATE_DIR/short-ids"
      fi
      [[ -z "$short_id" ]] && short_id="deadbeef"
      echo "backgrounded · $short_id"
      exit 0
    fi
  done
  echo "mock-claude: unsupported invocation: $*" >&2
  exit 1
fi
SHIM
)
  mock_bin claude "STATE_DIR=\"${MOCK_CLAUDE_STATE_DIR}\"
${shim_template}"
}

mock_claude_enqueue_short_id() {
  local short_id="${1:?Usage: mock_claude_enqueue_short_id <short-id>}"
  echo "$short_id" >> "${MOCK_CLAUDE_STATE_DIR:?call mock_claude first}/short-ids"
}

mock_claude_enqueue_agents() {
  local json="${1:?Usage: mock_claude_enqueue_agents <json>}"
  local state_dir="${MOCK_CLAUDE_STATE_DIR:?call mock_claude first}"
  local total=0
  [[ -f "${state_dir}/agents-enqueued" ]] && total=$(cat "${state_dir}/agents-enqueued")
  total=$((total + 1))
  printf '%s\n' "$json" > "${state_dir}/agents-response.${total}"
  echo "$total" > "${state_dir}/agents-enqueued"
}

mock_claude_agent_record() {
  local session_id="${1:?Usage: mock_claude_agent_record <sessionId> <kind> <cwd> <startedAt> <state>}"
  local kind="${2:?missing <kind>}"
  local cwd="${3:?missing <cwd>}"
  local started_at="${4:?missing <startedAt>}"
  local state="${5:?missing <state>}"
  # Observed field split (#581): live sessions carry status (busy|blocked)
  # plus state:"working"; terminal sessions carry state only, no status.
  if [[ "$state" == "busy" || "$state" == "blocked" ]]; then
    printf '{"sessionId":"%s","kind":"%s","cwd":"%s","startedAt":%s,"status":"%s","state":"working"}' \
      "$session_id" "$kind" "$cwd" "$started_at" "$state"
  else
    printf '{"sessionId":"%s","kind":"%s","cwd":"%s","startedAt":%s,"state":"%s"}' \
      "$session_id" "$kind" "$cwd" "$started_at" "$state"
  fi
}
