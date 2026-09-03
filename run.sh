#!/usr/bin/env bash
#
# Launch the Triage macOS app.
#
# Use this rather than the Xcode project: Triage.xcodeproj does not reliably
# resolve the local SPM package, so the SwiftPM route is the supported one.
#
set -euo pipefail

# Run from the repo root regardless of where this is invoked from.
cd "$(dirname "${BASH_SOURCE[0]}")"

exec swift run TriageApp "$@"
