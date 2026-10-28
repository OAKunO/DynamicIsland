#!/bin/zsh
set -euo pipefail
readonly project_root="${0:A:h:h}"
for test_script in "${project_root}"/scripts/run-*-tests.sh; do
    print "Running ${test_script:t}"
    zsh "$test_script"
done
