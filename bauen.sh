#!/bin/zsh
# Baut Queet.app (Apple-Chip und Intel).
#   ./bauen.sh              in /Applications installieren und still neu starten
#   ./bauen.sh dmg [Datei]  Queet.dmg zum Weitergeben
# Signatur: ist QUEET_SIGNATUR gesetzt (z. B. in lokal.sh), mit diesem Zertifikat, sonst ad hoc.
# Mit festem Zertifikat bleibt die Freigabe unter Bedienungshilfen nach einem Neubau erhalten.
set -e; cd "${0:a:h}"
[[ -f lokal.sh ]] && source ./lokal.sh
B=~/Library/Caches/Queet-Bau; A=$B/Queet.app
rm -rf $B; mkdir -p $A/Contents/MacOS $A/Contents/Resources
cp Info.plist $A/Contents/
# Symbol mit hellem und dunklem Aussehen
xcrun actool Symbol.icon --compile $A/Contents/Resources --platform macosx --minimum-deployment-target 14.0 \
  --app-icon Symbol --output-partial-info-plist $B/icon.plist >/dev/null
for arch in arm64 x86_64; do
  swiftc -O -target $arch-apple-macos14.0 main.swift Einstellungen.swift Stil.swift -o $B/queet-$arch
done
lipo -create $B/queet-arm64 $B/queet-x86_64 -output $A/Contents/MacOS/queet
K=(); [[ -n $QUEET_SCHLUESSELBUND ]] && K=(--keychain $QUEET_SCHLUESSELBUND)
codesign --force -s "${QUEET_SIGNATUR:--}" $K $A

if [[ "$1" == dmg ]]; then
  Z="${2:-$PWD/Queet.dmg}"; S=$B/dmg; mkdir -p $S
  cp -R $A $S/; ln -s /Applications $S/Programme
  rm -f "$Z"; hdiutil create -volname Queet -srcfolder $S -fs HFS+ -format UDZO -ov "$Z" >/dev/null
  echo "$Z"; exit 0
fi
# Laufenden Helfer beenden, ersetzen (nicht überschreiben: sonst beendet macOS ihn wegen
# ungültiger Signatur) und ohne Fenster neu starten
pkill -x queet 2>/dev/null || true
rm -rf /Applications/Queet.app; ditto $A /Applications/Queet.app
open -g /Applications/Queet.app --args --still
