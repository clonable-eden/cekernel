CEKERNEL_VAR_DIR := /usr/local/var/cekernel

.PHONY: install uninstall

install:
	@if ! touch $(CEKERNEL_VAR_DIR)/.write-test 2>/dev/null; then \
		echo "Error: Cannot write to $(CEKERNEL_VAR_DIR)/"; \
		echo "Run: sudo mkdir -p $(CEKERNEL_VAR_DIR) && sudo chown $$(whoami):admin $(CEKERNEL_VAR_DIR)"; \
		exit 1; \
	fi
	@rm -f $(CEKERNEL_VAR_DIR)/.write-test
	mkdir -p $(CEKERNEL_VAR_DIR)/locks
	mkdir -p $(CEKERNEL_VAR_DIR)/logs
	mkdir -p $(CEKERNEL_VAR_DIR)/runners
	@if [ ! -f $(CEKERNEL_VAR_DIR)/schedules.json ]; then \
		echo '[]' > $(CEKERNEL_VAR_DIR)/schedules.json; \
		echo "Created $(CEKERNEL_VAR_DIR)/schedules.json"; \
	fi
	@echo "cekernel runtime directory ready: $(CEKERNEL_VAR_DIR)"

uninstall:
	rm -rf $(CEKERNEL_VAR_DIR) 2>/dev/null || \
		(echo "Permission denied. Run: sudo rm -rf $(CEKERNEL_VAR_DIR)" && exit 1)
	@echo "Removed $(CEKERNEL_VAR_DIR)"
