#!/bin/zsh
# Compila Eco.app (Swift Package + bundle de app firmado ad hoc).
set -e
cd "$(dirname "$0")"
swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)
APP="Eco.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Eco" "$APP/Contents/MacOS/"
cp Eco.icns "$APP/Contents/Resources/"
for b in "$BIN"/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Eco</string>
  <key>CFBundleIdentifier</key><string>local.eco</string>
  <key>CFBundleIconFile</key><string>Eco</string>
  <key>CFBundleName</key><string>Eco</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.2</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSMicrophoneUsageDescription</key><string>Para transcribir lo que dices en la llamada.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Para transcribir la llamada en tu Mac.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Para saber qué reunión estás grabando y quiénes están invitados.</string>
  <key>NSAppleEventsUsageDescription</key><string>Para guardar tus llamadas en la app Notas.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Firma con un certificado fijo para que macOS recuerde los permisos entre compilaciones.
# Usa el primer "Apple Development" del llavero (o ECO_SIGN); si no hay, firma ad hoc.
SIGN="${ECO_SIGN:-Apple Development}"
if security find-identity -v -p codesigning | grep -q "$SIGN"; then
  codesign --force --sign "$SIGN" "$APP"
else
  echo "Aviso: no hay certificado '$SIGN'; firmo ad hoc (macOS pedirá permisos de nuevo tras cada compilación)."
  codesign --force --sign - "$APP"
fi
echo "Listo: $PWD/$APP"
