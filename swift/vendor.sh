#!/usr/bin/env bash
# Copy CenterKit into an app: ./vendor.sh <app's package folder>, e.g. ../../herald/desktop.
# It lands in <folder>/Packages/CenterKit, which the app's Package.swift names by path.
# CenterKit lives here until it has a public home an app's CI can fetch.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dest="$1/Packages/CenterKit"
mkdir -p "$dest"
rsync -a --delete --exclude .build --exclude .swiftpm "$here/CenterKit/" "$dest/"
git -C "$here" rev-parse --short HEAD > "$dest/VERSION"
echo "CenterKit $(cat "$dest/VERSION") -> $dest"
