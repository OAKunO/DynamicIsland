#!/bin/zsh
set -euo pipefail
source "${0:A:h}/swift-test-common.sh"
readonly output_directory="${project_root}/.derivedData/NotesUI"
# Independent executable: never launches or replaces DynamicIsland.app.
compile_swift_test "$output_directory" NotesUIRender \
    -default-isolation MainActor \
    "${view_test_sources[@]}" "${project_root}/Tests/NotesUIRender.swift"
"${output_directory}/NotesUIRender" "${output_directory}/screenshots"
