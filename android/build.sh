#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
PLATFORM="${SDK_PLATFORM:-$(ls "$SDK/platforms" | sort -V | tail -1)}"
VERSION="$(cat "$HERE/../VERSION" | tr -d '\r\n')"
OUT="${1:-$HERE/build}"
mkdir -p "$OUT/classes"
javac -source 8 -target 8 -Xlint:-options -bootclasspath "$SDK/platforms/$PLATFORM/android.jar" -d "$OUT/classes" "$HERE"/src/dev/e2estudio/sdk/*.java
jar cf "$OUT/classes.jar" -C "$OUT/classes" .
cp "$HERE/AndroidManifest.xml" "$OUT/AndroidManifest.xml"
(cd "$OUT" && zip -q -X e2e-studio-sdk-$VERSION.aar classes.jar AndroidManifest.xml)
(cat "$HERE/AndroidManifest.xml";find "$HERE/src" -name '*.java' | LC_ALL=C sort | while IFS= read -r f;do cat "$f";done) | tr -d '\r' | shasum -a 256 | cut -d ' ' -f 1 > "$OUT/source-sha256.txt"

echo "Built $OUT/e2e-studio-sdk-$VERSION.aar"
