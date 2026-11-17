#!/bin/bash
# Compila o PadProbe (armv7, iOS 8) e instala em /Applications do iPad via SSH.
# O app precisa ficar em /Applications (fora do sandbox) para falar com o BTdaemon.
#
# Uso:  ./build.sh            -> só compila (gera build/PadProbe.app)
#       ./build.sh install    -> compila e instala no iPad
#
# Variáveis: IPAD=192.168.1.105 (IP do iPad), X13=.../Xcode-13.4.1.app/Contents/Developer
set -euo pipefail
cd "$(dirname "$0")"

APP=PadProbe
IPAD="${IPAD:-192.168.1.105}"
SSH_OPTS=(-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa
          -o KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1)
ROOT="$(cd .. && pwd)"
X13="${X13:-$ROOT/Xcode-13.4.1.app/Contents/Developer}"
TC="$X13/Toolchains/XcodeDefault.xctoolchain/usr/bin"
SDK="$(ls -d "$X13"/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS*.sdk 2>/dev/null | head -1 || true)"

if [ ! -x "$TC/clang" ] || [ -z "$SDK" ]; then
    echo "Toolchain do Xcode 13 não encontrado em: $X13" >&2
    exit 1
fi

# libBTstack.dylib vem do próprio iPad (pacote ch.ringwald.btstack 1.1-1)
if [ ! -s vendor/libBTstack.dylib ]; then
    echo "==> Baixando /usr/lib/libBTstack.dylib do iPad ($IPAD)"
    ssh "${SSH_OPTS[@]}" "root@$IPAD" 'cat /usr/lib/libBTstack.dylib' > vendor/libBTstack.dylib.tmp || true
    if [ ! -s vendor/libBTstack.dylib.tmp ]; then
        echo "Não consegui copiar a libBTstack.dylib do iPad (confira o IP e o SSH)." >&2
        exit 1
    fi
    mv -f vendor/libBTstack.dylib.tmp vendor/libBTstack.dylib
fi
echo "==> libBTstack.dylib: $(wc -c < vendor/libBTstack.dylib | tr -d ' ') bytes ($(lipo -info vendor/libBTstack.dylib 2>/dev/null | sed 's/.*: //'))"
python3 tools/make_link_stub.py vendor/libBTstack.dylib vendor/libBTstackLink.dylib

export DEVELOPER_DIR="$X13"
OUT="build/$APP.app"
rm -rf build && mkdir -p "$OUT"

echo "==> Compilando (armv7, iOS 8.0)"
"$TC/clang" -arch armv7 -isysroot "$SDK" -miphoneos-version-min=8.0 -B "$TC" \
    -fobjc-arc -O2 -Wall -Wno-unused-parameter -Wunguarded-availability \
    -I vendor/btstack src/main.m -o "$OUT/$APP" \
    -L vendor -lBTstackLink \
    -framework Foundation -framework UIKit -framework CoreGraphics -framework QuartzCore

cp Info.plist "$OUT/"
cp resources/*.png "$OUT/"
if command -v ldid >/dev/null 2>&1; then ldid -S "$OUT/$APP"; else codesign -f -s - "$OUT/$APP"; fi
lipo -info "$OUT/$APP"
echo "==> OK: $OUT"

if [ "${1:-}" = "install" ]; then
    echo "==> Instalando em /Applications/$APP.app (senha: alpine)"
    tar -C build -cf - "$APP.app" | ssh "${SSH_OPTS[@]}" "root@$IPAD" \
        "rm -rf /Applications/$APP.app && tar -C /Applications -xf - && chown -R root:wheel /Applications/$APP.app && chmod -R 755 /Applications/$APP.app && (su mobile -c uicache || uicache)"
    echo "==> Instalado. Se o ícone não aparecer, faça um respring."
fi
