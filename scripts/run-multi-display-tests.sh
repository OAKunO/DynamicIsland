#!/bin/zsh
set -euo pipefail
source "${0:A:h}/swift-test-common.sh"
readonly output_directory="${project_root}/.derivedData/MultiDisplayTests"
compile_swift_test "$output_directory" MultiDisplayIntegration \
    -default-isolation MainActor \
    "${view_test_sources[@]}" \
    "${project_root}/Tests/MultiDisplayIntegration.swift"
"${output_directory}/MultiDisplayIntegration" "${output_directory}/screenshots"
