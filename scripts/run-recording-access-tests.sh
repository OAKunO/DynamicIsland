#!/bin/zsh
set -euo pipefail
source "${0:A:h}/swift-test-common.sh"
readonly output_directory="${project_root}/.derivedData/RecordingAccessTests"
compile_swift_test "$output_directory" RecordingAccessIntegration \
    -default-isolation MainActor \
    "${view_test_sources[@]}" "${project_root}/Tests/RecordingAccessIntegration.swift"
"${output_directory}/RecordingAccessIntegration"
