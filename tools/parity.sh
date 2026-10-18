#!/bin/sh
# Run the shared parity scenario on both SDKs and compare their upload bodies key by key.
# Needs both repositories checked out, by default side by side:
#   <parent>/sfere-ios-sdk and <parent>/sfere-android-sdk
# Override the locations with SFERE_IOS_SDK_DIR and SFERE_ANDROID_SDK_DIR.
# The same script lives in both repositories; keep the two copies identical.
set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
parent_dir="$(dirname "$repo_root")"
ios_dir="${SFERE_IOS_SDK_DIR:-$parent_dir/sfere-ios-sdk}"
android_dir="${SFERE_ANDROID_SDK_DIR:-$parent_dir/sfere-android-sdk}"

for checkout_dir in "$ios_dir" "$android_dir"; do
  if [ ! -d "$checkout_dir" ]; then
    echo "Missing checkout: $checkout_dir. Clone it next to this repository, or set SFERE_IOS_SDK_DIR / SFERE_ANDROID_SDK_DIR."
    exit 2
  fi
done

echo "Shared files (must be identical in both repositories):"
shared_files_differ=0
for shared_file in fixtures/deeplinks.json fixtures/event-names.json tools/parity.sh tools/parity_diff.py tools/mock_ingest.mjs tools/mock_ingest_ctl.sh; do
  if cmp -s "$ios_dir/$shared_file" "$android_dir/$shared_file"; then
    echo "  same     $shared_file"
  else
    echo "  DIFFERS  $shared_file"
    shared_files_differ=1
  fi
done
if [ "$shared_files_differ" != 0 ]; then
  echo "Copy the changed file into the other repository, then run this again."
  exit 1
fi

parity_dir="$(mktemp -d)"
trap 'rm -rf "$parity_dir"' EXIT
(cd "$ios_dir" && SFERE_PARITY_DIR="$parity_dir" swift test --filter WireTests/testParityScenarioAndDeepLinkProperties)
(cd "$android_dir" && SFERE_PARITY_DIR="$parity_dir" JAVA_HOME="$(/usr/libexec/java_home -v 17)" ./gradlew :sfere-analytics:testDebugUnitTest --tests 'io.sfere.analytics.TransportTest.parityScenarioAndDeepLinkProperties' --rerun -q)
python3 -I "$repo_root/tools/parity_diff.py" "$parity_dir"
