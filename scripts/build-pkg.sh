#!/usr/bin/env bash
# Installer package for IT teams (Jamf, Intune, Kandji, Mosyle, `installer -pkg`). Run by release.sh.
# Usage: scripts/build-pkg.sh <Euclid.app> <version> <out.pkg>
# Installs Euclid.app in /Applications (never relocated to wherever an older copy sits), macOS 14+,
# universal. Signed when INSTALLER_SIGN_IDENTITY ("Developer ID Installer: …") is set; release.sh notarizes.
set -euo pipefail
APP="${1:?app}" VERSION="${2:?version}" PKG="${3:?out.pkg}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/root" "$WORK/packages"
ditto "$APP" "$WORK/root/Euclid.app"
pkgbuild --analyze --root "$WORK/root" "$WORK/component.plist"
plutil -replace 0.BundleIsRelocatable -bool NO "$WORK/component.plist"
pkgbuild --root "$WORK/root" --component-plist "$WORK/component.plist" --install-location /Applications \
  --identifier dev.euclid.Euclid.pkg --version "$VERSION" "$WORK/packages/Euclid.pkg"
cat > "$WORK/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>Euclid</title>
  <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
  <domains enable_localSystem="true"/>
  <volume-check><allowed-os-versions><os-version min="14.0"/></allowed-os-versions></volume-check>
  <choices-outline><line choice="dev.euclid.Euclid.pkg"/></choices-outline>
  <choice id="dev.euclid.Euclid.pkg" visible="false" title="Euclid"><pkg-ref id="dev.euclid.Euclid.pkg"/></choice>
  <pkg-ref id="dev.euclid.Euclid.pkg" version="$VERSION" onConclusion="none">Euclid.pkg</pkg-ref>
</installer-gui-script>
XML
sign=()
[[ -n "${INSTALLER_SIGN_IDENTITY:-}" ]] && sign=(--sign "$INSTALLER_SIGN_IDENTITY" --timestamp)
productbuild --distribution "$WORK/distribution.xml" --package-path "$WORK/packages" ${sign[@]+"${sign[@]}"} "$PKG"
if [[ -n "${INSTALLER_SIGN_IDENTITY:-}" ]]; then
  pkgutil --check-signature "$PKG"
else
  echo "warning: .pkg not signed (set INSTALLER_SIGN_IDENTITY)" >&2
fi
