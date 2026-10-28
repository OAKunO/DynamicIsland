#!/bin/zsh
# Shared public configuration. Private signing material belongs in Keychain.
readonly signing_identity_name="DynamicIsland Local Development"
readonly signing_bundle_id="OAKunO.DynamicIsland"

signing_identity_hash() {
    local identity_hash
    identity_hash=$(/usr/bin/security find-identity -v -p codesigning |
        /usr/bin/awk '/"DynamicIsland Local Development"$/ { print $2 }')
    if [[ ! "$identity_hash" =~ '^[[:xdigit:]]{40}$' ]]; then
        print -u2 '需要唯一且有效的 DynamicIsland Local Development 签名证书。'
        print -u2 '请先运行 zsh scripts/setup-local-signing.sh；不会回退到临时签名。'
        return 1
    fi
    print -r -- "$identity_hash"
}
