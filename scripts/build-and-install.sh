#!/bin/zsh
set -euo pipefail
readonly project_root="${0:A:h:h}"
source "${project_root}/scripts/local-signing-common.sh"
identity_hash=$(signing_identity_hash)
readonly identity_hash
readonly build_directory="${project_root}/.derivedData/LocalSignedBuild"
readonly built_app="${build_directory}/Build/Products/Release/DynamicIsland.app"
readonly installed_app="/Applications/DynamicIsland.app"
readonly launch_services_tool='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
readonly install_requested="${1:-}"
[[ -z "$install_requested" || "$install_requested" == --install ]] || {
    print -u2 '用法：zsh scripts/build-and-install.sh [--install]'; exit 1
}
mkdir -p "$build_directory"
# Serialize the entire build/install operation across chats and terminals.
# The descriptor lock is released automatically on exit, including failures.
zmodload zsh/system
: >> "${build_directory}/operation.lock"
integer signing_lock_fd
if ! zsystem flock -t 60 -f signing_lock_fd "${build_directory}/operation.lock"; then
    print -u2 '另一个构建/安装仍在进行，请稍后重试。'
    exit 1
fi
if ! /usr/bin/xcodebuild -project "${project_root}/DynamicIsland.xcodeproj" \
    -scheme DynamicIsland -configuration Release -destination 'platform=macOS' \
    -derivedDataPath "$build_directory" \
    CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$identity_hash" build > "${build_directory}/build.log" 2>&1; then
    /usr/bin/tail -n 70 "${build_directory}/build.log"
    exit 1
fi
zsh "${project_root}/scripts/verify-app-signature.sh" "$built_app"
# Xcode registers its build product as an app. Keep the installed copy as the
# only launchable registration, so old build products do not appear beside it.
# An incremental build may already be unregistered; lsregister returns an error
# for that harmless case, which must not fail the signed build.
"$launch_services_tool" -u "$built_app" >/dev/null 2>&1 || true
if [[ -z "$install_requested" ]]; then
    print "签名构建完成：${built_app}"
    exit 0
fi

# Never replace files underneath a live process: its old in-memory identity
# would disagree with the newly installed signature.
if /usr/bin/pgrep -f '^/Applications/DynamicIsland.app/Contents/MacOS/DynamicIsland([[:space:]]|$)' >/dev/null; then
    print -u2 '应用仍在运行。请先退出灵动岛，再运行同一条 --install 命令。'
    exit 1
fi
readonly install_stamp=$(/bin/date '+%Y%m%d-%H%M%S')-$$
readonly backup_app="${project_root}/.derivedData/AppBackups/${install_stamp}/DynamicIsland.app"
readonly staging_app="/Applications/.DynamicIsland-${install_stamp}.app"
readonly previous_app="/Applications/.DynamicIsland-previous-${install_stamp}.app"
if [[ -e "$installed_app" ]]; then
    mkdir -p "${backup_app:h}"
    /usr/bin/ditto "$installed_app" "$backup_app"
fi
cleanup_install() {
    if [[ -e "$previous_app" ]]; then
        if [[ ! -e "$installed_app" ]]; then /bin/mv "$previous_app" "$installed_app"; fi
    fi
    [[ ! -e "$staging_app" ]] || /bin/rm -rf -- "$staging_app"
}
trap cleanup_install EXIT
/usr/bin/ditto "$built_app" "$staging_app"
zsh "${project_root}/scripts/verify-app-signature.sh" "$staging_app"
if [[ -e "$installed_app" ]]; then /bin/mv "$installed_app" "$previous_app"; fi
/bin/mv "$staging_app" "$installed_app"
if ! zsh "${project_root}/scripts/verify-app-signature.sh" "$installed_app"; then
    /bin/mv "$installed_app" "$staging_app"
    exit 1
fi
"$launch_services_tool" -f "$installed_app"
[[ ! -e "$previous_app" ]] || /bin/rm -rf -- "$previous_app"
print "固定签名版本已安装：${installed_app}"
[[ ! -e "$backup_app" ]] || print "旧版本备份：${backup_app}"
