#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/regression
sources=()
while IFS= read -r -d '' path; do sources+=("$path"); done < <(find MinuteFlow -name '*.swift' ! -name 'MinuteFlowApp.swift' -print0)
swiftc -swift-version 6 -parse-as-library "${sources[@]}" scripts/RegressionChecks.swift \
  -o .build/regression/checks -framework SwiftUI -framework AppKit \
  -framework AVFoundation -framework ScreenCaptureKit -framework Security \
  -framework CoreLocation -framework CryptoKit -framework Accelerate
.build/regression/checks
