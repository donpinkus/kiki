#!/bin/bash
# Fetch + compile the magic wand's SAM 2.1-small Core ML models.
#
# The compiled .mlmodelc bundles are committed under
# ios/Packages/CanvasModule/Sources/CanvasModule/Resources/SAM2/ (~90 MB), so
# this script only needs re-running to upgrade variants (e.g. small → baseplus:
# change VARIANT and the three model names in SAM2Bundle.swift).
#
# Source: https://huggingface.co/apple/coreml-sam2.1-small (Apache 2.0, ungated).
set -euo pipefail

VARIANT="${1:-small}"                 # tiny | small | baseplus | large
case "$VARIANT" in
  tiny) PREFIX="SAM2_1Tiny" ;;
  small) PREFIX="SAM2_1Small" ;;
  baseplus) PREFIX="SAM2_1BasePlus" ;;
  large) PREFIX="SAM2_1Large" ;;
  *) echo "unknown variant: $VARIANT" >&2; exit 1 ;;
esac

REPO="apple/coreml-sam2.1-$VARIANT"
DEST="$(cd "$(dirname "$0")/.." && pwd)/Packages/CanvasModule/Sources/CanvasModule/Resources/SAM2"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for MODEL in ImageEncoder PromptEncoder MaskDecoder; do
  PKG="${PREFIX}${MODEL}FLOAT16.mlpackage"
  echo "── $PKG"
  for P in "Data/com.apple.CoreML/model.mlmodel" "Data/com.apple.CoreML/weights/weight.bin" "Manifest.json"; do
    mkdir -p "$WORK/$PKG/$(dirname "$P")"
    curl -sL --fail -o "$WORK/$PKG/$P" "https://huggingface.co/$REPO/resolve/main/$PKG/$P"
  done
  xcrun coremlcompiler compile "$WORK/$PKG" "$WORK/out"
done

mkdir -p "$DEST"
rm -rf "$DEST"/*.mlmodelc
cp -R "$WORK/out/"*.mlmodelc "$DEST/"
echo "Installed:"
du -sh "$DEST"/*.mlmodelc
