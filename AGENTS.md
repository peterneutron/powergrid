# AGENTS: Working Guide for `powergrid`

This file is the source of truth for contributors and coding agents working in `powergrid`.

## Scope

- repo: `powergrid` only
- goal: ship a reliable daemon-mediated macOS power management app and CLI
- priority order:
  1. daemon correctness and safety
  2. compatibility across app, daemon, and RPC layers
  3. build and release repeatability

## Project Layout

- `cmd/powergrid-daemon/`
  - root daemon entrypoint
- `cmd/powergrid-app/`
  - SwiftUI menu bar app
- `cmd/powergridctl/`
  - user CLI that talks to the daemon
- `internal/daemon/`
  - daemon orchestration, decisions, session handling, and IPC
- `proto/`
  - RPC schema
- `generated/`
  - generated manifest and Swift outputs

## Non-Negotiable Rules

- do not bypass the daemon for user-facing control paths
- do not hand-edit generated protobuf or gRPC artifacts
- keep auth and socket ownership semantics intact unless the change explicitly targets them
- preserve protocol compatibility unless a coordinated RPC version bump is intentional

## Build and Verification

Run from repo root:

- `make test`
- `make vet`
- `make lint`
- `make proto-check`
- `make xcodegen-check`
- `make swiftlint`
- `make swift-test`
- `make verify`

Use `make build` for an unsigned local app build.

## Generated Files

Sources of truth:

- `proto/powergrid.proto`
- `project.yml`

Generated or derived outputs:

- `internal/rpc/*`
- `generated/swift/*`
- `cmd/powergrid-app/PowerGrid/PowerGrid.xcodeproj/*`

If the schema changes, regenerate instead of patching generated outputs manually.

## Editing Guidance

- daemon behavior changes usually belong in `internal/daemon/server` or `internal/daemon/engine`
- CLI changes should keep `powergridctl` daemon-backed
- app UI changes should preserve the app’s existing visual language unless a redesign is requested
- avoid mixing large docs cleanup with daemon behavior changes in the same commit when possible

## Release Model

- trunk branch: `master`
- releases are tagged from `master`
- if PowerGrid needs new `powerkit-go` APIs, release `powerkit-go` first and then bump `go.mod`
