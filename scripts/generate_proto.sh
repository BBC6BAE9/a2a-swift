#!/usr/bin/env bash
# Regenerates Sources/A2A/Generated/a2a.pb.swift from scripts/proto/a2a.proto.
#
# Usage:
#   ./scripts/generate_proto.sh
#
# Prerequisites:
#   brew install protobuf swift-protobuf
#
# When the upstream proto is updated:
#   1. Replace scripts/proto/a2a.proto with the new version.
#   2. Re-add the Swift-only line:  option swift_prefix = "";
#   3. Run this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROTO_DIR="$SCRIPT_DIR/proto"
OUT_DIR="$REPO_ROOT/Sources/A2A/Generated"

# ── dependencies ──────────────────────────────────────────────────────────────

if ! command -v protoc &>/dev/null; then
  echo "error: protoc not found. Run: brew install protobuf" >&2
  exit 1
fi

if ! command -v protoc-gen-swift &>/dev/null; then
  echo "error: protoc-gen-swift not found. Run: brew install swift-protobuf" >&2
  exit 1
fi

# ── googleapis include path ───────────────────────────────────────────────────
# google/api/annotations.proto, client.proto, field_behavior.proto

GOOGLEAPIS_DIR="${GOOGLEAPIS_DIR:-}"

if [[ -z "$GOOGLEAPIS_DIR" ]]; then
  # Try common locations
  for candidate in \
      /tmp/googleapis \
      "$HOME/.cache/googleapis" \
      "$(brew --prefix)/opt/googleapis" ; do
    if [[ -f "$candidate/google/api/annotations.proto" ]]; then
      GOOGLEAPIS_DIR="$candidate"
      break
    fi
  done
fi

if [[ -z "$GOOGLEAPIS_DIR" ]]; then
  echo "googleapis not found. Cloning (shallow)…"
  GOOGLEAPIS_DIR=/tmp/googleapis
  git clone --depth=1 https://github.com/googleapis/googleapis "$GOOGLEAPIS_DIR"
fi

echo "Using googleapis: $GOOGLEAPIS_DIR"

# ── generate ──────────────────────────────────────────────────────────────────

mkdir -p "$OUT_DIR"

protoc \
  -I "$GOOGLEAPIS_DIR" \
  -I "$(brew --prefix protobuf)/include" \
  -I "$PROTO_DIR" \
  --swift_opt=Visibility=Public \
  --swift_out="$OUT_DIR" \
  "$PROTO_DIR/a2a.proto"

echo "Generated: $OUT_DIR/a2a.pb.swift"
