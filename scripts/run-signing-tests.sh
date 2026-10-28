#!/bin/zsh
set -euo pipefail
readonly project_root="${0:A:h:h}"
source "${project_root}/scripts/local-signing-common.sh"
identity_hash=$(signing_identity_hash)
readonly identity_hash
mkdir -p "${project_root}/.derivedData/SigningTests"
signing_test_directory=$(/usr/bin/mktemp -d "${project_root}/.derivedData/SigningTests/run.XXXXXX")
readonly signing_test_directory
trap '/bin/rm -rf -- "$signing_test_directory"' EXIT

make_fixture() {
    local app_path="$1" bundle_id="$2" version="$3"
    mkdir -p "${app_path}/Contents/MacOS"
    cat > "${app_path}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${bundle_id}</string>
<key>CFBundleExecutable</key><string>DynamicIsland</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>${version}</string>
</dict></plist>
PLIST
    print -r -- "#include <stdio.h>
int main(void) { puts(\"signing test ${version}\"); return 0; }" |
        /usr/bin/xcrun clang -x c - -o "${app_path}/Contents/MacOS/DynamicIsland"
    /usr/bin/codesign --force --sign "$identity_hash" --timestamp=none "$app_path"
}

readonly first_app="${signing_test_directory}/First.app"
readonly updated_app="${signing_test_directory}/Updated.app"
readonly other_app="${signing_test_directory}/Other.app"
make_fixture "$first_app" "$signing_bundle_id" 1
make_fixture "$updated_app" "$signing_bundle_id" 2
make_fixture "$other_app" 'OAKunO.DynamicIsland.Unrelated' 3

first_requirement=$(/usr/bin/codesign -d -r - "$first_app" 2>&1 |
    /usr/bin/awk '/designated => / { sub(/^.*designated => /, ""); print }')
updated_requirement=$(/usr/bin/codesign -d -r - "$updated_app" 2>&1 |
    /usr/bin/awk '/designated => / { sub(/^.*designated => /, ""); print }')
first_hash=$(/usr/bin/codesign -dv --verbose=4 "$first_app" 2>&1 | /usr/bin/awk -F= '/^CDHash=/ { print $2 }')
updated_hash=$(/usr/bin/codesign -dv --verbose=4 "$updated_app" 2>&1 | /usr/bin/awk -F= '/^CDHash=/ { print $2 }')
[[ -n "$first_hash" && "$first_hash" != "$updated_hash" ]]
[[ -n "$first_requirement" && "$first_requirement" == "$updated_requirement" ]]
[[ "$first_requirement" != *cdhash* ]]
/usr/bin/codesign --verify --strict -R "=${first_requirement}" "$updated_app"
/usr/bin/codesign --verify --strict -R "=${updated_requirement}" "$first_app"
zsh "${project_root}/scripts/verify-app-signature.sh" "$first_app"
zsh "${project_root}/scripts/verify-app-signature.sh" "$updated_app"
if /usr/bin/codesign --verify --strict -R "=${first_requirement}" "$other_app" >/dev/null 2>&1; then
    print -u2 'FAIL: unrelated Bundle ID satisfied the application requirement'; exit 1
fi
/usr/bin/codesign --force --sign - "$updated_app"
if zsh "${project_root}/scripts/verify-app-signature.sh" "$updated_app" >/dev/null 2>&1; then
    print -u2 'FAIL: ad-hoc signature was accepted'; exit 1
fi
print 'tampered' >> "${first_app}/Contents/MacOS/DynamicIsland"
if zsh "${project_root}/scripts/verify-app-signature.sh" "$first_app" >/dev/null 2>&1; then
    print -u2 'FAIL: modified executable was accepted'; exit 1
fi
print 'PASS: different builds retain the same certificate-based identity; cross-version checks pass; unrelated, ad-hoc and modified apps are rejected.'
