# cekernel Config

## WezTerm Plugin

If using the WezTerm backend, install the WezTerm plugin into `plugins.d/` (recommended):

```bash
cd config
make install    # Symlinks wezterm.cekernel.lua → ~/.config/wezterm/plugins.d/cekernel.lua
make uninstall  # Removes the symlink
```

This requires a `plugins.d` loader in your `wezterm.lua` (before `return config`):

```lua
-- ============================================================
-- Plugins: load all .lua files from plugins.d/
-- ============================================================
for _, file in ipairs(wezterm.glob(wezterm.config_dir .. '/plugins.d/*.lua')) do
  dofile(file)
end
```

If you manage your own WezTerm config, you can load `wezterm.cekernel.lua` directly instead.

## Trusted Config Paths

Tools that require explicit trust for config files (e.g., [mise](https://mise.jdx.dev/), [direnv](https://direnv.net/)) will flag worktree paths as untrusted, because cekernel creates worktrees under `.worktrees/` — a different path from the original repository.

To avoid trust errors on every worker spawn, pre-trust the worktree directory in your tool's configuration.

### Example: mise

Add to `~/.config/mise/config.toml`:

```toml
[settings]
trusted_config_paths = ["~/path/to/repo/.worktrees"]
```

This trusts all config files under `.worktrees/`, covering all current and future worktrees created by cekernel.
