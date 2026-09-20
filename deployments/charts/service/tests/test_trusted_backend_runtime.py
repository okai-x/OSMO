"""Exercise the rendered internal listener using the deployed Envoy version."""

# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

import base64
import hashlib
import http.client
import json
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from test_trusted_backend import CHART, listeners, render


class Upstream(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.headers.get('Upgrade', '').lower() == 'websocket':
            key = self.headers['Sec-WebSocket-Key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
            accept = base64.b64encode(hashlib.sha1(key.encode()).digest()).decode()
            self.send_response(101)
            self.send_header('Upgrade', 'websocket')
            self.send_header('Connection', 'Upgrade')
            self.send_header('Sec-WebSocket-Accept', accept)
            self.end_headers()
            return
        body = json.dumps({key.lower(): value for key, value in self.headers.items()}).encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        pass


class TrustedBackendRuntimeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        cls.upstream = ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
        cls.addClassCleanup(cls.upstream.server_close)
        threading.Thread(target=cls.upstream.serve_forever, daemon=True).start()
        cls.addClassCleanup(cls.upstream.shutdown)
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            cls.port = probe.getsockname()[1]
        listener = listeners(render(CHART, 'gateway.trustedBackend.enabled=true',
                                    'gateway.authz.enabled=false'))[1]
        del listener['@type']  # LDS wraps Listener in Any; static_resources does not.
        listener['address']['socket_address'] = {'address': '127.0.0.1', 'port_value': cls.port}
        clusters = []
        for name in ('osmo-agent', 'osmo-service'):
            clusters.append({
                'name': name, 'connect_timeout': '1s', 'type': 'STATIC',
                'load_assignment': {'cluster_name': name, 'endpoints': [{'lb_endpoints': [{
                    'endpoint': {'address': {'socket_address': {
                        'address': '127.0.0.1', 'port_value': cls.upstream.server_port}}}}]}]}})
        path = Path(cls.directory.name) / 'envoy.json'
        path.write_text(json.dumps({'static_resources': {
            'listeners': [listener], 'clusters': clusters}}))
        command = ['docker', 'run', '--rm', '--network', 'host',
                   '-v', f'{path}:/etc/envoy/test.json:ro',
                   '--entrypoint', 'envoy', 'envoyproxy/envoy:v1.38.1',
                   '-c', '/etc/envoy/test.json', '--concurrency', '1']
        subprocess.run(command + ['--mode', 'validate'], check=True)
        cls.container = subprocess.check_output(command[:2] + ['-d'] + command[2:], text=True).strip()
        cls.addClassCleanup(subprocess.run, ['docker', 'stop', cls.container],
                            check=True, capture_output=True)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            try:
                with socket.create_connection(('127.0.0.1', cls.port), timeout=1):
                    return
            except OSError:
                time.sleep(0.1)
        raise RuntimeError('Envoy did not start')

    def request(self, path: str, method: str = 'GET', headers: dict | None = None) -> tuple:
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=5)
        self.addCleanup(connection.close)
        connection.request(method, path, headers=headers or {})
        response = connection.getresponse()
        return response.status, response.read()

    def test_credentials_are_not_required_and_identity_is_fixed(self) -> None:
        status, body = self.request('/api/configs/backend/default', headers={
            'Authorization': 'Bearer test-only-invalid', 'Cookie': 'session=test-only',
            'X-Osmo-User': 'admin', 'X-Osmo-Roles': 'osmo-admin',
            'X-Osmo-Token-Name': 'admin', 'X-Osmo-Workflow-Id': 'other',
            'X-Osmo-Allowed-Pools': '*'})
        self.assertEqual(status, 200)
        received = json.loads(body)
        self.assertEqual(received['x-osmo-user'], 'osmo-backend')
        self.assertEqual(received['x-osmo-roles'], 'osmo-backend')
        self.assertEqual(received['x-osmo-token-name'], 'trusted-network')
        for header in ('authorization', 'cookie', 'x-osmo-workflow-id', 'x-osmo-allowed-pools'):
            self.assertNotIn(header, received)
        self.assertEqual(self.request('/api/configs/backend_test/gpu')[0], 200)

    def test_other_routes_and_config_writes_are_denied(self) -> None:
        for path in ('/api/auth/jwt/access_token', '/api/workflow', '/api/configs/service',
                     '/api/agent/../auth/login', '/'):
            with self.subTest(path=path):
                self.assertEqual(self.request(path)[0], 404)
        self.assertEqual(self.request('/api/configs/backend/default', method='PUT')[0], 404)

    def test_websocket_without_token(self) -> None:
        for path in ('/api/agent/worker/backend/default',
                     '/api/agent/listener/heartbeat/backend/default'):
            with self.subTest(path=path):
                self.assertEqual(self.request(path, headers={
                    'Connection': 'Upgrade', 'Upgrade': 'websocket',
                    'Sec-WebSocket-Key': 'dGhlIHNhbXBsZSBub25jZQ==',
                    'Sec-WebSocket-Version': '13'})[0], 101)


if __name__ == '__main__':
    unittest.main()
