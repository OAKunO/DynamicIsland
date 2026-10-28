#!/bin/zsh
set -euo pipefail
readonly project_root="${0:A:h:h}"
source "${project_root}/scripts/local-signing-common.sh"
readonly signed_app="${1:?用法：verify-app-signature.sh /path/to/DynamicIsland.app}"
identity_hash=$(signing_identity_hash)
readonly identity_hash
readonly bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${signed_app}/Contents/Info.plist")
[[ "$bundle_id" == "$signing_bundle_id" ]] || { print -u2 'Bundle ID 不匹配，拒绝此应用。'; exit 1; }

# Require the exact certificate, rather than trusting the name or Bundle ID alone.
/usr/bin/codesign --verify --deep --strict \
    -R "=identifier \"${signing_bundle_id}\" and certificate leaf = H\"${identity_hash}\"" \
    "$signed_app"
readonly designated_requirement=$(/usr/bin/codesign -d -r - "$signed_app" 2>&1)
[[ "$designated_requirement" != *cdhash* ]] || { print -u2 '仍是随构建变化的临时签名身份，拒绝安装。'; exit 1; }
print "PASS: ${signing_bundle_id} 使用固定证书，完整签名验证通过。"
