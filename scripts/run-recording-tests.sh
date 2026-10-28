#!/bin/zsh
set -euo pipefail
source "${0:A:h}/swift-test-common.sh"
readonly output_directory="${project_root}/.derivedData/RecordingTests"
compile_swift_test "$output_directory" RecordingIntegration \
    -default-isolation MainActor \
    "${project_root}/DynamicIsland/RecordingState.swift" \
    "${project_root}/DynamicIsland/RecordingSettings.swift" \
    "${project_root}/DynamicIsland/RecordingExporter.swift" \
    "${layout_test_sources[@]}" \
    "${project_root}/Tests/RecordingIntegration.swift"
"${output_directory}/RecordingIntegration"
