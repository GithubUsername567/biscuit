#!/bin/zsh
# Sign Biscuit with the stable self-signed identity so macOS keeps its
# permission grants across rebuilds (ad-hoc signing changes identity every
# build, which silently revokes Accessibility / Screen Recording / Input
# Monitoring). Run after copying the build into /Applications.
#
# One-time cert creation (already done once):
#   openssl req -x509 -newkey rsa:2048 -nodes -keyout biscuit.key -out biscuit.crt \
#     -days 3650 -config biscuit-cert.conf
#   openssl pkcs12 -export -out biscuit.p12 -inkey biscuit.key -in biscuit.crt \
#     -passout pass:biscuit -name "Biscuit Local Signing" -legacy \
#     -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
#   security import biscuit.p12 -k ~/Library/Keychains/login.keychain-db \
#     -P biscuit -T /usr/bin/codesign -A

APP="${1:-/Applications/NotchAssistant.app}"
codesign --force --deep --sign "Biscuit Local Signing" --identifier com.local.NotchAssistant "$APP"
codesign -dvvv "$APP" 2>&1 | grep -E "Authority|Identifier=" | head -2
