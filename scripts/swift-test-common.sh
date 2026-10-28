#!/bin/zsh
# Shared source groups for the standalone Swift integration and UI executables.
# Keep existing run-*-tests.sh / render-*-ui.sh entry points stable.
readonly project_root="${0:A:h:h}"
readonly layout_test_sources=(
    "${project_root}/DynamicIsland/CompactActivityLayout.swift"
    "${project_root}/DynamicIsland/IslandNotchGeometry.swift"
    "${project_root}/DynamicIsland/IslandDisplaySettings.swift"
    "${project_root}/DynamicIsland/IslandLengthConfiguration.swift"
    "${project_root}/DynamicIsland/IslandLengthSettings.swift"
    "${project_root}/DynamicIsland/WindowManager.swift"
)
readonly model_test_sources=(
    "${project_root}/DynamicIsland/TimeToolsState.swift"
    "${project_root}/DynamicIsland/NotesStore.swift"
    "${project_root}/DynamicIsland/IslandModel.swift"
)
readonly app_sources=("${project_root}"/DynamicIsland/*.swift)
readonly view_test_sources=("${(@)app_sources:#*/DynamicIslandApp.swift}")

compile_swift_test() {
    local output_directory="$1" executable_name="$2"
    shift 2
    mkdir -p "$output_directory"
    xcrun swiftc -parse-as-library \
        -module-cache-path "${output_directory}/ModuleCache" \
        "$@" -o "${output_directory}/${executable_name}"
}
