#!/bin/zsh
set -euo pipefail
source "${0:A:h}/swift-test-common.sh"
readonly output_directory="${project_root}/.derivedData/ProcessTests"
compile_swift_test "$output_directory" ProcessRunnerIntegration \
    "${project_root}/DynamicIsland/ProcessRunner.swift" \
    "${project_root}/Tests/ProcessRunnerIntegration.swift"
"${output_directory}/ProcessRunnerIntegration"
