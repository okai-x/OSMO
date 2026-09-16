"""
SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

SPDX-License-Identifier: Apache-2.0
"""
import os
import tempfile
import unittest

from src.lib.utils import version


class TestLoadVersion(unittest.TestCase):
    """ load_version combines version.yaml with an optional build tag file. """

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()  # pylint: disable=consider-using-with
        self.addCleanup(self.directory.cleanup)

    def _write(self, name: str, content: str) -> None:
        with open(os.path.join(self.directory.name, name), 'w', encoding='UTF-8') as file:
            file.write(content)

    def test_without_tag_file_keeps_plain_version(self):
        self._write(version.VERSION_FILE, 'major: 6\nminor: 4\nrevision: 0\nhash: ""\n')
        self.assertEqual(str(version.load_version(self.directory.name)), '6.4.0')

    def test_tag_file_becomes_hash_suffix(self):
        self._write(version.VERSION_FILE, 'major: 6\nminor: 4\nrevision: 0\nhash: ""\n')
        self._write(version.VERSION_TAG_FILE, 'prana1a2b3c4d\n')
        loaded = version.load_version(self.directory.name)
        self.assertEqual(loaded.hash, 'prana1a2b3c4d')
        self.assertEqual(str(loaded), '6.4.0.prana1a2b3c4d')
        # The suffix must survive the service's parser and not affect ordering.
        parsed = version.Version.from_string(str(loaded))
        self.assertEqual(parsed.hash, 'prana1a2b3c4d')
        self.assertFalse(parsed < version.Version.from_string('6.4.0'))
        self.assertFalse(version.Version.from_string('6.4.0') < parsed)

    def test_release_hash_wins_over_tag_file(self):
        self._write(version.VERSION_FILE, 'major: 6\nminor: 4\nrevision: 0\nhash: "abc1234"\n')
        self._write(version.VERSION_TAG_FILE, 'prana1a2b3c4d')
        self.assertEqual(str(version.load_version(self.directory.name)), '6.4.0.abc1234')

    def test_blank_tag_file_is_ignored(self):
        self._write(version.VERSION_FILE, 'major: 6\nminor: 4\nrevision: 0\nhash: ""\n')
        self._write(version.VERSION_TAG_FILE, '  \n')
        self.assertEqual(str(version.load_version(self.directory.name)), '6.4.0')


if __name__ == '__main__':
    unittest.main()
