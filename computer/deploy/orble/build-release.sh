#!/usr/bin/env bash
# Package the upstream host release with the session image from main, by digest.
set -euo pipefail

output=$(realpath -m "${1:?Usage: build-release.sh <output.bundle>}")
cd "$(dirname "$0")/../.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

tree=$(git rev-parse HEAD:computer/deploy/image)
image=$(deploy/image-pin.sh "$tree")
deploy/bundle.sh "$tmp/computer.bundle" >/dev/null
git clone -q --branch main "$tmp/computer.bundle" "$tmp/release"
printf '%s\n' "$image" > "$tmp/release/deploy/image.pin"
git -C "$tmp/release" add -f deploy/image.pin
stamp=$(git -C "$tmp/release" log -1 --format=%ct)
GIT_AUTHOR_DATE="@$stamp +0000" GIT_COMMITTER_DATE="@$stamp +0000" \
  git -C "$tmp/release" -c user.name=OpenComputer -c user.email=release@opencomputer.invalid \
    -c commit.gpgsign=false commit -qm 'Pin the OpenComputer session image'
git -C "$tmp/release" bundle create "$tmp/pinned.bundle" refs/heads/main
mv "$tmp/pinned.bundle" "$output"
