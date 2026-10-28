#!/bin/zsh
set -euo pipefail
source "${0:A:h}/swift-test-common.sh"
readonly output_directory="${project_root}/.derivedData/NotesTests"
compile_swift_test "$output_directory" NotesIntegration \
    -default-isolation MainActor \
    "${model_test_sources[@]}" \
    "${layout_test_sources[@]}" \
    "${project_root}/Tests/NotesIntegration.swift"
"${output_directory}/NotesIntegration"
readonly persistence_directory="$(mktemp -d "${TMPDIR:-/tmp}/DynamicIslandNotesRestart.XXXXXX")"
trap 'rm -rf "${persistence_directory}"' EXIT
"${output_directory}/NotesIntegration" --persistence-write "${persistence_directory}/memos.json"
"${output_directory}/NotesIntegration" --persistence-read "${persistence_directory}/memos.json"
