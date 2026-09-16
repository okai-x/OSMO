"""
SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
"""

import contextlib
import io
import unittest
from unittest import mock

from src.cli import cli, main_parser
from src.lib.utils import client, osmo_errors


class TestBackendList(unittest.TestCase):
    """Exercise backend listing through the public CLI parser and entry point."""

    def setUp(self):
        self.parser = main_parser.create_cli_parser()
        self.service_client = mock.Mock(spec=client.ServiceClient)

    def run_list(self, response):
        args = self.parser.parse_args(['backend', 'list'])
        self.service_client.request.return_value = response
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            args.func(self.service_client, args)
        self.service_client.request.assert_called_once_with(
            client.RequestMethod.GET, 'api/configs/backend')
        return output.getvalue()

    def test_entry_point_lists_online_and_offline_backends(self):
        self.service_client.request.return_value = {'backends': [
            {'name': 'gpu-cluster', 'description': 'GPU workers', 'online': True},
            {'name': 'cpu-cluster', 'description': 'CPU workers', 'online': False},
        ]}
        output = io.StringIO()
        with mock.patch.object(cli.sys, 'argv', ['osmo', 'backend', 'list']), \
                mock.patch.object(cli, 'configure_logging'), \
                mock.patch.object(cli.client, 'LoginManager'), \
                mock.patch.object(cli.client, 'ServiceClient', return_value=self.service_client), \
                contextlib.redirect_stdout(output), self.assertRaises(SystemExit) as raised:
            cli.main()
        self.assertEqual(raised.exception.code, 0)
        self.service_client.request.assert_called_once_with(
            client.RequestMethod.GET, 'api/configs/backend')
        self.assertEqual(
            output.getvalue(),
            'Name          Description   Status \n'
            '===================================\n'
            'gpu-cluster   GPU workers   ONLINE \n'
            'cpu-cluster   CPU workers   OFFLINE\n',
        )

    def test_empty_backend_list_prints_table_headers(self):
        output = self.run_list({'backends': []})
        for heading in ('Name', 'Description', 'Status'):
            self.assertIn(heading, output)
        self.assertNotIn('ONLINE', output)
        self.assertNotIn('OFFLINE', output)

    def test_missing_response_fields_raise_server_error(self):
        complete_backend = {'name': 'cluster', 'description': '', 'online': True}
        responses: list[dict[str, object]] = [{}]
        responses.extend({'backends': [{key: value for key, value in complete_backend.items()
                                        if key != missing}]} for missing in complete_backend)
        for response in responses:
            with self.subTest(response=response), self.assertRaisesRegex(
                    osmo_errors.OSMOServerError, 'Backend response is not properly formatted'):
                self.run_list(response)

    def test_request_failure_is_not_reported_as_an_empty_list(self):
        self.service_client.request.side_effect = osmo_errors.OSMOServerError('Access denied')
        with self.assertRaisesRegex(osmo_errors.OSMOServerError, 'Access denied'):
            self.run_list({'backends': []})

    def test_help_exposes_backend_list(self):
        for arguments, expected in ((['--help'], 'backend'), (['backend', '--help'], '{list}')):
            with self.subTest(arguments=arguments):
                output = io.StringIO()
                with contextlib.redirect_stdout(output), self.assertRaises(SystemExit) as raised:
                    self.parser.parse_args(arguments)
                self.assertEqual(raised.exception.code, 0)
                self.assertIn(expected, output.getvalue())

    def test_backend_requires_a_subcommand(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
            self.parser.parse_args(['backend'])
        self.assertEqual(raised.exception.code, 2)


if __name__ == '__main__':
    unittest.main()
