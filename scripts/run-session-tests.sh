#!/bin/zsh
set -euo pipefail
source "${0:A:h}/swift-test-common.sh"
readonly output_directory="${project_root}/.derivedData/SessionTests"
compile_swift_test "$output_directory" SessionRecoveryIntegration \
    -default-isolation MainActor \
    "${project_root}/DynamicIsland/IslandSessionMonitor.swift" \
    "${project_root}/Tests/SessionRecoveryIntegration.swift"
"${output_directory}/SessionRecoveryIntegration"
