#!/usr/bin/env bash
set -euo pipefail

identity="${NARWHAL_SIGNING_IDENTITY:-Narwhal Local Code Signing}"
keychain="${NARWHAL_CODESIGN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/narwhal-codesign.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

if security find-identity -v -p codesigning | grep -F "\"$identity\"" >/dev/null; then
  echo "Code-signing identity already exists: $identity"
  exit 0
fi

openssl_config="$tmp_dir/openssl.cnf"
key_path="$tmp_dir/narwhal-local-codesign.key"
cert_path="$tmp_dir/narwhal-local-codesign.crt"
p12_path="$tmp_dir/narwhal-local-codesign.p12"

cat >"$openssl_config" <<EOF
[ req ]
default_bits = 2048
prompt = no
distinguished_name = subject
x509_extensions = extensions

[ subject ]
CN = $identity

[ extensions ]
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyCertSign,cRLSign
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

openssl req \
  -new \
  -newkey rsa:2048 \
  -x509 \
  -sha256 \
  -days 3650 \
  -nodes \
  -config "$openssl_config" \
  -keyout "$key_path" \
  -out "$cert_path" >/dev/null 2>&1

openssl pkcs12 \
  -export \
  -inkey "$key_path" \
  -in "$cert_path" \
  -name "$identity" \
  -passout pass: \
  -out "$p12_path" >/dev/null 2>&1

security import "$p12_path" \
  -k "$keychain" \
  -P "" \
  -T /usr/bin/codesign >/dev/null

security add-trusted-cert \
  -r trustRoot \
  -p codeSign \
  -k "$keychain" \
  "$cert_path" >/dev/null

if ! security find-identity -v -p codesigning | grep -F "\"$identity\"" >/dev/null; then
  echo "Created certificate but codesign does not list it as a valid identity: $identity" >&2
  exit 1
fi

cat <<EOF
Created local code-signing identity: $identity

Use it for stable Narwhal Accessibility trust:
  export NARWHAL_SIGNING_IDENTITY="$identity"
EOF
