#!/usr/bin/env bats
#
# Signals that need a human decision have to leave the run summary, which nobody
# opens, and land somewhere that gets read.

bats_require_minimum_version 1.5.0

load helper

setup() {
    setup_tmpdir
    SYNC="${SCRIPTS_DIR}/sync-upstream.sh"
}

teardown() {
    teardown_tmpdir
}

quiet_report() {
    printf '%s' '{"command":"apply","recipes":[
        {"recipe":"zlib","formula":"zlib","from":"1.3.2","to":"1.3.2","status":"current","patches_not_replayed":0,"formula_changed":false}],
        "new_major_lines":[]}'
}

@test "a quiet run asks for nothing" {
    run --separate-stderr bash -c "$(declare -f quiet_report); quiet_report | '$SYNC' attention"

    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "an orphan recipe asks for a decision" {
    local report='{"command":"apply","recipes":[
        {"recipe":"mysql@5","formula":null,"from":"5.7.0","to":null,"status":"unresolved","patches_not_replayed":0,"formula_changed":false}],
        "new_major_lines":[]}'

    run --separate-stderr bash -c "printf '%s' '$report' | '$SYNC' attention"

    [ "$status" -eq 0 ]
    [[ "$output" == *"mysql@5"* ]]
    [[ "$output" == *"no longer serves"* ]]
}

@test "a formula whose build logic moved asks for a review" {
    local report='{"command":"apply","recipes":[
        {"recipe":"openssl@3","formula":"openssl@3","from":"3.6.4","to":"3.6.4","status":"current","patches_not_replayed":0,"formula_changed":true,"formula_path":"Formula/o/openssl@3.rb"}],
        "new_major_lines":[]}'

    run --separate-stderr bash -c "printf '%s' '$report' | '$SYNC' attention"

    [[ "$output" == *"openssl@3"* ]]
    [[ "$output" == *"homebrew-core/commits/master/Formula/o/openssl@3.rb"* ]]
}

@test "a new major line asks for a product decision" {
    local report='{"command":"apply","recipes":[],"new_major_lines":["postgresql@19"]}'

    run --separate-stderr bash -c "printf '%s' '$report' | '$SYNC' attention"

    [[ "$output" == *"postgresql@19"* ]]
}
