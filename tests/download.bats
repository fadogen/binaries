#!/usr/bin/env bats
#
# Downloads must fail for the reason they actually failed: a network outage
# reported as a checksum mismatch sends whoever reads the log after the wrong
# cause, and the source is blamed for the host being down.

bats_require_minimum_version 1.5.0

load helper

setup() {
    setup_tmpdir
    export DOWNLOADS_DIR="${TEST_TMP}/downloads"
    # Retries are for flaky mirrors, not for a file that will never exist.
    export DOWNLOAD_RETRY_DELAY=0
    source "${LIB_DIR}/colors.sh"
    source "${LIB_DIR}/download.sh"
}

teardown() {
    teardown_tmpdir
}

@test "an unreachable source is reported as a failed download" {
    run download_package "file://${TEST_TMP}/absent.tar.gz" "0000000000000000000000000000000000000000000000000000000000000000"

    [ "$status" -ne 0 ]
    [[ "$output" == *"download failed"* ]]
    [[ "$output" != *"Checksum mismatch"* ]]
}

@test "a corrupted source is reported as a checksum mismatch" {
    printf 'not what was expected\n' > "${TEST_TMP}/pkg.tar.gz"

    run download_package "file://${TEST_TMP}/pkg.tar.gz" "0000000000000000000000000000000000000000000000000000000000000000"

    [ "$status" -ne 0 ]
    [[ "$output" == *"Checksum mismatch"* ]]
}

@test "a failed download leaves no partial file behind to be trusted later" {
    run download_package "file://${TEST_TMP}/absent.tar.gz" "0000000000000000000000000000000000000000000000000000000000000000"

    [ ! -f "${DOWNLOADS_DIR}/absent.tar.gz" ]
}
