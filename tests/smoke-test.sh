#!/usr/bin/env bash
set -Eeuo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$project_root/aur-safe-update"
work_dir="$(mktemp -d)"
mock_bin="$work_dir/bin"
helper_log="$work_dir/helper.log"
stdout_log="$work_dir/stdout.log"
stderr_log="$work_dir/stderr.log"
passed=0

trap 'rm -rf -- "$work_dir"' EXIT
mkdir -p -- "$mock_bin"

cat > "$mock_bin/paru" <<'MOCK'
#!/usr/bin/env bash
if [[ " $* " == *" -Qua "* ]]; then
    printf '%s' "${MOCK_UPDATES:-}"
    exit "${MOCK_LIST_STATUS:-0}"
fi
printf '%s\n' "$*" >> "$MOCK_HELPER_LOG"
exit "${MOCK_HELPER_STATUS:-0}"
MOCK

cat > "$mock_bin/pacman" <<'MOCK'
#!/usr/bin/env bash
if [[ "${MOCK_PACMAN_STATUS:-0}" != 0 ]]; then
    exit "$MOCK_PACMAN_STATUS"
fi
printf '%s' "${MOCK_FOREIGN:-}"
MOCK

cat > "$mock_bin/curl" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == "--disable" ]] || exit 90

https_only=0
for argument in "$@"; do
    [[ "$argument" == "=https" ]] && https_only=1
done
((https_only)) || exit 91

url="${!#}"
if [[ "$url" == "$AURWATCH_API" ]]; then
    [[ "${MOCK_API_STATUS:-0}" == 0 ]] || exit "$MOCK_API_STATUS"
    printf '%s' "$MOCK_VERDICT"
elif [[ "$url" == "$AUR_RPC" ]]; then
    [[ "${MOCK_RPC_STATUS:-0}" == 0 ]] || exit "$MOCK_RPC_STATUS"
    printf '%s' "$MOCK_AUR_INFO"
else
    exit 22
fi
MOCK

chmod +x "$mock_bin/paru" "$mock_bin/pacman" "$mock_bin/curl"

fail_case() {
    local name="$1"
    local message="$2"

    printf 'FAIL: %s: %s\n' "$name" "$message" >&2
    printf '%s\n' '--- stdout ---' >&2
    cat "$stdout_log" >&2
    printf '%s\n' '--- stderr ---' >&2
    cat "$stderr_log" >&2
    exit 1
}

run_case() {
    local name="$1"
    local expected_exit="$2"
    local expected_helper="$3"
    local stdout_pattern="$4"
    local stderr_pattern="$5"
    local actual_exit
    local actual_helper=""
    local stdout_content
    local stderr_content
    shift 5

    rm -f -- "$helper_log" "$stdout_log" "$stderr_log"

    set +e
    env \
        "PATH=$mock_bin:$PATH" \
        "AURWATCH_API=https://mock.test/check" \
        "AUR_RPC=https://mock.test/info" \
        "MOCK_HELPER_LOG=$helper_log" \
        $'MOCK_UPDATES=demo 1.0 -> 2.0\n' \
        $'MOCK_FOREIGN=demo\n' \
        'MOCK_VERDICT={"pkg":"demo","status":"clean","rules":[],"last_scanned":"2026-08-01T00:00:00Z"}' \
        'MOCK_AUR_INFO={"results":[{"Name":"demo","LastModified":1000}]}' \
        "$@" \
        "$script" --needed >"$stdout_log" 2>"$stderr_log"
    actual_exit=$?
    set -e

    [[ -f "$helper_log" ]] && actual_helper="$(<"$helper_log")"
    stdout_content="$(<"$stdout_log")"
    stderr_content="$(<"$stderr_log")"

    [[ "$actual_exit" == "$expected_exit" ]] ||
        fail_case "$name" "expected exit $expected_exit, got $actual_exit"
    [[ "$actual_helper" == "$expected_helper" ]] ||
        fail_case "$name" "expected helper invocation '$expected_helper', got '$actual_helper'"
    [[ -z "$stdout_pattern" || "$stdout_content" == *"$stdout_pattern"* ]] ||
        fail_case "$name" "stdout did not contain '$stdout_pattern'"
    [[ -z "$stderr_pattern" || "$stderr_content" == *"$stderr_pattern"* ]] ||
        fail_case "$name" "stderr did not contain '$stderr_pattern'"

    printf 'PASS: %s\n' "$name"
    ((passed += 1))
}

run_case \
    clean-current 0 '-Syu --needed' '[CLEAN]   demo' ''

run_case \
    pacman-failure 2 '' '' \
    'Could not enumerate installed foreign packages' \
    'MOCK_PACMAN_STATUS=1'

run_case \
    mismatched-api-package 3 '' \
    'invalid or mismatched response' '' \
    'MOCK_VERDICT={"pkg":"other","status":"clean","last_scanned":"2026-08-01T00:00:00Z"}'

run_case \
    missing-aur-metadata 3 '' \
    'current AUR metadata is missing or invalid' '' \
    'MOCK_AUR_INFO={"results":[]}'

run_case \
    unknown-noninteractive-fail-open 4 '' \
    '[UNKNOWN] demo' 'Interactive review required' \
    'AURWATCH_FAIL_OPEN=1' \
    'MOCK_VERDICT={"pkg":"demo","status":"unexpected","last_scanned":"2026-08-01T00:00:00Z"}'

run_case \
    stale-high-fail-open 3 '' \
    '[HIGH]    demo: danger' '' \
    'AURWATCH_FAIL_OPEN=1' \
    'MOCK_VERDICT={"pkg":"demo","status":"high","rules":["danger"],"last_scanned":""}'

run_case \
    no-aur-updates 0 '-Syu --needed' \
    'no AUR upgrades found' '' \
    'MOCK_UPDATES=' \
    'MOCK_FOREIGN='

run_case \
    insecure-endpoint 64 '' '' \
    'AURWATCH_API and AUR_RPC must use HTTPS' \
    'AURWATCH_API=http://mock.test/check'

printf '%d smoke tests passed.\n' "$passed"
