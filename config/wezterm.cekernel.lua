-- cekernel WezTerm plugin — Worker layout via user-var event
--
-- Install: symlink into ~/.config/wezterm/plugins.d/
--   ln -sfn /path/to/config/wezterm.cekernel.lua ~/.config/wezterm/plugins.d/
--
-- spawn-worker.sh triggers this via OSC user-var, constructing a 3-pane layout
-- inside the WezTerm GUI process (IPC 7+ → 3 calls, prevents UI freeze).
--
-- Layout:
--   ┌──────────────┬──────────┐
--   │  Claude Code │ Terminal │
--   │   (60%)      │  (40%)   │
--   ├──────────────┴──────────┤
--   │  git log (25%)          │
--   └─────────────────────────┘
--
-- Debug: Ctrl+Shift+L opens the WezTerm debug overlay.
-- Look for [cekernel] prefixed log entries.

local wezterm = require 'wezterm'

wezterm.on('user-var-changed', function(window, pane, name, value)
  if name ~= 'cekernel_worker_layout' then
    return
  end

  wezterm.log_info('[cekernel] worker layout triggered')

  local ok, params = pcall(wezterm.json_parse, value)
  if not ok then
    wezterm.log_error('[cekernel] JSON parse failed: ' .. tostring(params))
    return
  end

  local worktree = params.worktree or wezterm.home_dir
  local session_id = params.session_id or ''
  local issue_number = params.issue_number or ''
  local command = params.command or ''

  wezterm.log_info('[cekernel] issue=#' .. issue_number .. ' worktree=' .. worktree)

  local main_pane = pane

  -- Bottom pane (25%): git log watch — top_level for full width
  local bottom_pane = main_pane:split {
    direction = 'Bottom',
    size = 0.25,
    cwd = worktree,
    top_level = true,
  }
  bottom_pane:send_text("watch -n3 -t -c 'git --no-pager log --oneline --graph --color=always'\n")

  -- Right pane (40%): worker status monitor
  local right_pane = main_pane:split {
    direction = 'Right',
    size = 0.4,
    cwd = worktree,
  }
  local var_dir = os.getenv('CEKERNEL_VAR_DIR') or '/usr/local/var/cekernel'
  local ipc_dir = os.getenv('CEKERNEL_IPC_DIR') or (var_dir .. '/ipc/' .. session_id)
  right_pane:send_text(
    "watch -n 5 'cat " .. ipc_dir .. "/worker-" .. issue_number .. ".state 2>/dev/null"
    .. ' && echo "---"'
    .. " && tail -5 " .. ipc_dir .. "/logs/worker-" .. issue_number .. ".log 2>/dev/null'\n"
  )

  -- Send the pre-built command to main pane
  -- Command is fully constructed on bash side (cd, env vars, script capture, claude)
  if command ~= '' then
    wezterm.time.call_after(0.3, function()
      main_pane:send_text(command .. '\n')
    end)
  end

  wezterm.log_info('[cekernel] layout complete: 3 panes created')
end)
