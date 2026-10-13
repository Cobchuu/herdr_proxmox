#!/usr/bin/env bash
# Build the client-only Jaspr dashboard for local preview.
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../web/jaspr_dashboard"
dart pub get
dart analyze lib web vendor/juice/lib test
dart test --platform vm
mkdir -p build/web
dart compile js web/main.dart -O2 -o build/web/main.dart.js
cp web/index.html web/styles.css web/icons.svg build/web/
cp -R web/css web/vendor build/web/
printf 'Jaspr dashboard built in web/jaspr_dashboard/build/web.\n'
