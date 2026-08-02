lint:
    bash -n aur-safe-update
    bash -n tests/smoke-test.sh
    shellcheck aur-safe-update tests/smoke-test.sh

test:
    tests/smoke-test.sh

verify: lint test
