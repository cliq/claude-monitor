.PHONY: gen test test-integration clean open release install release-signed install-signed

RELEASE_APP := build/release/Build/Products/Release/ClaudeMonitor.app

gen:
	xcodegen generate

test:
	set -o pipefail && xcodebuild test \
	  -project ClaudeMonitor.xcodeproj \
	  -scheme ClaudeMonitor \
	  -destination 'platform=macOS' \
	  -only-testing:ClaudeMonitorTests

test-integration:
	set -o pipefail && xcodebuild test \
	  -project ClaudeMonitor.xcodeproj \
	  -scheme ClaudeMonitor \
	  -destination 'platform=macOS' \
	  -only-testing:ClaudeMonitorIntegrationTests

clean:
	rm -rf ClaudeMonitor.xcodeproj build
	xcodebuild -project ClaudeMonitor.xcodeproj clean 2>/dev/null || true

open: gen
	open ClaudeMonitor.xcodeproj

# Build Release with ad-hoc signing so it runs on this Mac without a Developer ID.
# Use this for local installs; notarized builds are produced by the release workflow
# (see docs/notarization.md).
release: gen
	set -o pipefail && xcodebuild \
	  -project ClaudeMonitor.xcodeproj \
	  -scheme ClaudeMonitor \
	  -configuration Release \
	  -destination 'platform=macOS' \
	  -derivedDataPath build/release \
	  CODE_SIGN_STYLE=Manual \
	  CODE_SIGN_IDENTITY=- \
	  build

# Quit any running copy, replace /Applications/ClaudeMonitor.app, and relaunch.
# Because ad-hoc signatures change on every rebuild, the "ClaudeMonitor would like
# to control Terminal/iTerm2" TCC prompt may reappear after each install.
# NOTE: the usage widget does NOT work from this install — ad-hoc signatures have
# no team ID, so the team-prefixed App Group entitlement can't validate and the
# widget shows its "monitoring off" state. Use `make install-signed` instead.
install: release
	pkill -x ClaudeMonitor 2>/dev/null || true
	rm -rf /Applications/ClaudeMonitor.app
	cp -R "$(RELEASE_APP)" /Applications/
	open /Applications/ClaudeMonitor.app

# Build Release with the identity from Configuration/LocalSigning.xcconfig
# (Apple Development + your DEVELOPMENT_TEAM). Required for the usage widget:
# the team-prefixed App Group only validates under a real team signature.
release-signed: gen
	set -o pipefail && xcodebuild \
	  -project ClaudeMonitor.xcodeproj \
	  -scheme ClaudeMonitor \
	  -configuration Release \
	  -destination 'platform=macOS' \
	  -derivedDataPath build/release \
	  build

install-signed: release-signed
	pkill -x ClaudeMonitor 2>/dev/null || true
	rm -rf /Applications/ClaudeMonitor.app
	cp -R "$(RELEASE_APP)" /Applications/
	open /Applications/ClaudeMonitor.app
