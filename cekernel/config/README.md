# cekernel Config

## WezTerm Plugin

If using the WezTerm backend, install the WezTerm plugin into `plugins.d/` (recommended):

```bash
cd cekernel/config
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
