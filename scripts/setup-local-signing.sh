#!/bin/zsh
set -euo pipefail
umask 077
readonly project_root="${0:A:h:h}"
source "${project_root}/scripts/local-signing-common.sh"
readonly signing_keychain="${HOME}/Library/Keychains/login.keychain-db"

if signing_identity_hash >/dev/null 2>&1; then
    print '已存在固定签名证书，继续复用，不创建新证书。'
    exit 0
fi

if /usr/bin/security find-certificate -c "$signing_identity_name" "$signing_keychain" >/dev/null 2>&1; then
    print -u2 '同名证书已存在，但私钥不可用或证书未通过代码签名验证。'
    print -u2 '请在钥匙串访问中修复现有身份；为避免身份变化，不自动重新生成。'
    exit 1
fi

signing_temporary=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp/}dynamicisland-signing.XXXXXX")
readonly signing_temporary
trap '/bin/rm -rf -- "$signing_temporary"' EXIT
cat > "${signing_temporary}/certificate.conf" <<'CONF'
[req]
prompt = no
distinguished_name = subject
x509_extensions = code_signing
[subject]
CN = DynamicIsland Local Development
O = DynamicIsland Local Development
[code_signing]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
CONF

# The temporary private key is owner-readable only, then imported as
# non-extractable. The trap removes temporary material even on failure.
/usr/bin/openssl genrsa -out "${signing_temporary}/private-key.pem" 3072
/usr/bin/openssl req -new -x509 -sha256 -days 3650 \
    -key "${signing_temporary}/private-key.pem" \
    -config "${signing_temporary}/certificate.conf" \
    -out "${signing_temporary}/certificate.pem"
/usr/bin/security import "${signing_temporary}/certificate.pem" \
    -k "$signing_keychain" -t cert -f pemseq
/usr/bin/security import "${signing_temporary}/private-key.pem" \
    -k "$signing_keychain" -t priv -f openssl -x -T /usr/bin/codesign
# User-domain trust is limited to code signing; no TLS or system trust changes.
/usr/bin/security add-trusted-cert -r trustRoot -p codeSign \
    -k "$signing_keychain" "${signing_temporary}/certificate.pem"
signing_identity_hash >/dev/null
print '固定代码签名证书已保存在登录钥匙串；临时私钥文件将被清理。'
