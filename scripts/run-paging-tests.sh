#!/bin/zsh
set -euo pipefail
source "${0:A:h}/swift-test-common.sh"
readonly output_directory="${project_root}/.derivedData/PagingTests"
compile_swift_test "$output_directory" ExpandedPagingIntegration \
    -default-isolation MainActor \
    "${layout_test_sources[@]}" \
    "${project_root}/Tests/ExpandedPagingIntegration.swift"
"${output_directory}/ExpandedPagingIntegration"
