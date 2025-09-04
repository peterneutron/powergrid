# Makefile for PowerGrid

PROJECT_NAME = PowerGrid
PROJECT_PATH = ./cmd/powergrid-app/PowerGrid
SCHEME_NAME = Release
PROTO_SCRIPT = ./scripts/gen_proto.sh
EXPORT_OPTIONS_PLIST = ./ExportOptions.plist
GENERATED_SWIFT_DIR = ./generated/swift
TARGET_SWIFT_DIR = ./cmd/powergrid-app/PowerGrid/${PROJECT_NAME}/internal/rpc

# --- Main Targets ---

all: release

release: proto
	@echo "--> Archiving PowerGrid.app for distribution..."
	xcodebuild -project ${PROJECT_PATH}/${PROJECT_NAME}.xcodeproj -scheme ${SCHEME_NAME} -configuration Release archive -archivePath ./build/${PROJECT_NAME}.xcarchive
	xcodebuild -exportArchive -archivePath ./build/${PROJECT_NAME}.xcarchive -exportPath ./build -exportOptionsPlist ${EXPORT_OPTIONS_PLIST}

# --- Helper Targets ---

proto:
	@echo "--> Running protobuf generation script..."
	@bash ${PROTO_SCRIPT}
	@echo "--> Copying generated Swift files into the project..."
	@cp ${GENERATED_SWIFT_DIR}/*.swift ${TARGET_SWIFT_DIR}/
	@echo "✅ Swift files copied to ${TARGET_SWIFT_DIR}"

clean:
	@echo "--> Cleaning build artifacts..."
	@xcodebuild -project ${PROJECT_PATH}/${PROJECT_NAME}.xcodeproj -scheme ${SCHEME_NAME} clean
	@rm -rf ./build
	@rm -rf ./generated
	@echo "✅ Cleaned build, generated, and rpc directories."

# Declare targets that are not files
.PHONY: all proto clean
