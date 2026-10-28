#!/bin/zsh
set -euo pipefail
source "${0:A:h}/swift-test-common.sh"
readonly output_directory="${project_root}/.derivedData/PagingUI"
compile_swift_test "$output_directory" ExpandedPagingUIRender \
    -default-isolation MainActor \
    "${view_test_sources[@]}" "${project_root}/Tests/ExpandedPagingUIRender.swift"
"${output_directory}/ExpandedPagingUIRender" "${output_directory}/screenshots"
