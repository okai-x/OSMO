#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/rebuild-install-cli.sh [--prefix DIRECTORY]

Build the current checkout's Prana CLI with Bazel and install without sudo.
The default prefix is ~/.local; the command is installed at PREFIX/bin/osmo.
Set OSMO_VERSION_TAG to an alphanumeric tag starting with prana (default: prana).
Bazel reuses unchanged build outputs. Old installations are retained.
EOF
}

prefix="$HOME/.local"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)
            if [[ $# -lt 2 || -z "$2" ]]; then
                echo 'ERROR: --prefix requires a directory.' >&2
                exit 1
            fi
            prefix="$2"
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done

case "$(uname -s):$(uname -m)" in
    Linux:x86_64) architecture=amd64 ;;
    Linux:aarch64|Linux:arm64) architecture=arm64 ;;
    *) echo 'ERROR: Only Linux x86_64 and arm64 are supported.' >&2; exit 1 ;;
esac

if command -v bazelisk >/dev/null 2>&1; then
    bazel_command=bazelisk
elif command -v bazel >/dev/null 2>&1; then
    bazel_command=bazel
else
    echo 'ERROR: Install Bazelisk or the Bazel version in .bazelversion first.' >&2
    exit 1
fi

export OSMO_VERSION_TAG="${OSMO_VERSION_TAG:-prana}"
if [[ ! "$OSMO_VERSION_TAG" =~ ^prana[a-zA-Z0-9]*$ ]]; then
    echo 'ERROR: OSMO_VERSION_TAG must be alphanumeric and start with prana.' >&2
    exit 1
fi

# Resolve a relative prefix before changing to the checkout directory.
mkdir -p -- "$prefix"
prefix=$(cd -- "$prefix" && pwd -P)
repository_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd -- "$repository_root"
target="//src/cli:osmo_cli_pkg_${architecture}"
echo "Building $target (tag: $OSMO_VERSION_TAG)"
"$bazel_command" build --workspace_status_command=bzl/prana_status.sh "$target"
bazel_bin=$("$bazel_command" info bazel-bin)

mkdir -p -- "$prefix/lib/osmo-cli" "$prefix/bin"
install_directory=$(mktemp -d "$prefix/lib/osmo-cli/build.XXXXXXXX")
echo "Extracting CLI to $install_directory"
tar -xzf "$bazel_bin/src/cli/osmo_cli_pkg_${architecture}.tgz" -C "$install_directory"
candidate="$install_directory/osmo/osmo_cli_onedir/osmo/osmo"

# An empty config prevents version checks from contacting a configured service.
version_output=$(OSMO_CONFIG_FILE_DIR="$install_directory/check-config" \
    OSMO_LOG_FILE_DIR="$install_directory/check-state" "$candidate" version)
printf '%s\n' "$version_output"
if ! grep -Eq "^OSMO client version: +[0-9]+\.[0-9]+\.[0-9]+\.${OSMO_VERSION_TAG}$" \
    <<< "$version_output"; then
    echo 'ERROR: Built CLI does not report the requested Prana tag; installation unchanged.' >&2
    exit 1
fi

# Keep the old entry point for rollback; switch only after the new CLI works.
if [[ -e "$prefix/bin/osmo" || -L "$prefix/bin/osmo" ]]; then
    if [[ -d "$prefix/bin/osmo" ]]; then
        echo 'ERROR: The existing osmo entry point is a directory.' >&2
        exit 1
    fi
    if [[ -L "$prefix/bin/osmo" ]]; then
        ln -s -- "$(readlink -m -- "$prefix/bin/osmo")" "$install_directory/previous-osmo"
    else
        cp -a -- "$prefix/bin/osmo" "$install_directory/previous-osmo"
    fi
    echo "Previous entry point saved to $install_directory/previous-osmo"
fi
ln -s -- "$candidate" "$install_directory/osmo-link"
mv -Tf -- "$install_directory/osmo-link" "$prefix/bin/osmo"
echo "Installed: $prefix/bin/osmo"
OSMO_CONFIG_FILE_DIR="$install_directory/check-config" \
    OSMO_LOG_FILE_DIR="$install_directory/check-state" "$prefix/bin/osmo" version
if [[ "$(command -v osmo || true)" != "$prefix/bin/osmo" ]]; then
    echo "To use this installation, put $prefix/bin first on PATH."
fi
