#!/bin/sh
#
# Runs xcodebuild with the given arguments and fails on any compiler warning in this
# repository's own code (Sources/, Tests/, Example/), the way the Android SDK's
# allWarningsAsErrors does.
#
#     tools/xcodebuild_strict.sh build -scheme SfereAnalytics -destination '…'
#
# Not SWIFT_TREAT_WARNINGS_AS_ERRORS=YES: as a command-line setting it reaches the base
# library's packages too, which Xcode compiles with warnings suppressed, and the compiler
# rejects the two flags together. A Swift 5.9 manifest cannot scope it to one target
# without unsafe flags, which would make the package unusable as a dependency. So the
# build runs normally and its warnings are checked afterwards; dependencies' warnings
# (under .build/ or DerivedData) are not ours and are ignored.

set -eu

root="$(git rev-parse --show-toplevel)"
log="$(mktemp)"
trap 'rm -f "$log" "$log.status" "$log.warnings"' EXIT

# POSIX sh has no pipefail: xcodebuild's own status goes through a file, past tee.
{
    rc=0
    xcodebuild "$@" 2>&1 || rc=$?
    echo "$rc" > "$log.status"
} | tee "$log"
status="$(cat "$log.status")"
[ "$status" -eq 0 ] || exit "$status"

if grep -E "^$root/(Sources|Tests|Example)/[^:]+:[0-9]+:[0-9]+: warning: " "$log" | sort -u > "$log.warnings" && [ -s "$log.warnings" ]; then
    sed "s|^$root/||" "$log.warnings" >&2
    echo "xcodebuild_strict: the warnings above are in this repository's code; warnings are errors here." >&2
    exit 1
fi
