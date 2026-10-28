#!/bin/zsh
set -euo pipefail
source "${0:A:h}/swift-test-common.sh"
readonly output_directory="${project_root}/.derivedData/TimeTests"
compile_swift_test "$output_directory" TimeToolsIntegration \
    -default-isolation MainActor \
    "${model_test_sources[@]}" \
    "${layout_test_sources[@]}" \
    "${project_root}/Tests/TimeToolsIntegration.swift"
"${output_directory}/TimeToolsIntegration"
