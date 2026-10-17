APP := build/Transcriber.app
INSTALL_DIR := /Applications

.PHONY: app whisper test run install uninstall icon clean

# Quit a running copy and wait until it is gone (opening it too early fails with -600).
# LaunchServices keeps the old instance registered a moment longer, hence the pause and retry.
QUIT_APP := if pkill -x Transcriber; then for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Transcriber >/dev/null || break; sleep 0.3; done; sleep 1; fi
OPEN_APP = open "$(1)" 2>/dev/null || (sleep 2 && open "$(1)")

app:
	./scripts/build-app.sh

whisper:
	./scripts/build-whisper.sh

test:
	swift run -c release SelfTest

run: app
	@$(QUIT_APP)
	@$(call OPEN_APP,$(APP))

install: app
	@$(QUIT_APP)
	rm -rf "$(INSTALL_DIR)/Transcriber.app"
	ditto $(APP) "$(INSTALL_DIR)/Transcriber.app"
	@$(call OPEN_APP,$(INSTALL_DIR)/Transcriber.app)
	@echo "Installed to $(INSTALL_DIR)/Transcriber.app"

uninstall:
	@$(QUIT_APP)
	rm -rf "$(INSTALL_DIR)/Transcriber.app"
	@echo "Models are kept in ~/Library/Application Support/Transcriber (delete manually if wanted)"

icon:
	swift scripts/make-icon.swift

clean:
	rm -rf .build build
