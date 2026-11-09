# Duo — developer tasks. Run `make help`.
SHELL := /bin/zsh
DD := build/dd
DEBUG_PRODUCTS := $(DD)/Build/Products/Debug
RELEASE_PRODUCTS := $(DD)/Build/Products/Release
SCRATCH ?= build/spm
DIST_URL ?= https://gomjellie.github.io/DuoKeyboard

.PHONY: help project build build-release test install e2e app dist run-app clean model

help:
	@echo "make project        Regenerate Duo.xcodeproj from project.yml (XcodeGen)"
	@echo "make test           Run DuoCore unit tests (Swift Testing)"
	@echo "make build          Build all targets (Debug)"
	@echo "make install        Build + install the Debug input method into ~/Library/Input Methods"
	@echo "make e2e            Run end-to-end cases through the real IMK client path"
	@echo "make app            Build the Duo host app (Release) into build/Release/Duo.app"
	@echo "make dist           Package the download site into build/dist (DIST_URL=$(DIST_URL))"
	@echo "make model          Rebuild the language model from corpora (Python)"

project:
	xcodegen generate --quiet

test:
	cd Packages/DuoCore && swift test --scratch-path ../../$(SCRATCH)

build: project
	Tools/scripts/build.sh DuoInputMethod Debug
	Tools/scripts/build.sh DuoHarness Debug
	Tools/scripts/build.sh Duo Debug

build-release: project
	Tools/scripts/build.sh Duo Release

install: project
	Tools/scripts/build.sh DuoInputMethod Debug
	Tools/scripts/install-ime.sh $(DEBUG_PRODUCTS)/DuoInputMethod.app

e2e: install
	Tools/scripts/build.sh DuoHarness Debug
	Tools/scripts/e2e.sh

app: build-release
	mkdir -p build/Release && rm -rf build/Release/Duo.app && ditto $(RELEASE_PRODUCTS)/Duo.app build/Release/Duo.app
	@echo "→ build/Release/Duo.app"

dist: project
	Tools/scripts/dist.sh $(DIST_URL)

model:
	python3 Tools/ModelBuilder/build_model.py

clean:
	rm -rf build Duo.xcodeproj
