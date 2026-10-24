#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
out="$here/.build/dist"
stage="$out/stage"
dmg="$out/Loops.dmg"
identity=${LOOPS_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')}
identity=${identity:--}

rm -rf "$out"
mkdir -p "$stage"
env -u LOOPS_REPO LOOPS_IDENTITY="$identity" "$here/build.sh" "$stage" >/dev/null
codesign --verify --deep --strict "$stage/Loops.app"
ln -s /Applications "$stage/Applications"
for attempt in 1 2 3; do
  hdiutil create -quiet -volname Loops -srcfolder "$stage" -format UDZO -ov "$dmg" && break
  [ "$attempt" = 3 ] && exit 1
  sleep 5
done

if [ "$identity" != - ]; then
  codesign --sign "$identity" --timestamp "$dmg"
  if [ -n "${LOOPS_NOTARY_PROFILE:-}" ]; then
    auth=(--keychain-profile "$LOOPS_NOTARY_PROFILE")
  elif [ -n "${LOOPS_NOTARY_KEY:-}" ]; then
    auth=(--key "$LOOPS_NOTARY_KEY" --key-id "$LOOPS_NOTARY_KEY_ID" --issuer "$LOOPS_NOTARY_ISSUER")
  fi
  if [ -n "${auth+x}" ]; then
    xcrun notarytool submit "$dmg" "${auth[@]}" --wait
    xcrun stapler staple "$dmg"
  fi
fi
echo "$dmg"
