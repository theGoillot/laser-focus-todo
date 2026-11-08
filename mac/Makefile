DERIVED := build
APP := "$(DERIVED)/Build/Products/Debug/Laser Focus.app"
RELEASE_APP := "$(DERIVED)/Build/Products/Release/Laser Focus.app"

.PHONY: project build release test run install
project:
	xcodegen -q
build: project
	xcodebuild -scheme MenuBarTodo -destination 'platform=macOS' -derivedDataPath $(DERIVED) -quiet build
test: project
	xcodebuild test -scheme MenuBarTodo -destination 'platform=macOS' -derivedDataPath $(DERIVED) 2>&1 | grep -E "error:|failed|Executed" | tail -20
run: build
	-pkill -f "Debug/Laser Focus.app/Contents/MacOS"; open $(APP)
release: project
	xcodebuild -scheme MenuBarTodo -configuration Release -destination 'platform=macOS' -derivedDataPath $(DERIVED) -quiet build
# Installs the Release build (no debug QA channel, registers launch at login) and opens it.
# Quits the running copy first and waits for it, so `open` never reuses the old process.
install: release
	@# The first quit request is sometimes ignored: ask again until the process is gone (max ~20s).
	@for i in 1 2 3 4 5 6 7 8 9 10; do \
	  pgrep -f "/Applications/.*/Contents/MacOS/(MenuBarTodo|Laser Focus)" >/dev/null || break; \
	  osascript -e 'tell application "Laser Focus" to quit' >/dev/null 2>&1; sleep 2; done
	@if pgrep -f "/Applications/.*/Contents/MacOS/(MenuBarTodo|Laser Focus)" >/dev/null; then echo "Laser Focus did not quit; not installing"; exit 1; fi
	rm -rf /Applications/MenuBarTodo.app "/Applications/Laser Focus.app"; cp -R $(RELEASE_APP) /Applications/ && open "/Applications/Laser Focus.app"
