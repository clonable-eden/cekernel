-- cekernel: Worker レイアウトを WezTerm Lua イベントで in-process 構築
--
-- このスニペットを ~/.config/wezterm/wezterm.lua の `return config` の前に追加してください。
-- spawn-worker.sh が OSC user-var 経由でトリガーし、3 ペインレイアウトを
-- GUI プロセス内部で構築します（IPC 7+ 回 → 3 回に削減、UI フリーズ防止）。
--
-- レイアウト:
--   ┌──────────────┬──────────┐
--   │  Claude Code │ Terminal │
--   │   (60%)      │  (40%)   │
--   ├──────────────┴──────────┤
--   │  git log (25%)          │
--   └─────────────────────────┘
--
-- デバッグ: Ctrl+Shift+L で WezTerm デバッグオーバーレイを開き、
-- [cekernel] プレフィックスのログを確認できます。

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
      main_pane:send_text(prompt .. '\n')
    end
  end)

  wezterm.log_info('[cekernel] layout complete: 3 panes created')
end)
