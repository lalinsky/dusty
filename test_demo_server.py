#!/usr/bin/env python3
"""
Integration test for the Dusty demo server.
Tests server startup, request handling, and graceful shutdown.
"""

import subprocess
import http.client
import time
import signal
import sys
import json
import os
import platform
from typing import Optional

PORT = 8080
HOST = "127.0.0.1"
BINARY_NAME = "basic-example" + (".exe" if platform.system() == "Windows" else "")
BINARY_PATH = os.path.join("zig-out", "bin", BINARY_NAME)
STARTUP_TIMEOUT = 10  # seconds
SHUTDOWN_TIMEOUT = 5  # seconds


def wait_for_server(timeout: float = STARTUP_TIMEOUT) -> bool:
    """Wait for the server to be ready to accept connections."""
    start_time = time.time()
    while time.time() - start_time < timeout:
        try:
            conn = http.client.HTTPConnection(HOST, PORT, timeout=1)
            conn.request("GET", "/")
            response = conn.getresponse()
            conn.close()
            if response.status == 200:
                print(f"[OK] Server ready on {HOST}:{PORT}")
                return True
        except (ConnectionRefusedError, OSError):
            time.sleep(0.1)
    return False


def test_get_root() -> bool:
    """Test GET / endpoint."""
    try:
        conn = http.client.HTTPConnection(HOST, PORT, timeout=5)
        conn.request("GET", "/")
        response = conn.getresponse()
        body = response.read().decode('utf-8')
        conn.close()

        if response.status != 200:
            print(f"[FAIL] GET / failed: expected status 200, got {response.status}")
            return False

        if body != "Hello World!\n":
            print(f"[FAIL] GET / failed: expected 'Hello World!\\n', got '{body}'")
            return False

        print("[OK] GET / returned correct response")
        return True
    except Exception as e:
        print(f"[FAIL] GET / failed with exception: {e}")
        return False


def test_get_user() -> bool:
    """Test GET /users/:id endpoint."""
    try:
        conn = http.client.HTTPConnection(HOST, PORT, timeout=5)
        conn.request("GET", "/users/123")
        response = conn.getresponse()
        body = response.read().decode('utf-8')
        conn.close()

        if response.status != 200:
            print(f"[FAIL] GET /users/123 failed: expected status 200, got {response.status}")
            return False

        if body != "Hello User 123\n":
            print(f"[FAIL] GET /users/123 failed: expected 'Hello User 123\\n', got '{body}'")
            return False

        print("[OK] GET /users/123 returned correct response")
        return True
    except Exception as e:
        print(f"[FAIL] GET /users/123 failed with exception: {e}")
        return False


def test_get_json() -> bool:
    """Test GET /json endpoint."""
    try:
        conn = http.client.HTTPConnection(HOST, PORT, timeout=5)
        conn.request("GET", "/json")
        response = conn.getresponse()
        body = response.read().decode('utf-8')
        conn.close()

        if response.status != 200:
            print(f"[FAIL] GET /json failed: expected status 200, got {response.status}")
            return False

        # Verify it's valid JSON
        try:
            data = json.loads(body)
            if "message" not in data or data["message"] != "Hello from Dusty!":
                print(f"[FAIL] GET /json failed: unexpected JSON content: {data}")
                return False
        except json.JSONDecodeError as e:
            print(f"[FAIL] GET /json failed: invalid JSON: {e}")
            return False

        print("[OK] GET /json returned valid JSON response")
        return True
    except Exception as e:
        print(f"[FAIL] GET /json failed with exception: {e}")
        return False


def test_post_data() -> bool:
    """Test POST /posts endpoint with body."""
    try:
        conn = http.client.HTTPConnection(HOST, PORT, timeout=5)
        test_body = "Test message"
        conn.request("POST", "/posts", body=test_body)
        response = conn.getresponse()
        body = response.read().decode('utf-8')
        conn.close()

        if response.status != 200:
            print(f"[FAIL] POST /posts failed: expected status 200, got {response.status}")
            return False

        # Response should contain counter and echo the body
        if "Counter:" not in body or test_body not in body:
            print(f"[FAIL] POST /posts failed: unexpected response: '{body}'")
            return False

        print("[OK] POST /posts echoed request body correctly")
        return True
    except Exception as e:
        print(f"[FAIL] POST /posts failed with exception: {e}")
        return False


def main() -> int:
    """Run the integration test."""
    print("=" * 60)
    print("Dusty Demo Server Integration Test")
    print("=" * 60)

    # Check if binary exists
    if not os.path.exists(BINARY_PATH):
        print(f"[FAIL] Binary not found at {BINARY_PATH}")
        print("  Run 'zig build' first to build the demo server")
        return 1

    print(f"\nStarting server: {BINARY_PATH}")

    # Start the server process
    server_process = subprocess.Popen([BINARY_PATH])

    try:
        # Wait for server to be ready
        print(f"Waiting for server on {HOST}:{PORT}...")
        if not wait_for_server():
            print(f"[FAIL] Server did not start within {STARTUP_TIMEOUT} seconds")
            return 1

        print("\nRunning tests...")
        print("-" * 60)

        # Run all tests
        all_passed = True
        all_passed &= test_get_root()
        all_passed &= test_get_user()
        all_passed &= test_get_json()
        all_passed &= test_post_data()

        print("-" * 60)

        if not all_passed:
            print("\n[FAIL] Some tests failed")
            return 1

        print("\n[OK] All tests passed")

        # Test graceful shutdown
        print("\nSending SIGINT for graceful shutdown...")
        server_process.send_signal(signal.SIGINT)

        # Wait for process to exit
        try:
            exit_code = server_process.wait(timeout=SHUTDOWN_TIMEOUT)
            if exit_code == 0:
                print("[OK] Server shut down gracefully")
            else:
                print(f"[WARN] Server exited with code {exit_code}")
                # Don't fail the test for non-zero exit on SIGINT
        except subprocess.TimeoutExpired:
            print(f"[FAIL] Server did not exit within {SHUTDOWN_TIMEOUT} seconds")
            server_process.kill()
            return 1

        print("\n" + "=" * 60)
        print("Integration test completed successfully!")
        print("=" * 60)
        return 0

    except Exception as e:
        print(f"\n[FAIL] Test failed with exception: {e}")
        return 1
    finally:
        # Ensure server is terminated
        if server_process.poll() is None:
            print("\nCleaning up: terminating server...")
            server_process.terminate()
            try:
                server_process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                server_process.kill()


if __name__ == "__main__":
    sys.exit(main())
