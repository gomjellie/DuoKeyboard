# Duo — developer tasks. Run `make help`.
SHELL := /bin/zsh
DD := build/dd
DEBUG_PRODUCTS := $(DD)/Build/Products/Debug
SCRATCH ?= build/spm

.PHONY: help project build test install clean model

help:
	@echo "make project        Regenerate Duo.xcodeproj from project.yml (XcodeGen)"
	@echo "make test           Run DuoCore unit tests (Swift Testing)"
	@echo "make build          Build all targets (Debug)"
	@echo "make install        Build + install the Debug input method into ~/Library/Input Methods"
	@echo "make model          Rebuild the language model from corpora (Python)"

project:
	xcodegen generate --quiet

test:
	cd Packages/DuoCore && swift test --scratch-path ../../$(SCRATCH)

build: project
	Tools/scripts/build.sh DuoInputMethod Debug

install: project
	Tools/scripts/build.sh DuoInputMethod Debug
	Tools/scripts/install-ime.sh $(DEBUG_PRODUCTS)/DuoInputMethod.app

model:
	python3 Tools/ModelBuilder/build_model.py

clean:
	rm -rf build Duo.xcodeproj
