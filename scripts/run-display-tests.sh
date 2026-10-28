#!/bin/zsh
set -euo pipefail
source "${0:A:h}/swift-test-common.sh"
readonly output_directory="${project_root}/.derivedData/DisplayTests"
compile_swift_test "$output_directory" IslandDisplaySettingsIntegration \
    -default-isolation MainActor \
    "${layout_test_sources[@]}" \
    "${model_test_sources[@]}" \
    "${project_root}/Tests/IslandDisplaySettingsIntegration.swift"
"${output_directory}/IslandDisplaySettingsIntegration"
