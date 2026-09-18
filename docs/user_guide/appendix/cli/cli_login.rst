..
  SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.

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

:tocdepth: 3

.. _cli_reference_login:

================================================
osmo login
================================================

.. argparse-with-postprocess::
   :module: src.cli.main_parser
   :func: create_cli_parser
   :prog: osmo
   :path: login
   :ref-prefix: cli_reference_login
   :argument-anchor:

Cloudflare Access gateways
--------------------------

For a converged gateway protected by Cloudflare Access that supplies the OSMO
identity, use the optional ``cloudflare`` login method. ``cloudflared`` must be
installed and available on ``PATH``:

.. code-block:: bash

   osmo login https://osmo.example.com --method cloudflare
   osmo workflow list

The login opens the company's existing Access sign-in page. Cloudflared owns
the cached personal application token; OSMO stores only the server address and
login method. Requests use HTTPS and router connections use WSS on this same
public origin, even when the backend advertises an internal router address.
Workflow controllers can continue using internal service addresses.

When the Access session expires, repeat the login command. Requests do not
start an interactive login automatically. ``osmo logout`` removes the OSMO
login configuration but does not revoke the separate Cloudflared session.

This mode does not configure OSMO per-user authorization. It requires the
gateway to provide the OSMO identity; a minimal gateway may assign all allowed
Access users its default admin identity. It is not a replacement for OIDC
login on gateways that require an OSMO bearer token.

See `Cloudflare CLI authentication
<https://developers.cloudflare.com/cloudflare-one/tutorials/cli/>`_.
