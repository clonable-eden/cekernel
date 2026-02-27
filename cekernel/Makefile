WEZTERM_PLUGINS_DIR := $(HOME)/.config/wezterm/plugins.d

.PHONY: install uninstall

install:
	@mkdir -p $(WEZTERM_PLUGINS_DIR)
	ln -sfnv $(CURDIR)/config/wezterm.cekernel.lua $(WEZTERM_PLUGINS_DIR)/wezterm.cekernel.lua
	@echo "Done!"

uninstall:
	rm -fv $(WEZTERM_PLUGINS_DIR)/wezterm.cekernel.lua
	@echo "Done!"
