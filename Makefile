# Makefile for building Alpine Lite via upstream alpine-cloud-images
# Mirrors standard GitLab upstream build workflow with QEMU / KVM acceleration.

SHELL           := /bin/bash
-include .env
export $(shell [ -f .env ] && sed -e 's/=.*//' .env)
ALPINE_BRANCH   ?= 3.24
ARCH            ?= x86_64
CLOUD           ?= gcp
BOOTSTRAP       ?= lite
FIRMWARE        ?= bios
MACHINE         ?= vm

UPSTREAM_REPO   ?= https://gitlab.alpinelinux.org/alpine/cloud/alpine-cloud-images.git
BUILD_DIR       ?= $(CURDIR)/build-work
UPSTREAM_DIR    := $(BUILD_DIR)/alpine-cloud-images
OVERLAY_DIR     := $(UPSTREAM_DIR)/overlays/alpine-lite
OUTPUT_DIR      := $(UPSTREAM_DIR)/output

.DEFAULT_GOAL   := help

.PHONY: help
help:
	@echo "Available targets:"
	@echo "  make check-kvm      - Verify KVM acceleration availability (/dev/kvm)"
	@echo "  make deps           - Display/check required host dependencies"
	@echo "  make clone          - Shallow clone upstream alpine-cloud-images"
	@echo "  make overlay        - Inject alpine-lite configs & scripts into overlay dir"
	@echo "  make build          - Run native upstream ./build with QEMU/KVM"
	@echo "  make package        - Package output disk.raw as GCE-compliant .raw.tar.gz"
	@echo "  make clean          - Clean local build workspace"

.PHONY: check-kvm
check-kvm:
	@if [ -e /dev/kvm ]; then \
		echo "[OK] KVM hardware acceleration detected (/dev/kvm)."; \
	else \
		echo "[WARN] /dev/kvm not found! QEMU will run via slower software TCG emulation."; \
	fi

.PHONY: deps
deps:
	@echo "Checking required host tools..."
	@which git >/dev/null 2>&1 || (echo "Missing: git" && exit 1)
	@which qemu-system-x86_64 >/dev/null 2>&1 || (echo "Missing: qemu-system-x86_64" && exit 1)
	@which qemu-img >/dev/null 2>&1 || (echo "Missing: qemu-img" && exit 1)
	@which parted >/dev/null 2>&1 || (echo "Missing: parted" && exit 1)
	@which tar >/dev/null 2>&1 || (echo "Missing: tar" && exit 1)
	@which bsdtar >/dev/null 2>&1 || (echo "Missing: bsdtar (libarchive-tools)" && exit 1)
	@which packer >/dev/null 2>&1 || (echo "Missing: packer" && exit 1)
	@echo "[OK] Core build tools present."

.PHONY: clone
clone:
	@if [ ! -d "$(UPSTREAM_DIR)/.git" ]; then \
		echo "==> Cloning upstream alpine-cloud-images..."; \
		mkdir -p "$(BUILD_DIR)"; \
		git clone --depth 1 "$(UPSTREAM_REPO)" "$(UPSTREAM_DIR)"; \
	else \
		echo "==> Upstream repository already cloned in $(UPSTREAM_DIR)"; \
	fi

.PHONY: overlay
overlay: clone
	@echo "==> Syncing alpine-lite configs and scripts to overlay..."
	@mkdir -p "$(OVERLAY_DIR)/configs" "$(OVERLAY_DIR)/scripts"
	@cp -f "$(CURDIR)/configs/alpine-lite.conf" "$(OVERLAY_DIR)/configs/"
	@cd "$(OVERLAY_DIR)/configs" && ln -sf alpine-lite.conf images.conf
	@cp -f "$(CURDIR)/scripts/setup-lite" "$(OVERLAY_DIR)/scripts/"
	@chmod +x "$(OVERLAY_DIR)/scripts/setup-lite"
	@if [ -d "$(UPSTREAM_DIR)/work/configs" ]; then \
		cp -f "$(CURDIR)/configs/alpine-lite.conf" "$(UPSTREAM_DIR)/work/configs/"; \
		cd "$(UPSTREAM_DIR)/work/configs" && ln -sf alpine-lite.conf images.conf; \
	fi
	@if [ -d "$(UPSTREAM_DIR)/work/scripts" ]; then \
		cp -f "$(CURDIR)/scripts/setup-lite" "$(UPSTREAM_DIR)/work/scripts/"; \
		chmod +x "$(UPSTREAM_DIR)/work/scripts/setup-lite"; \
	fi

.PHONY: build
build: check-kvm overlay
	@echo "==> Executing upstream ./build local for $(ALPINE_BRANCH) $(ARCH) $(FIRMWARE) $(BOOTSTRAP) $(MACHINE) $(CLOUD)..."
	@cd "$(UPSTREAM_DIR)" && ./build local \
		--custom overlays/alpine-lite \
		--only $(ALPINE_BRANCH) $(ARCH) $(FIRMWARE) $(BOOTSTRAP) $(MACHINE) $(CLOUD)
	@echo "==> Build complete! Output raw image in $(UPSTREAM_DIR)/work/images/$(CLOUD)/"

.PHONY: package
package:
	@IMAGE_RAW_DIR=$$(find "$(UPSTREAM_DIR)/work/images/$(CLOUD)" -maxdepth 2 -name "*.raw.tar.gz" 2>/dev/null | head -n 1); \
	if [ -n "$$IMAGE_RAW_DIR" ] && [ -f "$$IMAGE_RAW_DIR" ]; then \
		echo "==> Upstream raw.tar.gz artifact already created at $$IMAGE_RAW_DIR"; \
		cp -f "$$IMAGE_RAW_DIR" "$(CURDIR)/alpine-$(ALPINE_BRANCH)-lite.raw.tar.gz"; \
		echo "==> Staged $(CURDIR)/alpine-$(ALPINE_BRANCH)-lite.raw.tar.gz"; \
	elif [ -f "$(OUTPUT_DIR)/disk.raw" ]; then \
		echo "==> Packaging GCE-compatible tarball..."; \
		tar --numeric-owner -Sczf "$(CURDIR)/alpine-$(ALPINE_BRANCH)-lite.raw.tar.gz" -C "$(OUTPUT_DIR)" disk.raw; \
		echo "==> Created $(CURDIR)/alpine-$(ALPINE_BRANCH)-lite.raw.tar.gz"; \
	else \
		echo "ERROR: No built image artifact found in $(UPSTREAM_DIR)/work/images/$(CLOUD)/. Run 'make build' first."; \
		exit 1; \
	fi

.PHONY: clean
clean:
	@echo "==> Cleaning build workspace..."
	@rm -rf "$(BUILD_DIR)"
	@rm -f "$(CURDIR)/"*.raw.tar.gz
	@echo "[OK] Cleaned."
