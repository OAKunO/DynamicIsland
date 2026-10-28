#!/bin/zsh
set -euo pipefail
source "${0:A:h}/swift-test-common.sh"
readonly output_directory="${project_root}/.derivedData/LyricsTests"
compile_swift_test "$output_directory" RemoteLyricsIntegration \
    -default-isolation MainActor \
    "${view_test_sources[@]}" "${project_root}/Tests/RemoteLyricsIntegration.swift"
"${output_directory}/RemoteLyricsIntegration"
