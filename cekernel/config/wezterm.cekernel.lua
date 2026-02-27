-- cekernel WezTerm plugin — Worker layout via user-var event
--
-- Install: symlink into ~/.config/wezterm/plugins.d/
--   ln -sfn /path/to/cekernel/config/wezterm.cekernel.lua ~/.config/wezterm/plugins.d/
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
  local prompt = params.prompt or ''
  local issue_number = params.issue_number or ''

  wezterm.log_info('[cekernel] issue=#' .. issue_number .. ' worktree=' .. worktree)

  local main_pane = pane

  -- 下部ペイン (25%): git log watch — top_level で全幅に
  local bottom_pane = main_pane:split {
    direction = 'Bottom',
    size = 0.25,
    cwd = worktree,
    top_level = true,
  }
  bottom_pane:send_text("watch -n3 -t -c 'git --no-pager log --oneline --graph --color=always'\n")

  -- 右ペイン (40%): 汎用ターミナル
  main_pane:split {
    direction = 'Right',
    size = 0.4,
    cwd = worktree,
  }

  -- メインペインに cd + export + claude コマンドを送信
  -- shell 起動完了を待ってから send_text
  wezterm.time.call_after(0.3, function()
    main_pane:send_text(
      "cd '" .. worktree .. "' && export CEKERNEL_SESSION_ID='" .. session_id .. "'\n"
    )
    if prompt ~= '' then
      -- シェルエスケープ: ' → '\''
      local escaped = prompt:gsub("'", "'\\''")
      local cmd = "claude --agent cekernel:worker '" .. escaped .. "'"
      main_pane:send_text(cmd .. '\n')
    end
  end)

  wezterm.log_info('[cekernel] layout complete: 3 panes created')
end)
