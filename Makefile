# Duo — developer tasks. Run `make help`.
SHELL := /bin/zsh
SCRATCH ?= build/spm

.PHONY: help test model clean

help:
	@echo "make test           Run DuoCore unit tests (Swift Testing)"
	@echo "make model          Rebuild the language model from corpora (Python)"

test:
	cd Packages/DuoCore && swift test --scratch-path ../../$(SCRATCH)

model:
	python3 Tools/ModelBuilder/build_model.py

clean:
	rm -rf build
