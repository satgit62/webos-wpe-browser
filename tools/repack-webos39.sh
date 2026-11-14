#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Verwendung: $0 <pfad-zur-original.ipk>"
    echo "Beispiel:   $0 ~/Downloads/org.sostk.wpebrowser_0.3.1_arm.ipk"
    exit 1
fi

INPUT_IPK=$(readlink -f "$1")
if [ ! -f "$INPUT_IPK" ]; then
    echo "Fehler: Datei '$1' nicht gefunden." >&2
    exit 1
fi

NDK="${WEBOS_NDK:-$HOME/arm-webos-linux-gnueabi_sdk-buildroot}"
SYSROOT="$NDK/arm-webos-linux-gnueabi/sysroot"
REPO="${WREN_REPO:-$HOME/webos-wpe-browser}"
SRC="$REPO/engine/webos-backend"

for tool in ar tar patchelf curl wget dpkg-deb; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Fehler: '$tool' fehlt. Bitte installieren." >&2; exit 1; }
done
[ -x "$NDK/bin/arm-webos-linux-gnueabi-gcc" ] || { echo "Fehler: webOS NDK nicht unter $NDK gefunden." >&2; exit 1; }
[ -d "$SRC" ] || { echo "Fehler: Wren-Repository nicht unter $REPO gefunden." >&2; exit 1; }

WORK=$(mktemp -d /tmp/wren-webos39.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

echo "== 1. Original-IPK entpacken =="
mkdir -p "$WORK/ipk" "$WORK/root"
(cd "$WORK/ipk" && ar -x "$INPUT_IPK")
tar -xf "$WORK/ipk/data.tar."* -C "$WORK/root"

APP_DIR="$WORK/root/usr/palm/applications/org.sostk.wpebrowser"
[ -d "$APP_DIR" ] || { echo "Fehler: App-Verzeichnis im IPK nicht gefunden." >&2; exit 1; }

VERSION=$(grep -oE '"version"\s*:\s*"[^"]+"' "$APP_DIR/appinfo.json" | cut -d'"' -f4)
VERSION=${VERSION:-custom}

echo "== 2. GLIBC 2.28 (armel) herunterladen & in engine/lib/ integrieren =="
mkdir -p "$WORK/deb"
H="archive.debian.org"
P="debian/pool/main/g/glibc"
DEB_FILE=$(curl -s "http://${H}/${P}/" | grep -oE 'libc6_2\.28-[^"]+_armel\.deb' | head -n 1)
wget -q "http://${H}/${P}/${DEB_FILE}" -O "$WORK/deb/$DEB_FILE"
dpkg-deb -x "$WORK/deb/$DEB_FILE" "$WORK/deb/extracted"

for so in ld-linux.so.3 libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 libresolv.so.2 libutil.so.1 libanl.so.1 libnsl.so.1 libcrypt.so.1 libnss_files.so.2 libnss_dns.so.2; do
    cp -L "$WORK/deb/extracted/lib/arm-linux-gnueabi/$so" "$APP_DIR/engine/lib/"
done
cp -r "$WORK/deb/extracted/usr/lib/arm-linux-gnueabi/gconv" "$APP_DIR/engine/lib/"
chmod 755 "$APP_DIR/engine/lib/ld-linux.so.3"

echo "== 3. PT_INTERP der Engine-Binaries setzen =="
for exe in "$APP_DIR/engine/wpe-engine" "$APP_DIR"/engine/libexec/*; do
    [ -f "$exe" ] || continue
    patchelf --set-interpreter /tmp/org.sostk.wpebrowser/ld-linux.so.3 "$exe"
done

echo "== 4. libcurl & OpenSSL 1.1 aus dem NDK kopieren =="
for lib in libcurl.so.4 libssl.so.1.1 libcrypto.so.1.1; do
    if [ -f "$SYSROOT/usr/lib/$lib" ]; then
        cp -L "$SYSROOT/usr/lib/$lib" "$APP_DIR/lib/"
        "$NDK/bin/arm-webos-linux-gnueabi-strip" --strip-unneeded "$APP_DIR/lib/$lib"
    fi
done

echo "== 5. Wayland-Backends mit webOS-3.9-Shim neu kompilieren =="
P_WPE="debian/pool/main/libw/libwpe"
WPE_DEB=$(curl -s "http://${H}/${P_WPE}/" | grep -oE 'libwpe-1\.0-dev_[^"]+_armel\.deb' | head -n 1)
wget -q "http://${H}/${P_WPE}/${WPE_DEB}" -O "$WORK/deb/$WPE_DEB"
dpkg-deb -x "$WORK/deb/$WPE_DEB" "$WORK/deb/wpe-dev"

OUT_BE="$WORK/backend"
mkdir -p "$OUT_BE/wpe-link"
ln -sf "$APP_DIR/engine/lib/libwpe-1.0.so.1" "$OUT_BE/wpe-link/libwpe-1.0.so"

"$NDK/bin/wayland-scanner" client-header "$SYSROOT/usr/share/wayland-webos/webos-surface-group.xml" "$OUT_BE/webos-surface-group-client-protocol.h"
"$NDK/bin/wayland-scanner" private-code "$SYSROOT/usr/share/wayland-webos/webos-surface-group.xml" "$OUT_BE/webos-surface-group-protocol.c"
"$NDK/bin/wayland-scanner" client-header "$SYSROOT/usr/share/wayland-webos/webos-foreign.xml" "$OUT_BE/webos-foreign-client-protocol.h"
"$NDK/bin/wayland-scanner" private-code "$SYSROOT/usr/share/wayland-webos/webos-foreign.xml" "$OUT_BE/webos-foreign-protocol.c"
SHELL_XML=$(find "$SYSROOT" "$REPO" -name "webos-shell.xml" | head -n 1)
"$NDK/bin/wayland-scanner" private-code "$SHELL_XML" "$OUT_BE/webos-shell-protocol.c"

cat << 'SHIM_EOF' > "$OUT_BE/wayland_shim.c"
#include <stdarg.h>
#include <stdint.h>
#include <wayland-client.h>

__attribute__((visibility("hidden")))
struct wl_proxy *wl_proxy_marshal_constructor_versioned(struct wl_proxy *proxy,
                                                        uint32_t opcode,
                                                        const struct wl_interface *interface,
                                                        uint32_t version, ...) {
    (void)version;
    va_list ap;
    va_start(ap, version);
    uintptr_t a0 = va_arg(ap, uintptr_t);
    uintptr_t a1 = va_arg(ap, uintptr_t);
    uintptr_t a2 = va_arg(ap, uintptr_t);
    uintptr_t a3 = va_arg(ap, uintptr_t);
    uintptr_t a4 = va_arg(ap, uintptr_t);
    uintptr_t a5 = va_arg(ap, uintptr_t);
    va_end(ap);
    return wl_proxy_marshal_constructor(proxy, opcode, interface, a0, a1, a2, a3, a4, a5);
}
SHIM_EOF

"$NDK/bin/arm-webos-linux-gnueabi-gcc" -shared -fPIC -O2 -g0 -Wall -Wextra -Werror -std=gnu11 \
    -fvisibility=hidden -Wl,-soname,libwpeb-owner.so -Wl,--no-undefined -Wl,--as-needed \
    -I"$OUT_BE" -I"$SRC" -o "$APP_DIR/engine/lib/libwpeb-owner.so" \
    "$SRC/owner.c" "$OUT_BE/webos-surface-group-protocol.c" "$OUT_BE/wayland_shim.c" -lwayland-client

"$NDK/bin/arm-webos-linux-gnueabi-gcc" -shared -fPIC -O2 -g0 -Wall -Wextra -Werror -std=gnu11 \
    -fvisibility=hidden -Wl,-soname,libWPEBackend-webos.so -Wl,--no-undefined -Wl,--as-needed \
    -I"$OUT_BE" -I"$SRC" -I"$WORK/deb/wpe-dev/usr/include/wpe-1.0" \
    $(PKG_CONFIG_SYSROOT_DIR=$SYSROOT PKG_CONFIG_LIBDIR=$SYSROOT/usr/lib/pkgconfig pkg-config --cflags glib-2.0) \
    -o "$APP_DIR/engine/lib/libWPEBackend-webos.so" \
    "$SRC/wpebackend-webos.c" "$OUT_BE/webos-surface-group-protocol.c" "$OUT_BE/webos-shell-protocol.c" "$OUT_BE/webos-foreign-protocol.c" "$OUT_BE/wayland_shim.c" \
    -L"$OUT_BE/wpe-link" -lwpe-1.0 -lwayland-client -lwayland-egl -lglib-2.0 -ldl

"$NDK/bin/arm-webos-linux-gnueabi-strip" --strip-unneeded "$APP_DIR/engine/lib/libwpeb-owner.so" "$APP_DIR/engine/lib/libWPEBackend-webos.so"

echo "== 6. Neues webOS-3.9-IPK packen =="
mkdir -p "$WORK/pkg/control"
SIZE=$(du -sk "$WORK/root" | cut -f1)
cat << CTRL_EOF > "$WORK/pkg/control/control"
Package: org.sostk.wpebrowser
Version: ${VERSION}
Section: misc
Priority: optional
Architecture: arm
Installed-Size: ${SIZE}
Maintainer: Wren webOS 3.9 Custom Build
Description: Wren WPE WebKit Browser adapted for webOS 3.9
CTRL_EOF

printf "2.0\n" > "$WORK/pkg/debian-binary"
tar --format=gnu -czf "$WORK/pkg/control.tar.gz" -C "$WORK/pkg/control" control
tar --format=gnu -czf "$WORK/pkg/data.tar.gz" -C "$WORK/root" usr

OUT_IPK="$HOME/org.sostk.wpebrowser_${VERSION}-webos39_arm.ipk"
rm -f "$OUT_IPK"
(cd "$WORK/pkg" && ar -rU "$OUT_IPK" debian-binary control.tar.gz data.tar.gz)

echo "== FERTIG: $OUT_IPK =="
