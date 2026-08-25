#!/bin/bash
#
# Create a stable local code-signing identity, so macOS permission grants survive
# rebuilds.
#
# WHY THIS IS NOT OPTIONAL
#
# `swift build` and a bare `codesign --sign -` produce an *ad-hoc* signature. An
# ad-hoc signature has no certificate, so the designated requirement macOS derives
# from it is:
#
#     cdhash H"<hash of this exact binary>"
#
# That hash changes on every single build. TCC — the database behind the Privacy &
# Security panes — stores grants against the designated requirement, so every rebuild
# produces an application macOS has never seen before, and Accessibility, Input
# Monitoring and Microphone all silently revert.
#
# The failure mode is genuinely awful to diagnose, because the Privacy pane keeps
# listing the app with its switch ON while the API that actually gates the feature
# (`AXIsProcessTrusted`, `CGPreflightListenEventAccess`) returns false. The pane is
# describing a stored row; the API is describing *this* binary. Both are telling the
# truth, and the UI offers nothing to reconcile them — toggling the switch does not
# help, because the row was never the problem.
#
# With a certificate, the requirement becomes:
#
#     identifier "com.robertnowell.voice-dispatch" and certificate leaf = H"..."
#
# which is stable for as long as the certificate exists. Grant once, rebuild freely.
#
# An Apple Development certificate does the same job and is preferable if you have
# one — but it requires full Xcode, and this project otherwise builds with only the
# Command Line Tools. This script keeps that true.
#
# Usage: scripts/make-signing-identity.sh
#        Idempotent. Safe to re-run; it skips the work if the identity already exists.

set -euo pipefail

# Overridable so the create-from-nothing path can actually be exercised without
# rotating the real certificate — rotating it would void every macOS permission grant,
# which makes the honest test otherwise too expensive to run.
CN="${VD_SIGN_CN:-Voice Dispatch Local Signing}"
KEYCHAIN="${VD_SIGN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

existing=$(security find-identity -p codesigning 2>/dev/null | grep "$CN" || true)
if [ -n "$existing" ]; then
  echo "already present:"
  echo "  $(echo "$existing" | sed -E 's/^ *//')"
  echo
  echo "Nothing to do. scripts/bundle.sh will find and use it."
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# macOS ships LibreSSL, which has no -addext, so the extensions go in a config file.
# The codeSigning EKU is required: without it codesign refuses the identity.
#
# /usr/bin/openssl BY ABSOLUTE PATH, not whatever `openssl` resolves to. Measured
# 25 Aug on a machine with Homebrew first on PATH: OpenSSL 3.x writes PKCS#8 from
# `openssl rsa` regardless of the conversion below (it needs an explicit
# -traditional), and `security import -f openssl` rejects that with
#   security: SecKeychainItemImport: Unknown format in import.
# bundle.sh calls this script with `|| true`, so the failure was SILENT and the
# build fell through to ad-hoc signing -- the exact outcome the header above says
# is unusable. The script had always ASSUMED /usr/bin/openssl (see "macOS ships
# LibreSSL"); it just never said so where it mattered. LibreSSL predates the
# PKCS#8 default and writes traditional RSA, so pinning the path is the whole fix.
cat > "$WORK/req.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[ dn ]
CN = $CN
[ v3 ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
subjectKeyIdentifier   = hash
CNF

/usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -config "$WORK/req.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# Imported as two items rather than one PKCS#12 on purpose. macOS `security import`
# cannot verify the MAC on a PKCS#12 written by LibreSSL ("MAC verification failed"),
# and `openssl req` emits a PKCS#8 key that `security` reports as "Unknown format" —
# so the key is converted to traditional RSA PEM first.
/usr/bin/openssl rsa -in "$WORK/key.pem" -out "$WORK/key-trad.pem"

# -T /usr/bin/codesign -A: pre-authorise codesign to use the key, so signing never
# stops to ask for the login password. Without it every build blocks on a dialog.
security import "$WORK/key-trad.pem" -k "$KEYCHAIN" -f openssl -T /usr/bin/codesign -A >/dev/null
security import "$WORK/cert.pem"     -k "$KEYCHAIN"            -T /usr/bin/codesign -A >/dev/null

line=$(security find-identity -p codesigning 2>/dev/null | grep "$CN" || true)
if [ -z "$line" ]; then
  echo "import succeeded but no identity appeared — stopping rather than guessing." >&2
  exit 1
fi
HASH=$(echo "$line" | sed -E 's/^ *[0-9]+\) ([0-9A-F]+) .*/\1/')

echo "created: $CN"
echo "  sha1: $HASH"
echo
# The certificate is deliberately left UNTRUSTED. codesign signs with it regardless,
# and trusting a self-signed root is a system-wide change this project does not need.
echo "It reports CSSMERR_TP_NOT_TRUSTED, which is expected and harmless: the"
echo "certificate is not trusted for verifying other people's code, but codesign"
echo "signs with it, and that is all we need. No system trust store was modified."
echo
echo "Next:"
echo "  scripts/bundle.sh                     # picks this up automatically"
echo "  scripts/reset-permissions.sh          # clear grants bound to the old identity"
