# CloudStream macOS — Build Automation
#
# Primary Commands:
#   make build    - Builds the full stack (library + engine + client) into dist/CloudStream.app
#   make run      - Launches dist/CloudStream.app (builds it first if missing)
#   make test     - Runs tooling, library, engine and Swift client tests
#   make package  - Packages the DMG installer into dist/CloudStream.dmg
#   make clean    - Purges build outputs, DerivedData and dist/
#   make info     - Displays the current build manifest in dist/

.PHONY: all help build run test test-library test-engine test-client test-client-full test-live-player test-player-bench test-core test-scripts package clean info

SHELL := /bin/bash
.SHELLFLAGS := -e -o pipefail -c

all: build

help:
	@echo "======================================================================"
	@echo "  CloudStream macOS — Standard Commands"
	@echo "======================================================================"
	@echo "  make build         Build full release stack -> dist/CloudStream.app"
	@echo "  make run           Launch current release in dist/CloudStream.app"
	@echo "  make test          Run tooling, library, engine and the full client suite"
	@echo "  make test-core     Run isolated Swift extension and backup tests"
	@echo "  make test-scripts  Run build/package tooling tests"
	@echo "  make test-library  Run Kotlin extension-library tests + ABI check"
	@echo "  make test-engine   Run Kotlin scraper engine tests"
	@echo "  make test-client   Run Swift client unit & UI tests"
	@echo "  make test-client-full  Every client and UI test, all gated tiers provisioned (no skips)"
	@echo "  make test-live-player  Run the live libmpv player tests (fixtures in /tmp)"
	@echo "  make test-player-bench Run player startup benchmarks against local CDNs"
	@echo "  make package       Package DMG installer -> dist/CloudStream.dmg"
	@echo "  make clean         Purge build outputs, DerivedData and dist/"
	@echo "  make info          Show current build info in dist/"
	@echo "======================================================================"

build:
	@./scripts/build_dev.sh

run:
	@./run.sh

test: test-scripts test-library test-engine test-client-full

test-scripts:
	@python3 -m unittest discover -s scripts/tests -p 'test_*.py'

test-core:
	@bash scripts/test_extensions_core.sh
	@bash scripts/test_backup_core.sh

test-library:
	@echo "==> Running Kotlin library test suite and ABI check..."
	@./gradlew :library:test :library:checkKotlinAbi --console=plain

test-engine:
	@echo "==> Running Kotlin engine test suite..."
	@./gradlew :engine:test --console=plain

test-client:
	@# The client's end-to-end tests launch the real engine jar; a missing jar fails them.
	@if [ -x ./gradlew ]; then echo "==> Building the engine jar the client's end-to-end tests launch..."; ./gradlew :engine:jar --console=plain -q; fi
	@echo "==> Running Swift client test suite..."
	@mkdir -p client/build/test-results
	@result_dir=$$(mktemp -d client/build/test-results/run.XXXXXX); \
	./scripts/run_logged.sh "$$result_dir/xcodebuild.log" \
	xcodebuild -project client/CloudStreamMac.xcodeproj \
		-scheme CloudStreamMac \
		-destination 'platform=macOS' \
		test \
		-resultBundlePath "$$result_dir/tests.xcresult" \
		-derivedDataPath client/build/DerivedData

# The whole client suite with every gated tier provisioned; a skip fails it.
test-client-full:
	@./scripts/run_full_client_tests.sh

# Live libmpv pipeline tests (Remediation 6.1): real decoding and rendering
# on this Mac's GPU, with media fixtures generated into /tmp.
test-live-player:
	@./scripts/make_player_fixtures.sh
	@mkdir -p client/build/test-results
	@result_dir=$$(mktemp -d client/build/test-results/live.XXXXXX); \
	TEST_RUNNER_CS_MPV_ENGINE_TESTS=1 TEST_RUNNER_CS_IN_MEMORY_DB=1 \
	./scripts/run_logged.sh "$$result_dir/xcodebuild.log" \
	xcodebuild -project client/CloudStreamMac.xcodeproj \
		-scheme CloudStreamMac \
		-destination 'platform=macOS' \
		test \
		-only-testing:CloudStreamMacTests/PlayerEngineLiveTests \
		-only-testing:CloudStreamMacTests/PlayerAudioPipelineTests \
		-only-testing:CloudStreamMacTests/PlayerViewModelLiveTests \
		-resultBundlePath "$$result_dir/tests.xcresult" \
		-derivedDataPath client/build/DerivedData

# Player startup benchmarks against local CDN simulators (media in /tmp/cs-bench).
test-player-bench:
	@./scripts/run_player_benchmarks.sh

package:
	@./scripts/package_app.sh

clean:
	@./scripts/clean.sh --all

info:
	@if [ -f "dist/BUILD_INFO.json" ]; then \
		echo "Current Build Manifest (dist/BUILD_INFO.json):"; \
		cat dist/BUILD_INFO.json; \
	elif [ -d "dist/CloudStream.app" ]; then \
		echo "App exists at dist/CloudStream.app ($$(du -sh dist/CloudStream.app | cut -f1))"; \
	else \
		echo "No active build found in dist/. Run 'make build' to create one."; \
	fi
