#!/bin/sh
# Downloads the official Inochi2D example models (CC BY 4.0, by seagetch)
# into the app bundle's Models folder. The repo stores them in Git LFS.
set -eu
dest="$(dirname "$0")/../App/Resources/Models"
mkdir -p "$dest"
for m in Aka Midori; do
  if [ ! -s "$dest/$m.inx" ]; then
    curl -fsSL --retry 4 -o "$dest/$m.inx" \
      "https://media.githubusercontent.com/media/Inochi2D/example-models/main/$m.inx"
  fi
done
ls -la "$dest"
