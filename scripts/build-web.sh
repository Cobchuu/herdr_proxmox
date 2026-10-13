#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
check_runner="$PWD/scripts/check-evidence.py"
check() { python3 "$check_runner" "$@"; }
planned_checks=(flutter-config flutter-version flutter-pin shared-dependencies flutter-dependencies flutter-analyze flutter-tests jaspr-dependencies jaspr-analyze jaspr-tests jaspr-compile)
trap 'check_status=$?; python3 "$check_runner" --finish "${planned_checks[@]}" || check_status=1; exit "$check_status"' EXIT
# On a fresh SDK, first-run notices can precede --machine JSON. Initialize
# separately so only the version response is captured by the parser.
check flutter-config flutter config --no-analytics
version=$(check flutter-version flutter --version --machine)
printf '%s' "$version" | check flutter-pin python3 -c 'import json,sys; required=json.load(open(".fvmrc"))["flutter"]; v=json.load(sys.stdin)["frameworkVersion"]; assert v==required, "Flutter "+required+" required, found "+v'
cd web/dashboard_state
check shared-dependencies flutter pub get
cd ../dashboard
check flutter-dependencies flutter pub get
check flutter-analyze flutter analyze
check flutter-tests flutter test
cd ../jaspr_dashboard
check jaspr-dependencies dart pub get
check jaspr-analyze dart analyze lib web vendor/juice/lib test
check jaspr-tests dart test --platform vm
# Client-only semantic DOM; no server rendering, generators or Flutter renderer.
mkdir -p build/release
check jaspr-compile dart compile js web/main.dart -O2 -o build/release/main.dart.js
cp web/index.html web/styles.css web/icons.svg build/release/
cp -R web/css web/vendor build/release/
# Replace generated assets only after validation and compilation succeed, so old
# Flutter service workers/renderers cannot leak into a new deployment package.
release_destination="$(cd ../.. && pwd)/web/public"
[[ $release_destination == "$PWD/../public" || $release_destination == "$(cd .. && pwd)/public" ]]
rm -rf -- "$release_destination"
mkdir -p "$release_destination/dashboard"
cp build/release/main.dart.js* build/release/index.html build/release/styles.css build/release/icons.svg "$release_destination/dashboard/"
cp -R build/release/css build/release/vendor "$release_destination/dashboard/"
# Preserve both established entry points and hash deep links.
cp -R ../public/dashboard/. ../public/
# Only the project's own pinned build toolchain belongs here. This script is
# what the gateway runs to validate every worker merge, so requiring a
# separately provisioned tool would stall the integration loop whenever that
# provisioning has not run. A task-specific tool belongs to the agent, who
# installs it in its own checkout and reports the real result.
printf '\nBuilt web/public. Copy the repository to your Proxmox host to install.\n'
