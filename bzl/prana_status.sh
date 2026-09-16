#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Default workspace status command (.bazelrc). Emits STABLE_OSMO_VERSION_TAG,
# which //src/lib/utils:version_tag bundles next to version.yaml so every
# Python binary reports e.g. 6.4.0.prana instead of the upstream 6.4.0.
#
# The default is the constant "prana": a tag that changed per commit would
# re-run every test depending on the version library after each commit.
# Release builds pass a specific value, for example
#   OSMO_VERSION_TAG="prana$(git rev-parse --short=8 HEAD)" bazel build ...
# The tag must be alphanumeric: the service parses the client version header
# with ^\d+\.\d+\.\d+(\.[a-zA-Z0-9]+)?$.
set -euo pipefail

tag="${OSMO_VERSION_TAG:-prana}"
if [[ ! "$tag" =~ ^[a-zA-Z0-9]+$ ]]; then
    echo "OSMO_VERSION_TAG must be alphanumeric, got: $tag" >&2
    exit 1
fi
echo "STABLE_OSMO_VERSION_TAG $tag"
