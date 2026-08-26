#!/usr/bin/env python3
"""
Integration test for the httpbin example.

Drives the server with Python's stdlib HTTP client rather than dusty's
own, so the responses are checked by something that shares none of its
assumptions.
"""

import http.client
import json
import os
import platform
import socket
import subprocess
import tempfile
import time
import unittest

HOST = "127.0.0.1"
BINARY_NAME = "server" + (".exe" if platform.system() == "Windows" else "")
BINARY_PATH = os.path.join(os.path.dirname(__file__), "zig-out", "bin", BINARY_NAME)
STARTUP_TIMEOUT = 30  # seconds
SHUTDOWN_TIMEOUT = 5  # seconds


def free_port() -> int:
    """A port nothing is listening on, so parallel jobs do not collide."""
    with socket.socket() as s:
        s.bind((HOST, 0))
        return s.getsockname()[1]


def parse_sse(raw: bytes):
    """Events as (event, id, data) triples, per the text/event-stream grammar.

    Written from the spec rather than from how dusty emits them, so a
    change in framing shows up as a parse failure here.
    """
    events, fields, data = [], {}, []
    for line in raw.decode().split("\n"):
        if line == "":
            if fields or data:
                events.append((fields.get("event"), fields.get("id"), "\n".join(data)))
                fields, data = {}, []
            continue
        name, _, value = line.partition(":")
        if value.startswith(" "):
            value = value[1:]
        if name == "data":
            data.append(value)
        else:
            fields[name] = value
    return events


class HttpbinTest(unittest.TestCase):
    server_process = None
    server_log = None
    port = None

    @classmethod
    def setUpClass(cls):
        if not os.path.exists(BINARY_PATH):
            raise unittest.SkipTest(
                f"Binary not found at {BINARY_PATH}. Run 'zig build' first."
            )

        cls.port = free_port()
        # Captured rather than inherited: the server logs every request, so
        # sharing our stderr both drowns the results and kills the server
        # if whatever is reading them stops early.
        cls.server_log = tempfile.TemporaryFile()
        cls.server_process = subprocess.Popen(
            [BINARY_PATH, "-l", f"{HOST}:{cls.port}"],
            stdout=cls.server_log,
            stderr=subprocess.STDOUT,
        )

        if not cls.wait_for_server():
            exit_code = cls.server_process.poll()
            # Where it is stuck is the whole question when a server is alive
            # but silent, and that cannot be guessed at from another machine.
            stacks = cls.sample_stacks() if exit_code is None else ""
            cls.server_process.kill()
            raise RuntimeError(
                f"Server never answered on {HOST}:{cls.port}.\n"
                f"binary: {BINARY_PATH}\n"
                f"exited: {'no, still running' if exit_code is None else exit_code}\n"
                f"output:\n{cls.read_log()}\n"
                f"stacks:\n{stacks}"
            )

    @classmethod
    def tearDownClass(cls):
        if cls.server_process is not None:
            cls.server_process.terminate()
            try:
                cls.server_process.wait(timeout=SHUTDOWN_TIMEOUT)
            except subprocess.TimeoutExpired:
                cls.server_process.kill()
        if cls.server_log is not None:
            cls.server_log.close()

    @classmethod
    def sample_stacks(cls) -> str:
        """Best effort: what every thread of the hung server is doing."""
        pid = str(cls.server_process.pid)
        system = platform.system()
        if system == "Darwin":
            argv = ["sample", pid, "2", "-mayDie"]
        elif system == "Linux":
            argv = ["eu-stack", "-p", pid]
        else:
            return f"(no sampler for {system})"
        try:
            done = subprocess.run(argv, capture_output=True, text=True, timeout=30)
            return done.stdout or done.stderr or "(sampler produced nothing)"
        except (OSError, subprocess.SubprocessError) as e:
            return f"({' '.join(argv)} failed: {e})"

    @classmethod
    def read_log(cls) -> str:
        cls.server_log.seek(0)
        return cls.server_log.read().decode("utf-8", "replace")

    @classmethod
    def wait_for_server(cls, timeout: float = STARTUP_TIMEOUT) -> bool:
        deadline = time.time() + timeout
        while time.time() < deadline:
            # A server that has already exited is never going to answer,
            # and the exit code says more than the timeout would.
            if cls.server_process.poll() is not None:
                return False
            try:
                conn = http.client.HTTPConnection(HOST, cls.port, timeout=1)
                conn.request("GET", "/ip")
                response = conn.getresponse()
                conn.close()
                if response.status == 200:
                    return True
            except (ConnectionRefusedError, OSError):
                time.sleep(0.1)
        return False

    def request(self, method, path, body=None, headers=None):
        """Returns (status, headers, body bytes)."""
        conn = http.client.HTTPConnection(HOST, self.port, timeout=5)
        try:
            conn.request(method, path, body=body, headers=headers or {})
            response = conn.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            conn.close()

    def get_json(self, path, method="GET", body=None, headers=None):
        status, _, raw = self.request(method, path, body=body, headers=headers)
        self.assertEqual(status, 200, raw)
        return json.loads(raw)

    def raw_exchange(self, request: str) -> bytes:
        """Everything the server sends back, headers included.

        `http.client` knows a HEAD response carries no body and does not
        read one, so it cannot see a server that sends one anyway. Asking
        for the connection to close makes reading to EOF the whole reply.
        """
        with socket.create_connection((HOST, self.port), timeout=5) as sock:
            sock.sendall(request.encode())
            chunks = []
            while True:
                chunk = sock.recv(4096)
                if not chunk:
                    return b"".join(chunks)
                chunks.append(chunk)

    # Index

    def test_index_lists_every_endpoint(self):
        status, headers, raw = self.request("GET", "/")
        self.assertEqual(status, 200)
        self.assertIn("text/plain", headers["Content-Type"])
        page = raw.decode()
        # Listed here so a route added without a line in the index, or a
        # line left behind by one that went away, shows up as a failure.
        for path in (
            "/get",
            "/post",
            "/put",
            "/patch",
            "/delete",
            "/anything",
            "/headers",
            "/ip",
            "/user-agent",
            "/status/:code",
            "/bytes/:n",
            "/stream/:n",
            "/stream-bytes/:n",
            "/delay/:seconds",
            "/cookies",
            "/cookies/set",
        ):
            with self.subTest(path=path):
                self.assertIn(path, page)

    # Reflection

    def test_get_reflects_the_request(self):
        data = self.get_json("/get?a=1&b=hello%20world")
        self.assertEqual(data["args"], {"a": "1", "b": "hello world"})
        self.assertEqual(data["origin"], HOST)
        self.assertTrue(data["url"].endswith("/get?a=1&b=hello%20world"))
        self.assertIn("Host", data["headers"])
        # No body was sent, so the body fields are absent rather than null.
        self.assertNotIn("data", data)
        self.assertNotIn("form", data)

    def test_repeated_header_becomes_a_list(self):
        # A JSON object cannot hold the same key twice.
        conn = http.client.HTTPConnection(HOST, self.port, timeout=5)
        conn.putrequest("GET", "/headers")
        conn.putheader("X-Tag", "a")
        conn.putheader("X-Tag", "b")
        conn.endheaders()
        response = conn.getresponse()
        data = json.loads(response.read())
        conn.close()
        self.assertEqual(data["headers"]["X-Tag"], ["a", "b"])

    def test_user_agent_and_ip(self):
        data = self.get_json("/user-agent", headers={"User-Agent": "integration/1.0"})
        self.assertEqual(data["user_agent"], "integration/1.0")
        self.assertEqual(self.get_json("/ip")["origin"], HOST)

    # Bodies

    def test_post_form(self):
        data = self.get_json(
            "/post",
            method="POST",
            body="x=1&y=hello%20world",
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        self.assertEqual(data["form"], {"x": "1", "y": "hello world"})
        self.assertIsNone(data["json"])
        self.assertEqual(data["files"], {})

    def test_post_json(self):
        data = self.get_json(
            "/post",
            method="POST",
            body='{"k": [1, 2]}',
            headers={"Content-Type": "application/json"},
        )
        self.assertEqual(data["json"], {"k": [1, 2]})
        self.assertEqual(data["form"], {})

    def test_post_text_reports_json_null(self):
        # The key is present and null, which is what a client checks to
        # see whether its POST round-tripped.
        data = self.get_json(
            "/post",
            method="POST",
            body="raw text",
            headers={"Content-Type": "text/plain"},
        )
        self.assertEqual(data["data"], "raw text")
        self.assertIsNone(data["json"])

    def test_malformed_form_is_rejected(self):
        status, _, raw = self.request(
            "POST",
            "/post",
            body="ok=1&bad%ZZ=2",
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        self.assertEqual(status, 400)
        self.assertEqual(json.loads(raw)["error"], "Invalid form body")

    def test_anything_reports_the_method(self):
        for method in ("GET", "POST", "PUT", "PATCH", "DELETE"):
            with self.subTest(method=method):
                data = self.get_json("/anything", method=method, body="a=1")
                self.assertEqual(data["method"], method)

    def test_status_and_delay_answer_any_method(self):
        # Registered for every method, like /anything.
        for method in ("GET", "POST", "PUT", "PATCH", "DELETE"):
            with self.subTest(method=method):
                status, _, _ = self.request(method, "/status/204")
                self.assertEqual(status, 204)
                status, _, _ = self.request(method, "/delay/0")
                self.assertEqual(status, 200)

    def test_body_methods_have_their_own_paths(self):
        for method, path in (
            ("POST", "/post"),
            ("PUT", "/put"),
            ("PATCH", "/patch"),
            ("DELETE", "/delete"),
        ):
            with self.subTest(method=method):
                status, _, _ = self.request(method, path, body="a=1")
                self.assertEqual(status, 200)

    # Status

    def test_status_code_is_echoed(self):
        status, _, _ = self.request("GET", "/status/418")
        self.assertEqual(status, 418)

    def test_unusable_status_codes_are_refused(self):
        for path, message in (
            ("/status/abc", "Invalid status code"),
            ("/status/250", "Unsupported status code"),
        ):
            with self.subTest(path=path):
                status, _, raw = self.request("GET", path)
                self.assertEqual(status, 400)
                self.assertEqual(json.loads(raw)["error"], message)

    def test_not_found_is_json(self):
        status, headers, raw = self.request("GET", "/no-such-endpoint")
        self.assertEqual(status, 404)
        self.assertIn("application/json", headers["Content-Type"])
        self.assertEqual(json.loads(raw), {"error": "Not Found", "status": 404})

    # Bytes and streaming

    def test_bytes_has_a_declared_length(self):
        status, headers, raw = self.request("GET", "/bytes/1024")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Length"], "1024")
        self.assertNotIn("Transfer-Encoding", headers)
        self.assertEqual(len(raw), 1024)

    def test_bytes_is_capped(self):
        _, _, raw = self.request("GET", "/bytes/999999")
        self.assertEqual(len(raw), 100 * 1024)

    def test_seed_decides_whether_bytes_repeat(self):
        _, _, first = self.request("GET", "/bytes/64?seed=7")
        _, _, again = self.request("GET", "/bytes/64?seed=7")
        _, _, other = self.request("GET", "/bytes/64?seed=8")
        self.assertEqual(first, again)
        self.assertNotEqual(first, other)
        # Without a usable seed every response is fresh.
        _, _, a = self.request("GET", "/bytes/64")
        _, _, b = self.request("GET", "/bytes/64")
        self.assertNotEqual(a, b)

    def test_stream_bytes_is_chunked(self):
        status, headers, raw = self.request("GET", "/stream-bytes/512")
        self.assertEqual(status, 200)
        self.assertEqual(headers.get("Transfer-Encoding"), "chunked")
        self.assertNotIn("Content-Length", headers)
        self.assertEqual(len(raw), 512)

    def test_stream_emits_one_object_per_line(self):
        status, headers, raw = self.request("GET", "/stream/5")
        self.assertEqual(status, 200)
        self.assertEqual(headers.get("Transfer-Encoding"), "chunked")
        lines = [json.loads(line) for line in raw.splitlines() if line.strip()]
        self.assertEqual([line["id"] for line in lines], [0, 1, 2, 3, 4])

    def test_sse_is_chunked(self):
        status, headers, _ = self.request("GET", "/sse/3")
        self.assertEqual(status, 200)
        self.assertEqual(headers.get("Content-Type"), "text/event-stream")
        # No length is known up front, so the stream is framed by chunks
        # rather than by closing the connection.
        self.assertEqual(headers.get("Transfer-Encoding"), "chunked")
        self.assertNotIn("Content-Length", headers)

    def test_sse_emits_one_event_each(self):
        status, _, raw = self.request("GET", "/sse/3")
        self.assertEqual(status, 200)
        events = parse_sse(raw)
        self.assertEqual([name for name, _, _ in events], ["tick"] * 3)
        self.assertEqual([id_ for _, id_, _ in events], ["0", "1", "2"])
        self.assertEqual([json.loads(data)["id"] for _, _, data in events], [0, 1, 2])

    def test_sse_leaves_the_connection_reusable(self):
        """Chunked framing ends the stream without ending the connection."""
        conn = http.client.HTTPConnection(HOST, self.port, timeout=5)
        try:
            conn.request("GET", "/sse/2")
            first = conn.getresponse()
            self.assertEqual(first.status, 200)
            self.assertEqual(len(parse_sse(first.read())), 2)

            # Would raise if the server had hung up after the stream.
            conn.request("GET", "/get")
            second = conn.getresponse()
            self.assertEqual(second.status, 200)
            json.loads(second.read())
        finally:
            conn.close()

    def test_sse_count_is_validated(self):
        status, _, raw = self.request("GET", "/sse/abc")
        self.assertEqual(status, 400)
        self.assertEqual(json.loads(raw)["error"], "Invalid count")

    def test_delay_waits(self):
        start = time.monotonic()
        status, _, _ = self.request("GET", "/delay/0.5")
        self.assertEqual(status, 200)
        self.assertGreaterEqual(time.monotonic() - start, 0.4)

    def test_unusable_delays_are_refused(self):
        for value in ("abc", "nan", "inf"):
            with self.subTest(value=value):
                status, _, raw = self.request("GET", f"/delay/{value}")
                self.assertEqual(status, 400)
                self.assertEqual(json.loads(raw)["error"], "Invalid delay")

    # Cookies

    def test_cookies_round_trip(self):
        status, headers, _ = self.request("GET", "/cookies/set?a=1&b=2")
        self.assertEqual(status, 302)
        self.assertEqual(headers["Location"], "/cookies")

        data = self.get_json("/cookies", headers={"Cookie": "a=1; b=2"})
        self.assertEqual(data["cookies"], {"a": "1", "b": "2"})

    def test_cookies_that_would_inject_are_refused(self):
        for query, message in (
            ("bad;name=1", "Invalid cookie name"),
            ("ok=va;lue", "Invalid cookie value"),
        ):
            with self.subTest(query=query):
                status, headers, raw = self.request("GET", f"/cookies/set?{query}")
                self.assertEqual(status, 400)
                self.assertEqual(json.loads(raw)["error"], message)
                # Rejecting the batch must not leave earlier ones attached.
                self.assertNotIn("Set-Cookie", headers)

    # HEAD

    def test_head_reports_the_length_but_sends_no_body(self):
        reply = self.raw_exchange(
            f"HEAD /bytes/16 HTTP/1.1\r\nHost: {HOST}\r\nConnection: close\r\n\r\n"
        )
        head, separator, body = reply.partition(b"\r\n\r\n")
        self.assertEqual(separator, b"\r\n\r\n", reply)
        # The length a GET would have reported...
        self.assertIn(b"Content-Length: 16", head)
        # ...and not one byte of it.
        self.assertEqual(body, b"")

    def test_head_of_a_chunked_route_sends_no_chunks(self):
        reply = self.raw_exchange(
            f"HEAD /stream/3 HTTP/1.1\r\nHost: {HOST}\r\nConnection: close\r\n\r\n"
        )
        head, separator, body = reply.partition(b"\r\n\r\n")
        self.assertEqual(separator, b"\r\n\r\n", reply)
        # The framing a GET would have announced, with nothing framed by
        # it -- not even the terminating zero-length chunk.
        self.assertIn(b"Transfer-Encoding: chunked", head)
        self.assertEqual(body, b"")

    def test_head_is_answered_without_its_own_route(self):
        # /get is registered for GET alone, so answering HEAD at all is
        # the router falling back.
        status, headers, _ = self.request("HEAD", "/get")
        self.assertEqual(status, 200)
        self.assertIn("application/json", headers["Content-Type"])

    # Connection reuse

    def test_a_reused_connection_keeps_reporting_the_peer(self):
        conn = http.client.HTTPConnection(HOST, self.port, timeout=5)
        try:
            origins = []
            for _ in range(3):
                conn.request("GET", "/ip")
                response = conn.getresponse()
                origins.append(json.loads(response.read())["origin"])
            self.assertEqual(origins, [HOST] * 3)
        finally:
            conn.close()


if __name__ == "__main__":
    unittest.main()
