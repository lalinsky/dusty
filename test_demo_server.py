#!/usr/bin/env python3
"""
Integration test for the Dusty demo server.
Tests server startup, request handling, and graceful shutdown.
"""

import http.client
import json
import os
import platform
import subprocess
import time
import unittest

HOST = "127.0.0.1"
PORT = 8080
BINARY_NAME = "basic-example" + (".exe" if platform.system() == "Windows" else "")
BINARY_PATH = os.path.join("zig-out", "bin", BINARY_NAME)
STARTUP_TIMEOUT = 10  # seconds
SHUTDOWN_TIMEOUT = 5  # seconds


class DemoServerTest(unittest.TestCase):
    """Integration tests for the Dusty demo server."""

    server_process = None

    @classmethod
    def setUpClass(cls):
        """Start the server before running tests."""
        if not os.path.exists(BINARY_PATH):
            raise unittest.SkipTest(
                f"Binary not found at {BINARY_PATH}. Run 'zig build' first."
            )

        cls.server_process = subprocess.Popen([BINARY_PATH])

        if not cls.wait_for_server():
            cls.server_process.kill()
            raise RuntimeError(
                f"Server did not start within {STARTUP_TIMEOUT} seconds"
            )

    @classmethod
    def tearDownClass(cls):
        """Shut down the server after all tests."""
        if cls.server_process is None:
            return

        cls.server_process.terminate()
        try:
            cls.server_process.wait(timeout=SHUTDOWN_TIMEOUT)
        except subprocess.TimeoutExpired:
            cls.server_process.kill()

    @classmethod
    def wait_for_server(cls, timeout: float = STARTUP_TIMEOUT) -> bool:
        """Wait for the server to be ready to accept connections."""
        start_time = time.time()
        while time.time() - start_time < timeout:
            try:
                conn = http.client.HTTPConnection(HOST, PORT, timeout=1)
                conn.request("GET", "/")
                response = conn.getresponse()
                conn.close()
                if response.status == 200:
                    return True
            except (ConnectionRefusedError, OSError):
                time.sleep(0.1)
        return False

    def send_request(self, method: str, path: str, body: str = None) -> tuple[int, str]:
        """Make an HTTP request and return (status, body)."""
        conn = http.client.HTTPConnection(HOST, PORT, timeout=5)
        conn.request(method, path, body=body)
        response = conn.getresponse()
        response_body = response.read().decode("utf-8")
        conn.close()
        return response.status, response_body

    def test_get_root(self):
        """Test GET / endpoint."""
        status, body = self.send_request("GET", "/")
        self.assertEqual(status, 200)
        self.assertEqual(body, "Hello World!\n")

    def test_get_user(self):
        """Test GET /users/:id endpoint."""
        status, body = self.send_request("GET", "/users/123")
        self.assertEqual(status, 200)
        self.assertEqual(body, "Hello User 123\n")

    def test_get_json(self):
        """Test GET /json endpoint."""
        status, body = self.send_request("GET", "/json")
        self.assertEqual(status, 200)
        data = json.loads(body)
        self.assertEqual(data["message"], "Hello from Dusty!")

    def test_post_data(self):
        """Test POST /posts endpoint with body."""
        test_body = "Test message"
        status, body = self.send_request("POST", "/posts", body=test_body)
        self.assertEqual(status, 200)
        self.assertIn("Counter:", body)
        self.assertIn(test_body, body)


if __name__ == "__main__":
    unittest.main()
