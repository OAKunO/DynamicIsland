#!/bin/zsh
set -euo pipefail
source "${0:A:h}/swift-test-common.sh"
readonly output_directory="${project_root}/.derivedData/CodexTests"
compile_swift_test "$output_directory" CodexAppStatusIntegration \
    "${project_root}/DynamicIsland/CodexTaskSnapshot.swift" \
    "${project_root}/DynamicIsland/CodexAppStatusReader.swift" \
    "${project_root}/DynamicIsland/CodexSessionReader.swift" \
    "${project_root}/Tests/CodexAppStatusIntegration.swift" \
    "${project_root}/Tests/CodexRecoveryIntegration.swift"
"${output_directory}/CodexAppStatusIntegration" "$@"
