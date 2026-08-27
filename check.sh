#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

# Default values
TEST_FILTER=""
TEST_LOG_CAPTURE="true"
TEST_FAIL_FIRST="false"
TEST_VERBOSE="true"
CI_MODE=false
ZIO_BACKEND=""

# Parse arguments
usage() {
  echo "Usage: $0 [--test-filter \"test name\"] [--test-log-capture true|false] [--test-fail-first true|false] [--test-verbose true|false] [--ci] [--zio-backend epoll|io_uring|kqueue|poll]"
}
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        --test-filter)
            [[ $# -ge 2 ]] || { echo "--test-filter requires an argument"; usage; exit 1; }
            TEST_FILTER="$2"; shift 2
            ;;
        --test-log-capture)
            [[ $# -ge 2 ]] || { echo "--test-log-capture requires true|false"; usage; exit 1; }
            TEST_LOG_CAPTURE="$2"; shift 2
            ;;
        --test-fail-first)
            [[ $# -ge 2 ]] || { echo "--test-fail-first requires true|false"; usage; exit 1; }
            TEST_FAIL_FIRST="$2"; shift 2
            ;;
        --test-verbose)
            [[ $# -ge 2 ]] || { echo "--test-verbose requires true|false"; usage; exit 1; }
            TEST_VERBOSE="$2"; shift 2
            ;;
        --ci)
            CI_MODE=true
            shift
            ;;
        --zio-backend)
            [[ $# -ge 2 ]] || { echo "--zio-backend requires an argument"; usage; exit 1; }
            ZIO_BACKEND="$2"; shift 2
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

echo "=== Formatting code ==="
if [ "$CI_MODE" = true ]; then
    echo "Checking formatting (CI mode)..."
    zig fmt --check .
else
    echo "Formatting code..."
    zig fmt .
fi

# Set up environment variables for tests
if [ -n "$TEST_FILTER" ]; then
    export TEST_FILTER
fi
export TEST_LOG_CAPTURE="$TEST_LOG_CAPTURE"
export TEST_FAIL_FIRST="$TEST_FAIL_FIRST" 
export TEST_VERBOSE="$TEST_VERBOSE"

BUILD_ARGS=()
if [ -n "$ZIO_BACKEND" ]; then
    BUILD_ARGS+=("-Dzio_backend=$ZIO_BACKEND")
fi

echo "=== Building code ==="
zig build "${BUILD_ARGS[@]}"

echo "=== Building examples ==="
zig build examples "${BUILD_ARGS[@]}"

# Its own build.zig and its own zio, so the top-level build does not reach
# it and an API change can compile everywhere else and still break it.
# Takes no -Dzio_backend.
echo "=== Building httpbin example ==="
(cd examples/httpbin && zig build)

echo "=== Running unit tests ==="
if [ -n "$TEST_FILTER" ]; then
    echo "Running unit tests with filter: $TEST_FILTER"
else
    echo "Running all unit tests..."
fi
zig build test --summary all "${BUILD_ARGS[@]}"

echo "=== All checks passed! ==="
