#!/usr/bin/env bash
# Checks what an unsigned IPA really contains, so a downloaded IPA can be
# matched to its commit and its Meta toolkit before it is signed and
# installed: the commit baked into Info.plist, the Meta callback scheme, the
# accessory protocol, and which Meta frameworks are inside.
# Usage: scripts/ci-ipa-check.sh <path to GlassifAI.app> <configuration>
set -euo pipefail

APP="$1"
CONFIG="$2"
PLIST="$APP/Info.plist"

fail() {
  echo "::error title=IPA check ($CONFIG)::$1"
  exit 1
}

raw() { plutil -extract "$1" raw -o - "$PLIST" 2>/dev/null || echo "missing"; }
json() { plutil -extract "$1" json -o - "$PLIST" 2>/dev/null || echo "missing"; }

commit="$(raw AutoLoomCommitSHA)"
bundle="$(raw CFBundleIdentifier)"
version="$(raw CFBundleShortVersionString) ($(raw CFBundleVersion))"
callback="$(raw MWDAT.AppLinkURLScheme)"
app_id="$(raw MWDAT.MetaAppID)"
schemes="$(json CFBundleURLTypes.0.CFBundleURLSchemes)"
protocols="$(json UISupportedExternalAccessoryProtocols)"
modes="$(json UIBackgroundModes)"

[ "$commit" = "${GITHUB_SHA::12}" ] || fail "AutoLoomCommitSHA is '$commit', expected ${GITHUB_SHA::12}"
[ "$callback" = "glassifai://" ] || fail "MWDAT AppLinkURLScheme is '$callback'"
echo "$schemes" | grep -q '"glassifai"' || fail "URL scheme glassifai missing ($schemes)"
echo "$protocols" | grep -q 'com.meta.ar.wearable' || fail "accessory protocol com.meta.ar.wearable missing ($protocols)"
echo "$modes" | grep -q 'bluetooth-central' || fail "background mode bluetooth-central missing ($modes)"
case "$bundle" in
  *-*) fail "bundle identifier '$bundle' contains '-', which Meta's toolkit has rejected" ;;
esac

# The Meta toolkit ships dynamic frameworks; the mock device is test-only.
frameworks=""
for framework in MWDATCore MWDATCamera MWDATMockDevice; do
  if [ -d "$APP/Frameworks/$framework.framework" ]; then
    frameworks="$frameworks $framework"
  fi
done
case "$frameworks" in
  *MWDATMockDevice*) fail "MWDATMockDevice.framework is inside the app (test-only)" ;;
esac
dat="$(python3 -c "
import json
pins = json.load(open('ios/GlassifAI.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'))['pins']
print(next(p['state']['version'] for p in pins if p['identity'] == 'meta-wearables-dat-ios'))
" 2>/dev/null || echo unknown)"

echo "::notice title=IPA $CONFIG::commit $commit · bundle $bundle · app $version · Meta DAT $dat (frameworks:${frameworks:- none embedded}) · MetaAppID $app_id · callback $callback · URL schemes $schemes · accessory $protocols · unsigned: sign it before installing"
