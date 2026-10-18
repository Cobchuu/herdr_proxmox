#!/usr/bin/env bash
# Explicit opt-in: install the project's pinned SDK for development agents.
set -Eeuo pipefail
[[ $EUID == 0 ]] || { echo 'Run as root inside the development container.' >&2; exit 1; }
[[ $(getent passwd herdr | cut -d: -f6) == /home/herdr ]] || { echo 'Install the herdr user first.' >&2; exit 1; }
# The repository declares its own SDK version in .fvmrc. Reading it here keeps
# one pin: a second copy in this script or in the catalog would be one more
# place to forget when the project moves.
release=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
[[ -f $release/.fvmrc ]] || { echo 'This release does not include .fvmrc, so it declares no SDK version.' >&2; exit 1; }
version=$(python3 -c 'import json,sys; value=json.load(open(sys.argv[1])).get("flutter"); print(value if isinstance(value,str) else "")' "$release/.fvmrc" 2>/dev/null) || version=
[[ $version =~ ^[0-9]+(\.[0-9]+)+$ ]] || { echo 'This release does not declare a usable Flutter version in .fvmrc.' >&2; exit 1; }
case "$(uname -m)" in
  x86_64) architecture=x64 ;;
  aarch64) architecture=arm64 ;;
  *) echo 'Unsupported Flutter architecture.' >&2; exit 1 ;;
esac
sdk="/home/herdr/.local/share/flutter-$version"
# Progress for the dashboard. The root worker owns status.json; this file only
# reports how far the install has come, and the gateway treats it as optional —
# an unreadable file must never fail the card. Phases other than the download
# are allocations, so the bar names the phase rather than claiming a measurement.
state=/var/lib/herdr-sdk
install -d -o root -g root -m 0755 "$state" || true
progress() {
  # Publishing progress is optional and atomic; readers never see partial JSON.
  if printf '{"percent": %s, "phase": "%s", "at": "%s"}\n' "$1" "$2" "$(date -u +%FT%T.%NZ)" >"$state/progress.tmp" &&
      chmod 0644 "$state/progress.tmp"; then
    mv -f -- "$state/progress.tmp" "$state/progress.json" || true
  fi
  return 0
}
staging=
cleanup() {
  local status=$?
  rm -f -- "$state/progress.json" "$state/progress.tmp" || true
  if [[ -n $staging ]]; then rm -rf -- "$staging" || true; fi
  return "$status"
}
trap cleanup EXIT
progress 1 starting
install -d -o herdr -g herdr -m 0755 /home/herdr/.local/share /home/herdr/.local/bin
if [[ ! -d $sdk ]]; then
  progress 5 dependencies
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o Acquire::Retries=5 update
  apt-get -o Acquire::Retries=5 install -y ca-certificates curl git python3 xz-utils unzip libglu1-mesa
  staging=$(mktemp -d)
  chmod 0755 "$staging"
  # Release archives live under /releases; /flutter contains engine artifacts.
  origin=https://storage.googleapis.com/flutter_infra_release/releases
  printf 'Downloading official Flutter release manifest.\n'
  curl -fsSL --http1.1 --retry 3 --retry-all-errors --connect-timeout 10 --max-time 120 "$origin/releases_linux.json" -o "$staging/releases.json"
  python3 "$(dirname -- "${BASH_SOURCE[0]}")/flutter-release.py" "$version" "$architecture" <"$staging/releases.json" >"$staging/selected"
  mapfile -t release <"$staging/selected"
  printf 'Downloading Flutter %s (%s): %s/%s\n' "$version" "$architecture" "$origin" "${release[0]}"
  progress 10 download
  # The archive is the long pole, so this phase reports real bytes rather than an
  # allocation: the total from the response headers, the progress from the file
  # growing on disk. curl cannot emit machine-readable progress, hence the poll.
  expected=$(curl -fsSI --http1.1 --connect-timeout 10 --max-time 60 "$origin/${release[0]}" 2>/dev/null \
    | awk 'tolower($1)=="content-length:" {print $2}' | tr -d '\r' | head -n1) || expected=
  curl -fsSL --http1.1 --retry 3 --retry-all-errors --connect-timeout 10 --max-time 1800 "$origin/${release[0]}" -o "$staging/sdk.tar.xz" &
  downloader=$!
  while kill -0 "$downloader" 2>/dev/null; do
    size=$(stat -c %s "$staging/sdk.tar.xz" 2>/dev/null || echo 0)
    if [[ $expected =~ ^[0-9]+$ ]] && (( expected > 0 )); then
      percent=$((10 + size * 55 / expected))
      if (( percent > 65 )); then percent=65; fi
      progress "$percent" download
    fi
    sleep 1
  done
  wait "$downloader"
  progress 70 verify
  printf '%s  %s\n' "${release[1]}" "$staging/sdk.tar.xz" | sha256sum --check --status
  chmod 0644 "$staging/sdk.tar.xz"
  install -d -o herdr -g herdr -m 0755 /home/herdr/.local/share /home/herdr/.local/bin
  install -d -o herdr -g herdr -m 0755 "$staging/unpack"
  # xz decompression reports nothing usable, so this is a phase boundary.
  progress 75 extract
  runuser -u herdr -- tar --no-same-owner -xJf "$staging/sdk.tar.xz" -C "$staging/unpack"
  runuser -u herdr -- mv "$staging/unpack/flutter" "$sdk"
fi
progress 95 initialize
# runuser preserves the caller's environment and working directory. Root's
# Android/XDG settings and /root cwd must not leak into Flutter initialization.
cd /home/herdr
flutter_as_herdr() {
  runuser -u herdr -- env -i HOME=/home/herdr USER=herdr LOGNAME=herdr \
    PATH=/usr/local/bin:/usr/bin:/bin "$sdk/bin/flutter" "$@"
}
flutter_as_herdr config --no-analytics
flutter_as_herdr --version --machine | python3 -c 'import json,sys; assert json.load(sys.stdin)["frameworkVersion"] == sys.argv[1], "Installed Flutter version does not match the project pin"' "$version"
for command in flutter dart; do
  link="/home/herdr/.local/bin/$command"
  if [[ -e $link || -L $link ]]; then
    [[ -L $link && $(readlink "$link") == "$sdk/bin/$command" ]] || { echo "Refusing to replace existing $link" >&2; exit 1; }
  else
    runuser -u herdr -- ln -s "$sdk/bin/$command" "$link"
  fi
done
progress 100 done
printf 'Flutter %s ready for development agents. Use scripts/build-web.sh in the assigned checkout.\n' "$version"
