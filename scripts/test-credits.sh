#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ai-credit-tests.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
SDK="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -sdk "$SDK" -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -module-cache-path "$BUILD_DIR/ModuleCache" -parse-as-library \
  "$ROOT/Sources/Models/MonitorModels.swift" "$ROOT/Sources/Models/OpenAICredits.swift" \
  "$ROOT/Sources/Models/QuotaResetFormatter.swift" \
  "$ROOT/Sources/Services/QuotaClient.swift" "$ROOT/Sources/Services/OpenAICredentialDiscovery.swift" \
  "$ROOT/Sources/Services/OpenAICreditClient.swift" \
  "$ROOT/Sources/Services/BraveCreditGrantClient.swift" \
  "$ROOT/Sources/Services/CreditSnapshotCache.swift" "$ROOT/Sources/Services/AIQuotaService.swift" "$ROOT/Tests/OpenAICreditsTests.swift" \
  -o "$BUILD_DIR/credit-tests"
"$BUILD_DIR/credit-tests"
