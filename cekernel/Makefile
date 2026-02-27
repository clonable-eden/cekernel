WEZTERM_PLUGINS_DIR := $(HOME)/.config/wezterm/plugins.d

.PHONY: install uninstall

install:
	mkdir -p $(WEZTERM_PLUGINS_DIR)
	ln -sf $(CURDIR)/config/wezterm.cekernel.lua $(WEZTERM_PLUGINS_DIR)/cekernel.lua
	@echo "Done!"

uninstall:
	rm -f $(WEZTERM_PLUGINS_DIR)/cekernel.lua
	@echo "Done!"
