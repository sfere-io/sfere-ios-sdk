#!/bin/sh
#
# Regenerates api/SfereAnalytics.api, the public API dump of the SDK (macOS with Xcode).
#
#     tools/api_dump.sh                 # writes api/SfereAnalytics.api
#     tools/api_dump.sh --check         # fails when the committed dump is stale
#     tools/api_dump.sh --output FILE   # writes FILE instead (CI)
#
# Compiles SfereAnalytics for the iOS Simulator (the dump is the iOS API: some methods exist
# only where UIKit does), with the compiler's symbol graph turned on, then turns the graph
# into sorted text with tools/api_dump.py. Warnings are errors here, as in CI.
#
# This script is the only writer of api/SfereAnalytics.api. CI's "Build" job runs it and
# the "API contract" job compares its output with the committed file.

set -eu

cd "$(git rev-parse --show-toplevel)"

out="api/SfereAnalytics.api"
check=0
case "${1:-}" in
    --check) check=1 ;;
    --output) out="$2" ;;
    "") ;;
    *) echo "usage: tools/api_dump.sh [--check | --output FILE]" >&2; exit 2 ;;
esac

work=".build/api-dump"
rm -rf "$work/symbol-graphs"
mkdir -p "$work/symbol-graphs"

xcodebuild build -quiet \
    -scheme SfereAnalytics \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$work/derived-data" \
    -onlyUsePackageVersionsFromResolvedFile \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    OTHER_SWIFT_FLAGS="\$(inherited) -emit-symbol-graph -emit-symbol-graph-dir $PWD/$work/symbol-graphs -symbol-graph-minimum-access-level public"

if [ "$check" = 1 ]; then
    python3 -I tools/api_dump.py "$work/symbol-graphs" > "$work/SfereAnalytics.api"
    if ! diff -u api/SfereAnalytics.api "$work/SfereAnalytics.api"; then
        echo "api_dump: api/SfereAnalytics.api is stale. Run tools/api_dump.sh and commit the result." >&2
        exit 1
    fi
    echo "api_dump: api/SfereAnalytics.api matches the code."
else
    python3 -I tools/api_dump.py "$work/symbol-graphs" > "$out"
    echo "api_dump: wrote $out"
fi
