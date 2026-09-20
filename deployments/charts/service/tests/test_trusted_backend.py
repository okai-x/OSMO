"""Render checks for the credential-free internal operator entry point."""

# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

import subprocess
import unittest
from pathlib import Path

import yaml

CHART = Path(__file__).resolve().parents[1]


def render(chart: Path, *values: str) -> list[dict]:
    command = ['helm', 'template', 'test', str(chart), '--namespace', 'osmo']
    for value in values:
        command.extend(['--set', value])
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    return [document for document in yaml.safe_load_all(result.stdout) if document]


def resource(documents: list[dict], kind: str, name: str) -> dict:
    return next(document for document in documents
                if document['kind'] == kind and document['metadata']['name'] == name)


def listeners(documents: list[dict]) -> list[dict]:
    config = resource(documents, 'ConfigMap', 'osmo-gateway-envoy-config')
    return yaml.safe_load(config['data']['lds.yaml'])['resources']


class TrustedBackendTest(unittest.TestCase):
    def test_public_listener_is_unchanged(self) -> None:
        baseline = render(CHART)
        enabled = render(CHART, 'gateway.trustedBackend.enabled=true')
        self.assertEqual(listeners(baseline)[0], listeners(enabled)[0])
        self.assertEqual(len(listeners(baseline)), 1)
        self.assertEqual(len(listeners(enabled)), 2)
        self.assertEqual(resource(baseline, 'Service', 'osmo-gateway'),
                         resource(enabled, 'Service', 'osmo-gateway'))
        service = resource(enabled, 'Service', 'osmo-gateway-backend')
        self.assertEqual(service['spec']['type'], 'ClusterIP')
        self.assertEqual(service['spec']['ports'][0]['targetPort'], 10081)

    def test_routes_and_fixed_identity(self) -> None:
        documents = render(CHART, 'gateway.trustedBackend.enabled=true',
                           'gateway.authz.enabled=true')
        listener = listeners(documents)[1]
        manager = listener['filter_chains'][0]['filters'][0]['typed_config']
        routes = manager['route_config']['virtual_hosts'][0]['routes']
        self.assertEqual(routes[0]['match'], {'prefix': '/api/agent/'})
        self.assertEqual(routes[0]['route']['cluster'], 'osmo-agent')
        self.assertEqual(routes[1]['match']['headers'], [
            {'name': ':method', 'string_match': {'exact': 'GET'}}])
        self.assertEqual(routes[-1]['direct_response']['status'], 404)
        filters = manager['http_filters']
        self.assertNotIn('envoy.filters.http.jwt_authn', [f['name'] for f in filters])
        self.assertEqual(filters[1]['name'], 'envoy.filters.http.ext_authz')
        self.assertFalse(filters[1]['typed_config']['failure_mode_allow'])
        script = filters[0]['typed_config']['default_source_code']['inline_string']
        for header in ('x-osmo-user', 'x-osmo-roles'):
            self.assertIn(f"headers:replace('{header}', 'osmo-backend')", script)
        for header in ('authorization', 'cookie', 'x-osmo-workflow-id',
                       'x-osmo-allowed-pools'):
            self.assertIn(f"headers:remove('{header}')", script)

    def test_operator_needs_no_secret_or_developer_mode(self) -> None:
        documents = render(CHART.parent / 'backend-operator', 'global.loginMethod=none')
        for component in ('listener', 'worker'):
            deployment = resource(documents, 'Deployment', f'test-osmo-backend-{component}')
            pod = deployment['spec']['template']['spec']
            container = pod['containers'][0]
            args = container['args']
            self.assertEqual(args[args.index('--trust_network') + 1], 'true')
            for flag in ('--method', '--token_file', '--password_file', '--login_method'):
                self.assertNotIn(flag, args)
            self.assertNotIn('osmo-secret', [v['name'] for v in pod.get('volumes', [])])
            self.assertNotIn('osmo-secret', [v['name'] for v in container.get('volumeMounts', [])])
            self.assertTrue(pod['serviceAccountName'])

    def test_rejects_listener_port_conflicts(self) -> None:
        for value in ('gateway.trustedBackend.port=9901',
                      'gateway.trustedBackend.port=443',
                      'gateway.trustedBackend.port=8080',
                      'gateway.envoy.enabled=false',
                      'gateway.upstreams.agent.enabled=false'):
            with self.subTest(value=value), self.assertRaises(subprocess.CalledProcessError):
                render(CHART, 'gateway.trustedBackend.enabled=true',
                       'gateway.envoy.listenerPort=8080', value)


if __name__ == '__main__':
    unittest.main()
