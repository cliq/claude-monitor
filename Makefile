.PHONY: gen test test-integration clean open

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
	rm -rf ClaudeMonitor.xcodeproj
	xcodebuild -project ClaudeMonitor.xcodeproj clean 2>/dev/null || true

open: gen
	open ClaudeMonitor.xcodeproj
