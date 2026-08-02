#!/usr/bin/env bats
# Unit tests for nmdctl utility functions

setup() {
    export PATH="$BATS_TEST_DIRNAME/..:$PATH"
    source "$BATS_TEST_DIRNAME/../nmdctl"
    # patch out functions unnecessary for testing
    eval 'check_root() { return 0; }'
    eval 'check_module_loaded() { return 0; }'
    eval 'run_nmd_command() { return 1; }'
    eval 'check_nmdstat_exists() { return 0; }'
    eval 'get_nmdstat_value() { echo "STOPPED"; }'
    eval 'validate_device_path() { return 0; }'
    eval 'get_disk_size_kb() { echo "1000000"; }'

    # Default superblock path for layout tests
    export SUPERBLOCK_PATH="/tmp/test.dat"

    # Never let a test reach the real /etc/nonraid/disk-offsets. Individual
    # tests override this again, but the default must not be the live file:
    # the suite runs as root in CI, so a stray save_disk_offset would write to
    # real array state.
    export DISK_OFFSETS_FILE="$BATS_TMPDIR/default-disk-offsets"
}

teardown() {
    # Cleanup any temporary mock files
    rm -f "$BATS_TMPDIR"/mock_nmdstat_*
}

# Create a mock nmdstat file for testing
create_mock_nmdstat() {
    local state=${1:-STOPPED}
    local missing=${2:-0}
    local invalid=${3:-0}
    local resync=${4:-0}
    local resync_action=${5:-check P}
    local resync_pos=${6:-0}
    local resync_size=${7:-0}
    local resync_corr=${8:-0}
    local sync_errs=${9:-0}

    cat << EOF
mdState=$state
mdNumDisks=3
sbName=/test.dat
sbLabel=MockArray
mdNumMissing=$missing
mdNumInvalid=$invalid
mdNumWrong=0
mdNumDisabled=0
mdNumReplaced=0
mdNumNew=0
mdResync=$resync
mdResyncAction=$resync_action
mdResyncCorr=$resync_corr
mdResyncPos=$resync_pos
mdResyncSize=$resync_size
mdResyncDt=10
mdResyncDb=5000
diskSize.0=2000000
diskSize.1=1000000
diskSize.2=1000000
diskSize.29=0
diskId.0=MOCK_PARITY_DISK
diskId.1=MOCK_DATA_DISK_1
diskId.2=MOCK_DATA_DISK_2
diskName.1=nmd1p1
diskName.2=nmd1p2
rdevName.0=sda1
rdevName.1=sdb1
rdevName.2=sdc1
rdevStatus.0=DISK_OK
rdevStatus.1=DISK_OK
rdevStatus.2=DISK_OK
rdevNumErrors.0=0
rdevNumErrors.1=0
rdevNumErrors.2=0
sbSynced=$(( $(date +%s) - 14*24*3600 ))
sbSynced2=$(( $(date +%s) - 14*24*3600 ))
sbSyncErrs=$sync_errs
sbSyncExit=0
EOF
}

@test "nmdctl version check" {
    run "$BATS_TEST_DIRNAME/../nmdctl" --version
    [ "$status" -eq 0 ]
    [[ "$output" =~ nmdctl\ version\ [0-9]+\.[0-9]+\.[0-9]+ ]]
}

@test "nmdctl help command" {
    run "$BATS_TEST_DIRNAME/../nmdctl" --help
    [ "$status" -eq 0 ]
    [[ "$output" =~ "nmdctl - NonRAID array management utility" ]]
    [[ "$output" =~ "Usage:" ]]
}

@test "invalid command handling" {
    run "$BATS_TEST_DIRNAME/../nmdctl" invalid-command
    [ "$status" -eq 1 ]
}

@test "unassign command parameter validation" {
    # Test missing parameter
    run "$BATS_TEST_DIRNAME/../nmdctl" unassign
    [ "$status" -ne 0 ]
    [[ "$output" =~ "Error: Missing slot parameter" ]]

    # Test invalid slot parameter
    run "$BATS_TEST_DIRNAME/../nmdctl" unassign invalid
    [ "$status" -ne 0 ]
    [[ "$output" =~ "Error: Slot must be a number" ]]

    # Test out of range slot
    run "$BATS_TEST_DIRNAME/../nmdctl" unassign 99
    [ "$status" -ne 0 ]
    [[ "$output" =~ "Error: Invalid slot number" ]]
}

@test "format_kbytes function" {
    # These expectations are decimal (MB = 10^6 B, GB = 10^9 B), matching the
    # unit labels the function prints. Several previously asserted binary
    # results - e.g. 1572864 KB as "1.5 GB" - which is 1.5 GiB mislabelled as
    # GB; decimally it is 1.61 GB.
    # Test basic conversion (1048576 KB ~= 1 GB)
    result=$(format_kbytes 1048576 0 0 "gb")
    [ "$result" = "1" ]

    # 1572864 KB = 1610612736 B = 1.61 GB
    result=$(format_kbytes 1572864 0 1 "gb")
    [ "$result" = "1.6" ]

    # Test rounding up (should round up to 1)
    result=$(format_kbytes 1048575 0 0 "gb")
    [ "$result" -eq 1 ]

    # Test smart decimal display - small remainders show as integers
    # Exactly 1.0 MB should show as "1" not "1.0"
    result=$(format_kbytes 1024 1 1)
    [ "$result" = "1 MB" ]

    result=$(format_kbytes 1024 1 2)
    [ "$result" = "1 MB" ]

    # 1126 KB = 1153024 B = 1.15 MB - a large enough remainder to show decimals
    result=$(format_kbytes 1126 1 1)
    [ "$result" = "1.1 MB" ]

    result=$(format_kbytes 1126 1 2)
    [ "$result" = "1.15 MB" ]

    # 1.5 MB (significant remainder) should show decimals
    result=$(format_kbytes 1536 1 0)
    [ "$result" = "2 MB" ]

    result=$(format_kbytes 1536 1 1)
    [ "$result" = "1.5 MB" ]

    result=$(format_kbytes 1536 1 2)
    [ "$result" = "1.57 MB" ]

    # Test GB formatting with 2 decimals
    result=$(format_kbytes 1572864 1 2)  # 1.61 GB
    [ "$result" = "1.61 GB" ]

    # Test exactly 1 GB shows as integer
    result=$(format_kbytes 1048576 1 1)  # Exactly 1 GB
    [ "$result" = "1 GB" ]

    result=$(format_kbytes 1048576 1 2)  # Exactly 1 GB
    [ "$result" = "1 GB" ]

    # Test default behavior (should default to 1 decimal place)
    result=$(format_kbytes 1536)
    [ "$result" = "1.5 MB" ]

    # Test without unit suffix
    result=$(format_kbytes 1536 0 1)
    [ "$result" = "1.5" ]

    # Test forced units with no decimals
    result=$(format_kbytes 1572864 0 0 "gb")
    [ "$result" = "2" ]

    # Test forced units with decimals (1572864 KB = 1.61 GB decimal)
    result=$(format_kbytes 1572864 0 1 "gb")
    [ "$result" = "1.6" ]

    # Test KB and B units (should not have decimals). Decimal like the rest:
    # 1536 KiB = 1572864 B = 1572 kB. Previously asserted "1536 kB", which was
    # the input echoed back under a decimal label.
    result=$(format_kbytes 1536 1 1 "kb")
    [ "$result" = "1572 kB" ]

    result=$(format_kbytes 1 1 1 "b")
    [ "$result" = "1024 B" ]

    # Test TB formatting. 1073741824000 KB = 1.0995e15 B = 1099.5 TB decimal
    # (it is 1000 TiB, which is what the old binary maths reported as "1000 TB").
    result=$(format_kbytes 1073741824000 1 1 "tb")
    [ "$result" = "1099.5 TB" ]

    # Test very large number with 2 decimals (1.5 TiB = 1.64 TB decimal)
    result=$(format_kbytes 1610612736 1 2)
    [ "$result" = "1.64 TB" ]
}

@test "format_time_duration function" {
    # Test seconds
    result=$(format_time_duration 45)
    [ "$result" = "45 sec" ]

    # Test minutes
    result=$(format_time_duration 150)  # 2 minutes 30 seconds
    [ "$result" = "2 minutes, 30 seconds" ]

    # Test hours
    result=$(format_time_duration 7200)  # 2 hours
    [ "$result" = "2 hours, 00 minutes" ]

    # Test days
    result=$(format_time_duration 90000)  # 1 day 1 hour
    [ "$result" = "1 days, 1 hours" ]
}

@test "get_visible_length function" {
    # Test known status lengths
    result=$(get_visible_length "$(echo -e "\033[0;32mDISK_OK\033[0m")")
    echo "$result"
    [ "$result" -eq 7 ]

    result=$(get_visible_length "$(echo -e "\033[0;31mDISK_INVALID\033[0m")")
    [ "$result" -eq 12 ]

    result=$(get_visible_length "$(echo -e "\033[0;32mDISK_OK\033[0m \033[0;31m10 errs\033[0m")")
    [ "$result" -eq 15 ]
}

# Status parsing tests with mock environment
@test "status parsing - HEALTHY state detection" {
    create_mock_nmdstat "STARTED" 0 0 > "$BATS_TMPDIR/mock_nmdstat_healthy"

    export PROC_NMDSTAT="$BATS_TMPDIR/mock_nmdstat_healthy"
    run show_status

    echo "$status"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" =~ Array\ State.*STARTED ]]
    [[ "$output" =~ "Disks Present : 3" ]]
    [[ "$output" =~ Array\ Health.*HEALTHY ]]
}

@test "status parsing - STOPPED state detection" {
    create_mock_nmdstat "STOPPED" 0 0 > "$BATS_TMPDIR/mock_nmdstat_stopped"

    export PROC_NMDSTAT="$BATS_TMPDIR/mock_nmdstat_stopped"
    run show_status

    echo "$status"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" =~ Array\ State.*STOPPED ]]
}

@test "status parsing - DEGRADED state with missing disk" {
    create_mock_nmdstat "STARTED" 1 0 > "$BATS_TMPDIR/mock_nmdstat_degraded"

    export PROC_NMDSTAT="$BATS_TMPDIR/mock_nmdstat_degraded"
    run show_status

    echo "$status"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" =~ Array\ Health.*DEGRADED ]]
}

@test "status parsing - Array size calculation" {
    create_mock_nmdstat "STARTED" 0 0 > "$BATS_TMPDIR/mock_nmdstat_size"

    export PROC_NMDSTAT="$BATS_TMPDIR/mock_nmdstat_size"
    run show_status

    echo "$status"
    echo "$output"
    [ "$status" -eq 0 ]
    # 2 data disks of 1000000 KB = 2048000000 B = 2.05 GB. Previously read as
    # 1.9 because the size was divided in binary and labelled GB.
    [[ "$output" =~ Array\ Size.*2\ GB\ \(2\ data\ disk\(s\)\) ]]
}

@test "status parsing - Array with invalid disks" {
    create_mock_nmdstat "STOPPED" 0 1 > "$BATS_TMPDIR/mock_nmdstat_invalid"

    export PROC_NMDSTAT="$BATS_TMPDIR/mock_nmdstat_invalid"
    run show_status

    echo "$status"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" =~ Invalid:\ 1 ]]
    [[ "$output" =~ DEGRADED ]]
}

@test "status parsing - Parity check in progress" {
    # Create mock with parity check in progress (50% complete)
    create_mock_nmdstat "STARTED" 0 0 1 "check P" 500000 1000000 1 0 > "$BATS_TMPDIR/mock_nmdstat_parity_check"

    export PROC_NMDSTAT="$BATS_TMPDIR/mock_nmdstat_parity_check"
    run show_status -v

    echo "$status"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" =~ Array\ State.*STARTED ]]
    [[ "$output" =~ Array\ Health.*HEALTHY ]]
    [[ "$output" =~ Operation.*Parity-Check\ P ]]
    [[ "$output" =~ MOCK_DATA_DISK_1 ]]
}

@test "status parsing - Parity sync in progress" {
    # Create mock with parity sync in progress
    create_mock_nmdstat "STARTED" 0 1 1 "recon P" 250000 1000000 0 0 > "$BATS_TMPDIR/mock_nmdstat_parity_sync"

    export PROC_NMDSTAT="$BATS_TMPDIR/mock_nmdstat_parity_sync"
    run show_status

    echo "$status"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" =~ Array\ State.*STARTED ]]
    [[ "$output" =~ Array\ Health.*DEGRADED ]]
    [[ "$output" =~ Progress.*25% ]]
    [[ "$output" =~ Operation.*Parity-Sync\ P ]]
    [[ "$output" =~ WARNING:\ Driver\ internal\ state ]]
}

@test "handle_check - RESUME resumes paused parity check" {
    create_mock_nmdstat "STARTED" 0 0 0 "check P" 500000 1000000 0 0 > "$BATS_TMPDIR/mock_nmdstat_paused_check"

    export PROC_NMDSTAT="$BATS_TMPDIR/mock_nmdstat_paused_check"
    eval 'run_nmd_command() { echo "cmd: $*"; return 0; }'
    run handle_check "RESUME"

    echo "$status"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "cmd: check RESUME" ]]
}

@test "handle_check - RESUME in unattended mode resumes paused parity check" {
    create_mock_nmdstat "STARTED" 0 0 0 "check P" 500000 1000000 0 0 > "$BATS_TMPDIR/mock_nmdstat_paused_check_unattended"

    export PROC_NMDSTAT="$BATS_TMPDIR/mock_nmdstat_paused_check_unattended"
    export UNATTENDED=1
    eval 'run_nmd_command() { echo "cmd: $*"; return 0; }'
    run handle_check "RESUME"

    echo "$status"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "cmd: check RESUME" ]]
}

@test "handle_check - new check blocked in unattended mode with paused operation" {
    create_mock_nmdstat "STARTED" 0 0 0 "check P" 500000 1000000 0 0 > "$BATS_TMPDIR/mock_nmdstat_paused_check_block"

    export PROC_NMDSTAT="$BATS_TMPDIR/mock_nmdstat_paused_check_block"
    export UNATTENDED=1
    run handle_check

    echo "$status"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Cannot start new operation with a paused operation pending" ]]
}

@test "handle_check - RESUME blocked when no paused operation" {
    # mdResync=0, mdResyncPos=0 means nothing paused
    create_mock_nmdstat "STARTED" 0 0 0 "check P" 0 0 0 0 > "$BATS_TMPDIR/mock_nmdstat_no_paused"

    export PROC_NMDSTAT="$BATS_TMPDIR/mock_nmdstat_no_paused"
    run handle_check "RESUME"

    echo "$status"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "No paused resync operation to resume" ]]
}

@test "handle_check - check blocked in unattended mode when recon is pending" {
    # mdResync=0, mdResyncPos=0, mdResyncAction=recon means a recon is pending (not started)
    create_mock_nmdstat "STARTED" 0 1 0 "recon P" 0 1000000 0 0 > "$BATS_TMPDIR/mock_nmdstat_recon_pending"

    export PROC_NMDSTAT="$BATS_TMPDIR/mock_nmdstat_recon_pending"
    export UNATTENDED=1
    run handle_check

    echo "$status"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Cannot start parity check with another sync operation pending" ]]
}

@test "status parsing - Parity check with errors found" {
    # Create mock with parity check that found errors
    create_mock_nmdstat "STARTED" 0 0 0 "check P" 0 0 1 15 > "$BATS_TMPDIR/mock_nmdstat_parity_errors"

    export PROC_NMDSTAT="$BATS_TMPDIR/mock_nmdstat_parity_errors"
    run show_status

    echo "$status"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" =~ Sync\ Errors:\ 15 ]]
}

@test "status parsing - Array with disk errors" {
    # Create mock with disk errors - need to override the basic template
    create_mock_nmdstat "STARTED" 0 0 > "$BATS_TMPDIR/mock_nmdstat_disk_errors"
    sed -i -e 's/rdevNumErrors.1=0/rdevNumErrors.1=5/' \
           -e 's/rdevNumErrors.2=0/rdevNumErrors.2=10/' \
           "$BATS_TMPDIR/mock_nmdstat_disk_errors"

    export PROC_NMDSTAT="$BATS_TMPDIR/mock_nmdstat_disk_errors"
    run show_status

    echo "$status"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" =~ 5\ errs ]]
    [[ "$output" =~ 10\ errs ]]
    [[ "$output" =~ WARNING.*15\ total ]]
}

@test "status parsing - Array with Q" {
    # Create mock with Q disk - need to override the basic template
    create_mock_nmdstat "STARTED" 0 0 > "$BATS_TMPDIR/mock_nmdstat_dual_parity"
    sed -i -e 's/diskSize.29=0/diskSize.29=1500000\
diskId.29=MOCK_PARITY_DISK_2\
rdevName.29=sdd1\
rdevStatus.29=DISK_OK\
rdevNumErrors.29=0/' \
           "$BATS_TMPDIR/mock_nmdstat_dual_parity"

    export PROC_NMDSTAT="$BATS_TMPDIR/mock_nmdstat_dual_parity"
    run show_status -v

    echo "$status"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" =~ Parity.*Dual\ Parity ]]
    [[ "$output" =~ "MOCK_PARITY_DISK_2 (sdd1)  1500000" ]]
}

@test "unassigning a disk" {
    create_mock_nmdstat "STOPPED" 0 0 > "$BATS_TMPDIR/mock_nmdstat_stopped"

    export PROC_NMDSTAT="$BATS_TMPDIR/mock_nmdstat_stopped"
    run unassign_disk 2 <<< "y"

    echo "$status"
    echo "$output"
    [ "$status" -eq 1 ] # fails due to error writing to nmdcmd
    [[ "$output" =~ Unassigning\ disk\ from\ slot\ 2 ]]
}

@test "nmdctl help performance" {
    local start_time=$(date +%s%N)
    run timeout 5s "$BATS_TEST_DIRNAME/../nmdctl" --help
    local end_time=$(date +%s%N)

    local duration=$((end_time - start_time))

    # Should complete in under 100 ms
    [ "$((duration / 1000000))" -lt 100 ]
}

# Tests for different output formats
@test "status parsing - default format" {
    create_mock_nmdstat "STARTED" 0 0 > "$BATS_TMPDIR/mock_nmdstat_default"

    export PROC_NMDSTAT="$BATS_TMPDIR/mock_nmdstat_default"
    run show_status

    echo "$status"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "=== NonRAID Array Status ===" ]]
    [[ "$output" =~ Array\ State.*STARTED ]]
    [[ "$output" =~ Array\ Health.*HEALTHY ]]
}

@test "status parsing - default format explicit" {
    create_mock_nmdstat "STARTED" 0 0 > "$BATS_TMPDIR/mock_nmdstat_default_explicit"

    export PROC_NMDSTAT="$BATS_TMPDIR/mock_nmdstat_default_explicit"
    run show_status -o default

    echo "$status"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "=== NonRAID Array Status ===" ]]
    [[ "$output" =~ Array\ State.*STARTED ]]
    [[ "$output" =~ Array\ Health.*HEALTHY ]]
}

@test "status parsing - prometheus format" {
    create_mock_nmdstat "STARTED" 0 0 > "$BATS_TMPDIR/mock_nmdstat_prometheus"

    export PROC_NMDSTAT="$BATS_TMPDIR/mock_nmdstat_prometheus"
    run show_status -o prometheus

    echo "$status"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "# HELP nonraid_array_state" ]]
    [[ "$output" =~ "# HELP nonraid_array_health" ]]
    [[ "$output" =~ "nonraid_array_state{label=\"MockArray\"} 1" ]]
    [[ "$output" =~ "nonraid_array_health{label=\"MockArray\",status=\"HEALTHY\"} 0" ]]
}

@test "status parsing - json format" {
    create_mock_nmdstat "STARTED" 0 0 > "$BATS_TMPDIR/mock_nmdstat_json"

    export PROC_NMDSTAT="$BATS_TMPDIR/mock_nmdstat_json"
    run show_status -o json

    echo "$status"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "\"timestamp\":" ]]
    [[ "$output" =~ "\"state\": \"STARTED\"" ]]
    [[ "$output" =~ "\"status\": \"HEALTHY\"" ]]
    [[ "$output" =~ "\"label\": \"MockArray\"" ]]

    # Validate that the output is valid JSON
    echo "$output" | jq . > /dev/null
    [ "$?" -eq 0 ]
}

@test "status parsing - invalid format" {
    create_mock_nmdstat "STARTED" 0 0 > "$BATS_TMPDIR/mock_nmdstat_invalid_format"

    export PROC_NMDSTAT="$BATS_TMPDIR/mock_nmdstat_invalid_format"
    run show_status -o invalid

    echo "$status"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Error: Invalid output format" ]]
}

@test "prometheus format - degraded state" {
    create_mock_nmdstat "STARTED" 1 0 > "$BATS_TMPDIR/mock_nmdstat_prometheus_degraded"

    export PROC_NMDSTAT="$BATS_TMPDIR/mock_nmdstat_prometheus_degraded"
    run show_status -o prometheus

    echo "$status"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "nonraid_array_health{label=\"MockArray\",status=\"DEGRADED\"} 1" ]]
    [[ "$output" =~ "nonraid_nummissing_count{label=\"MockArray\"} 1" ]]
}

@test "json format - degraded state" {
    create_mock_nmdstat "STARTED" 1 0 > "$BATS_TMPDIR/mock_nmdstat_json_degraded"

    export PROC_NMDSTAT="$BATS_TMPDIR/mock_nmdstat_json_degraded"
    run show_status -o json

    echo "$status"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "\"status\": \"DEGRADED\"" ]]
    [[ "$output" =~ "\"code\": 1" ]]
}

@test "data collection functions work correctly" {
    create_mock_nmdstat "STARTED" 0 0 > "$BATS_TMPDIR/mock_nmdstat_collection"

    export PROC_NMDSTAT="$BATS_TMPDIR/mock_nmdstat_collection"

    # Test data collection functions
    get_all_nmdstat_values NMDSTAT_VALUES
    collect_array_summary
    collect_array_health
    collect_array_size_and_parity
    collect_resync_status
    collect_disk_status

    echo "$status"
    echo "$output"

    # Verify ARRAY_STATUS_DATA was populated correctly
    [ "${ARRAY_STATUS_DATA[mdstate]}" = "STARTED" ]
    [ "${ARRAY_STATUS_DATA[sblabel]}" = "MockArray" ]
    [ "${ARRAY_STATUS_DATA[health_status]}" = "HEALTHY" ]
    [ "${ARRAY_STATUS_DATA[health_code]}" = "0" ]
    [ "${ARRAY_STATUS_DATA[data_disk_count]}" = "2" ]
    [ "${ARRAY_STATUS_DATA[has_parity]}" = "true" ]
    [ "${ARRAY_STATUS_DATA[data_size_gb]}" = "2" ]
    [ "${ARRAY_STATUS_DATA[parity_size_gb]}" = "2" ]
    [ -n "${ARRAY_STATUS_DATA[last_sync_timestamp]}" ]
    [ -n "${ARRAY_STATUS_DATA[last_sync_ago]}" ]

    # Verify RESYNC_STATUS_DATA was populated correctly
    [ "${RESYNC_STATUS_DATA[active]}" = "false" ]
    [ "${RESYNC_STATUS_DATA[progress_percent]}" = "0" ]
    [ "${RESYNC_STATUS_DATA[paused]}" = "false" ]
    [ "${RESYNC_STATUS_DATA[pending]}" = "false" ]

    # Verify DISK_STATUS_DATA was populated correctly
    # Check that we have data for parity disk (slot 0)
    [ "${DISK_STATUS_DATA[slot_0_type]}" = "P" ]
    [ "${DISK_STATUS_DATA[slot_0_present]}" = "true" ]
    [ "${DISK_STATUS_DATA[slot_0_size_gb]}" = "2" ]
    [ "${DISK_STATUS_DATA[slot_0_errors]}" = "0" ]

    # Check that we have data for data disks (slots 1 and 2)
    [ "${DISK_STATUS_DATA[slot_1_present]}" = "true" ]
    [ "${DISK_STATUS_DATA[slot_1_type]}" = "data" ]
    [ "${DISK_STATUS_DATA[slot_1_size_gb]}" = "1" ]
    [ "${DISK_STATUS_DATA[slot_1_errors]}" = "0" ]

    [ "${DISK_STATUS_DATA[slot_2_present]}" = "true" ]
    [ "${DISK_STATUS_DATA[slot_2_type]}" = "data" ]
    [ "${DISK_STATUS_DATA[slot_2_size_gb]}" = "1" ]
    [ "${DISK_STATUS_DATA[slot_2_errors]}" = "0" ]
}

# Helper function to mock run_nmd_command for layout tests
mock_import_success() {
    eval 'run_nmd_command() { echo "Imported: $1 $2"; return 0; }'
}

mock_import_with_status() {
    eval 'show_status() { echo "Array status displayed"; return 0; }'
}

# Tests for create_array_layout function
@test "create_array_layout - parameter parsing with P notation" {
    mock_import_success
    run create_array_layout 1 "P:/tmp/disk1:parity-disk" "1:/tmp/disk2:data-disk-1" "2:/tmp/disk3:data-disk-2"

    echo "$output"
    [ "$status" -eq 0 ]
    # Strip ANSI color codes for testing
    local clean_output
    clean_output=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g')
    [[ "$clean_output" =~ Slot\ 0: ]]
    [[ "$clean_output" =~ Slot\ 1: ]]
    [[ "$clean_output" =~ Slot\ 2: ]]
}

@test "create_array_layout - parameter parsing with numeric notation" {
    mock_import_success
    run create_array_layout 1 "0:/tmp/disk1:parity-disk" "1:/tmp/disk2:data-disk-1"

    echo "$output"
    [ "$status" -eq 0 ]
    # Strip ANSI color codes for testing
    local clean_output
    clean_output=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g')
    [[ "$clean_output" =~ Slot\ 0: ]]
    [[ "$clean_output" =~ Slot\ 1: ]]
}

@test "create_array_layout - parameter parsing with Q notation" {
    mock_import_success
    run create_array_layout 1 "P:/tmp/parity:parity-disk-1" "Q:/tmp/parity2:parity-disk-2" "1:/tmp/data1:data-disk-1"

    echo "$output"
    [ "$status" -eq 0 ]
    # Strip ANSI color codes for testing
    local clean_output
    clean_output=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g')
    [[ "$clean_output" =~ Slot\ 0: ]]
    [[ "$clean_output" =~ Slot\ 29: ]]
    [[ "$clean_output" =~ Slot\ 1: ]]
}

@test "create_array_layout - invalid parameter format" {
    run create_array_layout 1 "invalid_format"

    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "Error: Invalid format" ]] || [[ "$output" =~ "Error: Could not determine disk ID" ]]
    [[ "$output" =~ "Expected format:" ]] || [[ "$output" =~ "provide disk ID manually" ]]
}

@test "create_array_layout - duplicate slot assignment" {
    run create_array_layout 1 "0:/tmp/disk1:disk-id-1" "P:/tmp/disk2:disk-id-2"

    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "Error: Slot 0 specified multiple times" ]]
}

@test "create_array_layout - with force flag and device validation" {
    mock_import_success
    run create_array --force "0:/tmp/disk1:disk-id-1" "1:/tmp/disk2:disk-id-2"

    echo "$output"
    [ "$status" -eq 0 ]
}

@test "create_array_layout - no parameters uses interactive mode" {
    eval 'create_array_interactive() { echo "Interactive mode called"; return 0; }'
    run create_array

    echo "$output"
    [[ "$output" =~ "Interactive mode called" ]]
}

@test "create_array_layout - P and Q alias validation" {
    mock_import_success
    run create_array_layout 1 "P:/tmp/parity:parity-disk-1" "Q:/tmp/parity2:parity-disk-2"

    echo "$output"
    [ "$status" -eq 0 ]
    # Strip ANSI color codes for testing
    local clean_output
    clean_output=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g')
    [[ "$clean_output" =~ Slot\ 0: ]]
    [[ "$clean_output" =~ Slot\ 29: ]]
}

@test "create_array_layout - array creation flow" {
    mock_import_success
    mock_import_with_status
    run create_array_layout 1 "0:/tmp/disk1:parity-disk" "1:/tmp/disk2:data-disk-1" "2:/tmp/disk3:data-disk-2"

    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Array layout validated successfully" ]]
    [[ "$output" =~ "All disks imported successfully" ]]
}

@test "create_array_layout - error on missing device without force" {
    # Test that validation catches missing devices (no force)
    run create_array_layout 0 "0:/dev/nonexistent1:disk-id"

    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "Error" ]]
}


@test "device_kernel_name - plain /dev path passes through" {
    run device_kernel_name "/dev/null"

    [ "$status" -eq 0 ]
    [ "$output" = "null" ]
}

@test "device_kernel_name - by-id style symlink resolves to the kernel name" {
    # The driver opens /dev/<name>, so a symlink must resolve to its target's
    # name. Returning the symlink's own basename makes the import a silent no-op.
    ln -sf /dev/null "$BATS_TMPDIR/virtio-testdisk-part1"
    run device_kernel_name "$BATS_TMPDIR/virtio-testdisk-part1"

    [ "$status" -eq 0 ]
    [ "$output" = "null" ]
    [ "$output" != "virtio-testdisk-part1" ]
}

@test "device_kernel_name - chained symlink resolves to the final target" {
    ln -sf /dev/null "$BATS_TMPDIR/link-a"
    ln -sf "$BATS_TMPDIR/link-a" "$BATS_TMPDIR/link-b"
    run device_kernel_name "$BATS_TMPDIR/link-b"

    [ "$status" -eq 0 ]
    [ "$output" = "null" ]
}

@test "device_kernel_name - unresolvable path falls back to its own basename" {
    # readlink -e fails here; the fallback must yield something that then fails
    # the caller's block-device check rather than a plausible-looking name.
    run device_kernel_name "/dev/disk/by-id/definitely-not-present"

    [ "$status" -eq 0 ]
    [ "$output" = "definitely-not-present" ]
}

@test "device_kernel_name - dangling symlink falls back rather than inventing a name" {
    ln -sf "$BATS_TMPDIR/no-such-target" "$BATS_TMPDIR/dangling-link"
    run device_kernel_name "$BATS_TMPDIR/dangling-link"

    [ "$status" -eq 0 ]
    [ "$output" = "dangling-link" ]
}

@test "unassign_disk - refuses in unattended mode without --force" {
    create_mock_nmdstat "STOPPED" 0 0 > "$BATS_TMPDIR/mock_nmdstat_unassign_u"
    export PROC_NMDSTAT="$BATS_TMPDIR/mock_nmdstat_unassign_u"
    export UNATTENDED=1

    run unassign_disk 1

    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "without --force" ]]
}

@test "unassign_disk - proceeds in unattended mode with --force and no stdin" {
    create_mock_nmdstat "STOPPED" 0 0 > "$BATS_TMPDIR/mock_nmdstat_unassign_uf"
    export PROC_NMDSTAT="$BATS_TMPDIR/mock_nmdstat_unassign_uf"
    export UNATTENDED=1
    eval 'run_nmd_command() { echo "cmd: $*"; return 0; }'

    run unassign_disk 1 -f < /dev/null

    echo "$output"
    [[ ! "$output" =~ "without --force" ]]
    [[ ! "$output" =~ "Operation cancelled" ]]
}

@test "unassign_disk - rejects a second positional argument" {
    # Destructive command: "unassign 1 2 -f" must not silently act on slot 1.
    export UNATTENDED=1
    run unassign_disk 1 2 -f

    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Unexpected argument" ]]
}

@test "unassign_disk - rejects an unknown option" {
    export UNATTENDED=1
    run unassign_disk --forse 1

    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Unknown option" ]]
}

@test "is_valid_offset - accepts digits, rejects anything else" {
    run is_valid_offset 0;    [ "$status" -eq 0 ]
    run is_valid_offset 64;   [ "$status" -eq 0 ]
    run is_valid_offset "";   [ "$status" -ne 0 ]
    run is_valid_offset "64a"; [ "$status" -ne 0 ]
    run is_valid_offset "-1"; [ "$status" -ne 0 ]
}

@test "parse_device_spec - device only" {
    run parse_device_spec "/dev/sdb1"

    [ "$status" -eq 0 ]
    [ "$output" = "/dev/sdb1||0" ]
}

@test "parse_device_spec - device and id" {
    run parse_device_spec "/dev/sdb1:ata-SOMEDISK_123"

    [ "$status" -eq 0 ]
    [ "$output" = "/dev/sdb1|ata-SOMEDISK_123|0" ]
}

@test "parse_device_spec - device, id and offset" {
    # A nonzero offset is only accepted for a whole disk; stub the check so the
    # test does not depend on the runner having a spare physical disk.
    eval 'is_whole_device() { return 0; }'
    run parse_device_spec "/dev/sdb:virtdisk-001:64"

    [ "$status" -eq 0 ]
    [ "$output" = "/dev/sdb|virtdisk-001|64" ]
}

@test "parse_device_spec - an all-digit disk ID is an ID, not an offset" {
    # Upstream's parser treated a numeric second field as an offset, so this
    # spec silently imported the disk at offset 12345 and sized it wrongly.
    run parse_device_spec "/dev/sdb1:12345"

    [ "$status" -eq 0 ]
    [ "$output" = "/dev/sdb1|12345|0" ]
}

@test "parse_device_spec - rejects a non-numeric offset" {
    run parse_device_spec "/dev/sdb:myid:notanumber"

    [ "$status" -ne 0 ]
    [[ "$output" =~ "canonical decimal" ]]
}

@test "parse_device_spec - rejects too many fields" {
    run parse_device_spec "/dev/sdb:myid:64:extra"

    [ "$status" -ne 0 ]
    [[ "$output" =~ "too many fields" ]]
}

@test "save/get_disk_offset - round trip, overwrite and clear" {
    export DISK_OFFSETS_FILE="$BATS_TMPDIR/disk-offsets"
    rm -f "$DISK_OFFSETS_FILE"

    # nothing recorded yet
    run get_saved_disk_offset "diskA"
    [ "$output" = "0" ]

    save_disk_offset "diskA" 64
    save_disk_offset "diskB" 2048
    run get_saved_disk_offset "diskA"
    [ "$output" = "64" ]
    run get_saved_disk_offset "diskB"
    [ "$output" = "2048" ]

    # overwriting one entry must not disturb the other
    save_disk_offset "diskA" 128
    run get_saved_disk_offset "diskA"
    [ "$output" = "128" ]
    run get_saved_disk_offset "diskB"
    [ "$output" = "2048" ]

    # re-adding without an offset clears the stale record
    save_disk_offset "diskA" 0
    run get_saved_disk_offset "diskA"
    [ "$output" = "0" ]
    run get_saved_disk_offset "diskB"
    [ "$output" = "2048" ]
}

@test "save_disk_offset - refuses a non-numeric offset without touching the file" {
    export DISK_OFFSETS_FILE="$BATS_TMPDIR/disk-offsets-guard"
    rm -f "$DISK_OFFSETS_FILE"
    save_disk_offset "diskA" 64

    run save_disk_offset "diskB" "garbage"
    [ "$status" -ne 0 ]

    # the existing entry must survive a rejected write
    run get_saved_disk_offset "diskA"
    [ "$output" = "64" ]
}

@test "is_valid_offset - rejects leading zeros that bash would read as octal" {
    # "08" passes a bare ^[0-9]+$ and then dies in arithmetic with
    # "value too great for base", so it must be rejected up front.
    run is_valid_offset "08"
    [ "$status" -ne 0 ]

    run is_valid_offset "0"
    [ "$status" -eq 0 ]

    run is_valid_offset "64"
    [ "$status" -eq 0 ]
}

@test "is_valid_offset - rejects values that would overflow shell arithmetic" {
    run is_valid_offset "999999999999999999"
    [ "$status" -eq 0 ]

    run is_valid_offset "99999999999999999999999999"
    [ "$status" -ne 0 ]
}

@test "parse_device_spec - refuses a nonzero offset on a partition" {
    # Reload applies a saved offset to the whole physical disk, so an offset
    # against a partition would address a different region afterwards.
    eval 'is_whole_device() { return 1; }'
    run parse_device_spec "/dev/sdb1:myid:64"

    [ "$status" -ne 0 ]
    [[ "$output" =~ "whole device" ]]
}

@test "parse_device_spec - allows offset 0 on a partition" {
    eval 'is_whole_device() { return 1; }'
    run parse_device_spec "/dev/sdb1:myid:0"

    [ "$status" -eq 0 ]
    [ "$output" = "/dev/sdb1|myid|0" ]
}

@test "get_saved_disk_offset - malformed record fails closed rather than reading as 0" {
    export DISK_OFFSETS_FILE="$BATS_TMPDIR/offsets-malformed"
    printf 'diskA notanumber\n' > "$DISK_OFFSETS_FILE"

    run get_saved_disk_offset "diskA"
    # Exit 2 distinguishes "malformed record" from "no record"; the caller must
    # refuse the disk rather than import it at sector 0.
    [ "$status" -eq 2 ]

    printf 'diskB\n' > "$DISK_OFFSETS_FILE"
    run get_saved_disk_offset "diskB"
    [ "$status" -eq 2 ]
}

@test "get_saved_disk_offset - a read failure fails closed rather than reading as 0" {
    export DISK_OFFSETS_FILE="$BATS_TMPDIR/offsets-unreadable"
    printf 'diskA 64\n' > "$DISK_OFFSETS_FILE"

    # Permission bits are not a barrier under root (CAP_DAC_OVERRIDE), so the
    # read is broken by shadowing awk instead. Empty output from a failed read
    # must not be read as "no record".
    awk() { return 1; }

    run get_saved_disk_offset "diskA"
    unset -f awk

    [ "$status" -eq 2 ]
}

@test "save_disk_offset - rejects a disk ID containing whitespace" {
    export DISK_OFFSETS_FILE="$BATS_TMPDIR/offsets-whitespace"
    rm -f "$DISK_OFFSETS_FILE"

    # "<id> <offset>" is whitespace separated and lookups match on the first
    # field, so such a record could never be found or removed again.
    run save_disk_offset "disk with spaces" 64
    [ "$status" -ne 0 ]
    [[ "$output" =~ "whitespace" ]]
    [ ! -f "$DISK_OFFSETS_FILE" ]

    run save_disk_offset "$(printf 'disk\tid')" 64
    [ "$status" -ne 0 ]
}

@test "get_saved_disk_offset - absent record is 0 with success" {
    export DISK_OFFSETS_FILE="$BATS_TMPDIR/offsets-absent"
    printf 'diskA 64\n' > "$DISK_OFFSETS_FILE"

    run get_saved_disk_offset "diskZ"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "save_disk_offset - rejects a disk ID longer than the driver stores" {
    export DISK_OFFSETS_FILE="$BATS_TMPDIR/offsets-toolong"
    rm -f "$DISK_OFFSETS_FILE"

    # MD_ID_SIZE is 80 including the terminator and the driver strncpy()s
    # MD_ID_SIZE-1, so /proc/nmdstat reports at most 79 bytes. A longer key
    # could never be matched on reload, and the disk would return at offset 0.
    local long79 long80
    long79=$(printf 'a%.0s' $(seq 1 79))
    long80=$(printf 'a%.0s' $(seq 1 80))

    run save_disk_offset "$long80" 64
    [ "$status" -ne 0 ]
    [[ "$output" =~ "79 bytes" ]]
    [ ! -f "$DISK_OFFSETS_FILE" ]

    run save_disk_offset "$long79" 64
    [ "$status" -eq 0 ]
    run get_saved_disk_offset "$long79"
    [ "$output" = "64" ]
}

@test "save_disk_offset - an unwritable path fails loudly instead of silently" {
    # Runs as root in CI, so permission bits are not a reliable barrier
    # (CAP_DAC_OVERRIDE). Put a regular file where the parent directory would
    # have to be: mkdir -p then fails for any user.
    printf 'not a directory\n' > "$BATS_TMPDIR/blocker"
    export DISK_OFFSETS_FILE="$BATS_TMPDIR/blocker/disk-offsets"

    run save_disk_offset "diskA" 64

    [ "$status" -ne 0 ]
    [[ "$output" =~ "could not" ]]
}

@test "save_disk_offset - a rejected write leaves earlier entries intact" {
    export DISK_OFFSETS_FILE="$BATS_TMPDIR/offsets-intact"
    rm -f "$DISK_OFFSETS_FILE"
    save_disk_offset "diskA" 64

    # A non-canonical offset is refused before the file is touched.
    run save_disk_offset "diskB" "08"
    [ "$status" -ne 0 ]

    run get_saved_disk_offset "diskA"
    [ "$output" = "64" ]
    run get_saved_disk_offset "diskB"
    [ "$output" = "0" ]
}

@test "validate_disk_id - accepts a normal udev ID_SERIAL" {
    run validate_disk_id "Samsung_SSD_860_EVO_1TB_S5B3NR0N810424T"

    [ "$status" -eq 0 ]
}

@test "validate_disk_id - empty is allowed (caller derives one later)" {
    run validate_disk_id ""

    [ "$status" -eq 0 ]
}

@test "validate_disk_id - rejects the driver's delimiters" {
    # The driver tokenises the import command on " ,\t\n", and the ID is the
    # last field, so any of these truncates it silently.
    run validate_disk_id "ata-SOME DISK_123"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "space, comma, tab or newline" ]]

    run validate_disk_id "ata-SOME,DISK_123"
    [ "$status" -ne 0 ]

    run validate_disk_id "$(printf 'ata-SOME\tDISK')"
    [ "$status" -ne 0 ]

    run validate_disk_id "$(printf 'ata-SOME\nDISK')"
    [ "$status" -ne 0 ]
}

@test "validate_disk_id - rejects nmdctl's own field separator" {
    # Driver-valid, but nmdctl joins specs and import entries with '|' and reads
    # them back with IFS='|', so this would shift every field after it.
    run validate_disk_id "ata-SOME|DISK_123"

    [ "$status" -ne 0 ]
    [[ "$output" =~ "contains a '|'" ]]
}

@test "validate_disk_id - rejects an ID longer than the driver can store" {
    # MD_ID_SIZE is 80 including the terminator.
    local ok_id
    ok_id=$(printf 'a%.0s' $(seq 1 79))
    run validate_disk_id "$ok_id"
    [ "$status" -eq 0 ]

    local long_id
    long_id=$(printf 'a%.0s' $(seq 1 80))
    run validate_disk_id "$long_id"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "at most 79" ]]
}

@test "validate_disk_id - measures the driver's limit in bytes, not characters" {
    # strncpy into MD_ID_SIZE bounds bytes. 40 two-byte characters is 80 bytes,
    # which the driver truncates, but only 40 characters - so a length check run
    # in a multibyte locale would wave it through.
    local multibyte_id
    multibyte_id=$(printf 'ä%.0s' $(seq 1 40))

    LC_ALL=en_US.UTF-8 run validate_disk_id "$multibyte_id"

    [ "$status" -ne 0 ]
    [[ "$output" =~ "80 bytes" ]]
}

@test "parse_device_spec - rejects a spec whose ID contains a space" {
    run parse_device_spec "/dev/sdb1:bad id"

    [ "$status" -ne 0 ]
    [[ "$output" =~ "space, comma, tab or newline" ]]
}

@test "resync_elapsed_file - distinct superblocks do not collide" {
    NMDSTAT_VALUES[sbName]="/a b.dat"
    local one one_again
    one=$(resync_elapsed_file)
    one_again=$(resync_elapsed_file)

    NMDSTAT_VALUES[sbName]="/a_b.dat"
    local two
    two=$(resync_elapsed_file)

    # Resume has to find the file pause wrote, so the name must be stable for a
    # given superblock...
    [ "$one" = "$one_again" ]
    # ...while still separating these two. A plain "tr '/ ' '__'" substitution
    # would map both to the same name.
    [ "$one" != "$two" ]
}

# Seed the state handle_check reads for a running check, so it skips
# get_all_nmdstat_values and takes the pause/cancel branch.
seed_running_check() {
    NMDSTAT_VALUES=(
        [mdState]=STARTED
        [mdResync]=1
        [mdResyncAction]="check P"
        [mdResyncCorr]=0
        [mdResyncPos]=100
        [mdResyncSize]=1000
        [sbName]=/test.dat
        [sbSynced]="${1:-0}"
    )
}

@test "handle_check PAUSE - carries elapsed time across pause, resume, pause" {
    export RESYNC_ELAPSED_DIR="$BATS_TMPDIR/resync-carry-$$"
    eval 'run_nmd_command() { return 0; }'

    # First pause, 60s after the check started.
    seed_running_check "$(( $(date +%s) - 60 ))"
    run handle_check PAUSE
    [ "$status" -eq 0 ]

    # Resuming makes the driver reset sbSynced, so a second pause 30s later
    # measures only that segment. Overwriting rather than accumulating would
    # discard the first 60s entirely.
    seed_running_check "$(( $(date +%s) - 30 ))"
    run handle_check PAUSE
    [ "$status" -eq 0 ]

    local saved_action saved
    { read -r saved_action; read -r saved; } < "$(echo "$RESYNC_ELAPSED_DIR"/resync_elapsed_*)"
    [ "$saved_action" = "check P" ]
    [ "$saved" -ge 90 ]
    [ "$saved" -le 92 ]

    rm -rf "$RESYNC_ELAPSED_DIR"
}

@test "collect_resync_status - a snapshot from another action is not inherited" {
    export RESYNC_ELAPSED_DIR="$BATS_TMPDIR/resync-action-$$"
    mkdir -p "$RESYNC_ELAPSED_DIR"

    # A check was paused earlier and its snapshot is still on disk, by design.
    NMDSTAT_VALUES=([sbName]=/test.dat)
    printf 'check P\n3600\n' > "$(resync_elapsed_file)"

    # The array then starts a reconstruction of its own accord. Its elapsed time
    # is its own; inheriting the paused check's hour would be nonsense.
    NMDSTAT_VALUES+=(
        [mdResync]=1
        [mdResyncAction]=recon
        [mdResyncCorr]=0
        [mdResyncPos]=100
        [mdResyncSize]=1000
        [mdResyncDt]=10
        [mdResyncDb]=5000
        [sbSynced]="$(( $(date +%s) - 5 ))"
    )
    collect_resync_status

    [ "${RESYNC_STATUS_DATA[elapsed_seconds]}" -lt 60 ]

    rm -rf "$RESYNC_ELAPSED_DIR"
}

@test "handle_check PAUSE - a rejected pause writes no snapshot" {
    export RESYNC_ELAPSED_DIR="$BATS_TMPDIR/resync-nopause-$$"
    eval 'run_nmd_command() { return 1; }'

    seed_running_check "$(( $(date +%s) - 60 ))"
    run handle_check PAUSE
    [ "$status" -ne 0 ]

    # The check is still running against the same sbSynced. A snapshot here
    # would be added to it by collect_resync_status and counted twice.
    run bash -c "ls '$RESYNC_ELAPSED_DIR'/resync_elapsed_* 2>/dev/null"
    [ "$status" -ne 0 ]

    rm -rf "$RESYNC_ELAPSED_DIR"
}

@test "handle_check CANCEL - a rejected cancel keeps the carried segment" {
    export RESYNC_ELAPSED_DIR="$BATS_TMPDIR/resync-nocancel-$$"
    eval 'run_nmd_command() { return 1; }'

    seed_running_check "$(( $(date +%s) - 30 ))"
    mkdir -p "$RESYNC_ELAPSED_DIR"
    local elapsed_file
    elapsed_file=$(resync_elapsed_file)
    echo 60 > "$elapsed_file"

    run handle_check CANCEL
    [ "$status" -ne 0 ]

    # The run the driver refused to stop still needs its carried time.
    [ -f "$elapsed_file" ]
    [ "$(cat "$elapsed_file")" -eq 60 ]

    rm -rf "$RESYNC_ELAPSED_DIR"
}
