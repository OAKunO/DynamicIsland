#!/bin/zsh
set -euo pipefail
source "${0:A:h}/swift-test-common.sh"
readonly output_directory="${project_root}/.derivedData/PhoneTests"
compile_swift_test "$output_directory" PhoneInformationIntegration \
    -default-isolation MainActor \
    "${project_root}/DynamicIsland/IPhoneInformationReader.swift" \
    "${project_root}/Tests/PhoneInformationIntegration.swift"
"${output_directory}/PhoneInformationIntegration" "$@"
