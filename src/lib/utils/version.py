"""
SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved. # pylint: disable=line-too-long

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
import re
from typing import Dict

import pydantic
import yaml

from . import osmo_errors

VERSION_FILE = 'version.yaml'
# Written at build time by //src/lib/utils:version_tag (see bzl/prana_status.sh).
VERSION_TAG_FILE = 'version_tag.txt'
VERSION_HEADER = 'x-osmo-client-version'
SERVICE_VERSION_HEADER = 'x-osmo-service-version'
WARNING_HEADER = 'x-osmo-warning'


class Version(pydantic.BaseModel):
    """ A class to maintain version information. """
    model_config = pydantic.ConfigDict(coerce_numbers_to_str=True)

    major: str
    minor: str = '0'
    revision: str = '0'
    hash: str = ''

    def __str__(self):
        """ Gets the version number of OSMO. """
        version = '.'.join([self.major, self.minor, self.revision])
        # Development version will not have hash
        if self.hash:
            version += f'.{self.hash}'
        return version

    def __lt__(self, other: 'Version') -> bool:  # type: ignore[override]
        self_values = tuple(map(int, [self.major, self.minor, self.revision]))
        other_values = tuple(map(int, [other.major, other.minor, other.revision]))
        return self_values < other_values


    @classmethod
    def from_string(cls, version_str: str) -> 'Version':
        kwargs = {}
        version_pattern = re.compile(r'^\d+\.\d+\.\d+(\.[a-zA-Z0-9]+)?$')
        if not version_pattern.match(version_str):
            raise osmo_errors.OSMOError('Version should be of the format major.minor.revision')
        version_list = version_str.split('.')
        kwargs['major'] = version_list[0]
        if len(version_list) > 1:
            kwargs['minor'] = version_list[1]
        if len(version_list) > 2:
            kwargs['revision'] = version_list[2]
        if len(version_list) > 3:
            kwargs['hash'] = version_list[3]
        return Version(**kwargs)

    @classmethod
    def from_dict(cls, version_dict: Dict) -> 'Version':
        kwargs = {}
        if 'major' not in version_dict or 'minor' not in version_dict\
            or 'revision' not in version_dict:
            raise osmo_errors.OSMOError('Version dict should contain major, minor, and revision')
        kwargs['major'] = version_dict['major']
        kwargs['minor'] = version_dict['minor']
        kwargs['revision'] = version_dict['revision']
        if 'hash' in version_dict and version_dict['hash']:
            kwargs['hash'] = version_dict['hash']
        return Version(**kwargs)


def _module_directories() -> list[str]:
    """ Directories that may hold the version files: the runfiles symlink
    directory first, then the resolved source directory. """
    directories = [os.path.dirname(os.path.abspath(__file__))]
    real_directory = os.path.dirname(os.path.realpath(__file__))
    if real_directory not in directories:
        directories.append(real_directory)
    return directories


def _read_version_tag(directory: str) -> str:
    tag_path = os.path.join(directory, VERSION_TAG_FILE)
    if not os.path.exists(tag_path):
        return ''
    with open(tag_path, 'r', encoding='UTF-8') as file:
        return file.read().strip()


def load_version(directory: str | None = None) -> Version:
    """ Loads the version from the version file.

    A build tag file beside it supplies the hash suffix when the version file
    itself carries none, so tagged builds report major.minor.revision.tag.
    None means the directory of this module.
    """
    directories = [directory] if directory is not None else _module_directories()
    for candidate in directories:
        release_file_path = os.path.join(candidate, VERSION_FILE)
        if os.path.exists(release_file_path):
            break
    with open(release_file_path, 'r', encoding='UTF-8') as file:
        version_spec = yaml.safe_load(file)
    if not version_spec.get('hash'):
        for candidate in directories:
            tag = _read_version_tag(candidate)
            if tag:
                version_spec['hash'] = tag
                break
    return Version(**version_spec)


def write_version(version: Version) -> None:
    """ Replaces the version into version file. """
    release_file_path = os.path.join(os.path.dirname(os.path.realpath(__file__)), VERSION_FILE)
    data = ''
    for key, value in version.model_dump().items():
        data += F'{key.lower()}: {value}\n'
    with open(release_file_path, 'w+', encoding='UTF-8') as file:
        file.write(data)


VERSION = load_version()
