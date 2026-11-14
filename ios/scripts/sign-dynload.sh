#!/bin/bash
# sign-dynload.sh — convert the CPython lib-dynload *.so modules bundled under
# <app>/python into individual frameworks under <app>/Frameworks, following
# the official CPython iOS packaging rules (PEP 730; "Using Python on iOS"
# in the CPython docs, sections 7.1.4 and 7.2.2 step 9), sign each
# framework, then re-seal the app.
#
# WHY: App Store validation rejects loose Mach-O files in the bundle
# ("Invalid bundle structure ... does not have an allowed file type").
# Every binary module must be a dynamic library inside its own .framework
# in the app's Frameworks folder. The interpreter's AppleFrameworkLoader
# finds each module through a .fwork marker left at the module's original
# sys.path location; each framework carries a .origin back-reference.
# (This replaces the previous sign-in-place approach, which was fine for
# sideloading but cannot pass App Store validation.)
#
# WHEN: runs as a postBuildScript, after Xcode has signed the app — the
# same slot the old version used. We convert + sign, then re-sign the
# whole app bundle so its seal covers the changed contents.
set -euo pipefail

APP="${CODESIGNING_FOLDER_PATH:-}"
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "convert-dynload: CODESIGNING_FOLDER_PATH unset or not a dir ($APP) — skipping" >&2
  exit 0
fi

DYNLOAD_DIR="$APP/python/lib/python3.13/lib-dynload"
if [ ! -d "$DYNLOAD_DIR" ]; then
  echo "convert-dynload: no lib-dynload at $DYNLOAD_DIR — nothing to do" >&2
  exit 0
fi

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"
# EXPANDED_CODE_SIGN_IDENTITY is the SHA-1 hash Xcode resolved; "-" means ad-hoc.
echo "convert-dynload: identity=$IDENTITY  dir=$DYNLOAD_DIR"

# Minimal framework Info.plist template (same shape as CPython's
# iOS/Resources/dylib-Info-template.plist). CFBundleExecutable,
# CFBundleIdentifier and CFBundleName are filled in per module.
TEMPLATE="$(mktemp)"
cat > "$TEMPLATE" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string></string>
	<key>CFBundleIdentifier</key>
	<string></string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string></string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>MinimumOSVersion</key>
	<string>13.0</string>
</dict>
</plist>
PLIST

mkdir -p "$APP/Frameworks"

count=0
while IFS= read -r -d '' so; do
  base="$(basename "$so")"                     # e.g. _ssl.cpython-313-darwin.so
  mod="$(echo "$base" | cut -d '.' -f 1)"       # e.g. _ssl
  fw="$APP/Frameworks/$mod.framework"
  mkdir -p "$fw"
  cp "$TEMPLATE" "$fw/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $mod" "$fw/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $mod" "$fw/Info.plist"
  bundle_id="$(echo "${PRODUCT_BUNDLE_IDENTIFIER:-com.example.app}.$mod" | tr '_' '-')"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$fw/Info.plist"
  mv "$so" "$fw/$mod"
  # Marker where the .so used to be, pointing at the framework binary
  # (path relative to the app bundle).
  echo "Frameworks/$mod.framework/$mod" > "${so%.so}.fwork"
  # Back-reference inside the framework, pointing at the .fwork file
  # (path relative to the app bundle).
  echo "python/lib/python3.13/lib-dynload/${base%.so}.fwork" > "$fw/$mod.origin"
  # Sign the framework (official recipe flags).
  /usr/bin/codesign --force --sign "$IDENTITY" -o runtime --timestamp=none --generate-entitlement-der "$fw"
  count=$((count + 1))
done < <(find "$DYNLOAD_DIR" -name '*.so' -type f -print0)
echo "convert-dynload: converted and signed $count modules"
rm -f "$TEMPLATE"

# Re-seal the app so its signature covers the converted contents. Reuse
# the app's own entitlements so we don't strip increased-memory-limit etc.
ENTITLEMENTS_ARG=()
if [ -n "${CODE_SIGN_ENTITLEMENTS:-}" ] && [ -f "${SRCROOT:-.}/$CODE_SIGN_ENTITLEMENTS" ]; then
  ENTITLEMENTS_ARG=(--entitlements "${SRCROOT}/$CODE_SIGN_ENTITLEMENTS")
fi
echo "convert-dynload: re-sealing app bundle $APP"
/usr/bin/codesign --force --sign "$IDENTITY" --timestamp=none \
  "${ENTITLEMENTS_ARG[@]}" "$APP"
echo "convert-dynload: done"
