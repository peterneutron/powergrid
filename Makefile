SHELL := /bin/bash

# Config
APP_NAME ?= PowerGrid
PROJECT_DIR ?= ./cmd/powergrid-app/PowerGrid
PROJECT ?= $(PROJECT_DIR)/$(APP_NAME).xcodeproj
SCHEME ?= Release
CONFIGURATION ?= Release
BUILD_DIR ?= ./build
ARCHIVE := $(BUILD_DIR)/$(SCHEME).xcarchive
EXPORT_OPTIONS ?= ./ExportOptions.plist
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
SIGNING_IDENTITY_SCRIPT := ./scripts/select_signing_identity.sh
PROTO_SCRIPT ?= ./scripts/gen_proto.sh
GENERATED_SWIFT_DIR ?= ./generated/swift
TARGET_SWIFT_DIR ?= ./cmd/powergrid-app/PowerGrid/$(APP_NAME)/internal/rpc

# --- Main Targets ---

.PHONY: all release proto archive export clean

all: release

release: proto archive export

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

archive: $(BUILD_DIR)
	@identity="$$SIGNING_IDENTITY"; \
	if [[ -z "$$identity" ]]; then \
	  if [[ ! -x "$(SIGNING_IDENTITY_SCRIPT)" ]]; then \
	    echo "error: missing signing identity script at $(SIGNING_IDENTITY_SCRIPT)" >&2; \
	    exit 1; \
	  fi; \
	  identity="$$($(SIGNING_IDENTITY_SCRIPT))"; \
	fi; \
	team_id="$$(printf '%s\n' "$$identity" | sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p')"; \
	team_arg=""; \
	if [[ -n "$$team_id" ]]; then \
	  echo "--> Using development team $$team_id"; \
	  team_arg="DEVELOPMENT_TEAM=$$team_id"; \
	else \
	  echo "Warning: Unable to derive development team from signing identity; ensure Xcode project sets DEVELOPMENT_TEAM"; \
	fi; \
	echo "--> Archiving $(APP_NAME).app (scheme=$(SCHEME), configuration=$(CONFIGURATION)) [signing: $$identity]"; \
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(CONFIGURATION)" \
		-destination 'generic/platform=macOS' \
		-archivePath "$(ARCHIVE)" \
		CODE_SIGN_IDENTITY="$$identity" \
		$$team_arg \
		archive

export: archive
	@echo "--> Exporting archive to $(BUILD_DIR) using $(EXPORT_OPTIONS)"
	xcodebuild -exportArchive \
		-archivePath "$(ARCHIVE)" \
		-exportOptionsPlist "$(EXPORT_OPTIONS)" \
		-exportPath "$(BUILD_DIR)"
	@echo "--> Normalizing exported .app location"
	@appPath="$(APP_BUNDLE)"; \
	srcCandidates=( \
	  "$(BUILD_DIR)/Products/Applications/$(APP_NAME).app" \
	  "$(BUILD_DIR)/Applications/$(APP_NAME).app" \
	  "$(BUILD_DIR)/Products/Applications/$(SCHEME).app" \
	  "$(BUILD_DIR)/Applications/$(SCHEME).app" \
	); \
	if [[ ! -d "$$appPath" ]]; then \
	  for candidate in "$${srcCandidates[@]}"; do \
	    if [[ -d "$${candidate}" ]]; then \
	      cp -R "$${candidate}" "$$appPath"; \
	      break; \
	    fi; \
	  done; \
	fi; \
	if [[ -d "$$appPath" ]]; then \
	  echo "Exported app: $$appPath"; \
	else \
	  echo "Warning: Could not locate exported .app in $(BUILD_DIR)."; \
	fi

# --- Helper Targets ---

proto:
	@echo "--> Running protobuf generation script..."
	@bash $(PROTO_SCRIPT)
	@echo "--> Copying generated Swift files into the project..."
	@cp $(GENERATED_SWIFT_DIR)/*.swift $(TARGET_SWIFT_DIR)/
	@echo "✅ Swift files copied to $(TARGET_SWIFT_DIR)"

clean:
	@echo "--> Cleaning build artifacts..."
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean
	@rm -rf $(BUILD_DIR)
	@rm -rf ./generated
	@echo "✅ Cleaned build, generated, and rpc directories."
