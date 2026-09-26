#!/bin/zsh
# Собирает vendor/aria2c — универсальный (Apple Silicon + Intel), только на системных библиотеках macOS.
# Готового aria2c для Mac нет, а Homebrew-версии нужны свои библиотеки. TLS — системный (AppleTLS),
# без c-ares (DNS системный: встроенный на macOS не находит серверы), без XML и SQLite: торренты и
# файлы по ссылкам этого не требуют. Лицензия aria2 — GPL 2, исходники: github.com/aria2/aria2.
set -euo pipefail
VER=1.37.0
WORK=$(mktemp -d)
cd "$WORK"
curl -sL -o aria2.tar.xz "https://github.com/aria2/aria2/releases/download/release-$VER/aria2-$VER.tar.xz"
for arch in arm64 x86_64; do
  mkdir $arch && tar xf aria2.tar.xz -C $arch
  (cd $arch/aria2-$VER && ./configure --host=$([[ $arch == arm64 ]] && echo aarch64 || echo x86_64)-apple-darwin \
    CC="clang -arch $arch" CXX="clang++ -arch $arch" \
    CFLAGS="-O2 -mmacosx-version-min=14.0" CXXFLAGS="-O2 -mmacosx-version-min=14.0" LDFLAGS="-mmacosx-version-min=14.0" \
    PKG_CONFIG=false --with-appletls --without-openssl --without-gnutls --without-libgcrypt --without-libnettle \
    --without-libgmp --without-libssh2 --without-libcares --without-libxml2 --without-libexpat --without-sqlite3 \
    --disable-nls --disable-metalink --disable-websocket >/dev/null && make -j8 >/dev/null)
done
lipo -create arm64/aria2-$VER/src/aria2c x86_64/aria2-$VER/src/aria2c -output "$OLDPWD/aria2c"
rm -rf "$WORK"
echo "Готово: vendor/aria2c"
