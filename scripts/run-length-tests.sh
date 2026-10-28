#!/bin/zsh
set -euo pipefail

source "${0:A:h}/swift-test-common.sh"
readonly output_directory="${project_root}/.derivedData/LengthTests"
readonly executable="${output_directory}/IslandLengthSettingsIntegration"

compile_swift_test "$output_directory" IslandLengthSettingsIntegration \
    -default-isolation MainActor \
    "${layout_test_sources[@]}" \
    "${project_root}/Tests/IslandLengthSettingsIntegration.swift"
"${executable}"
