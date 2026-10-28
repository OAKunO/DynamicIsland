#!/bin/zsh
set -euo pipefail
source "${0:A:h}/swift-test-common.sh"
readonly output_directory="${project_root}/.derivedData/NotchUI"
compile_swift_test "$output_directory" IslandNotchUIRender \
    -default-isolation MainActor \
    "${view_test_sources[@]}" "${project_root}/Tests/IslandNotchUIRender.swift"
"${output_directory}/IslandNotchUIRender" "${output_directory}/screenshots"
