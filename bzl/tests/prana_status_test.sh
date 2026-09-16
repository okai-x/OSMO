#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
script="${TEST_SRCDIR}/_main/bzl/prana_status.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ "$(OSMO_VERSION_TAG='' bash "$script")" == "STABLE_OSMO_VERSION_TAG prana" ]] || fail "default tag changed"
[[ "$(OSMO_VERSION_TAG=prana1a2b3c4d bash "$script")" == "STABLE_OSMO_VERSION_TAG prana1a2b3c4d" ]] \
    || fail "override not honoured"
for bad in prana-1 'prana 1' 6.4.0 prana+git; do
    if OSMO_VERSION_TAG="$bad" bash "$script" >/dev/null 2>&1; then fail "accepted non-alphanumeric tag: $bad"; fi
done
echo "PASS: prana status command"
