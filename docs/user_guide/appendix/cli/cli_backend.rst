..
  SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
  SPDX-License-Identifier: Apache-2.0

:tocdepth: 3

.. _cli_reference_backend:

================================================
osmo backend
================================================

List the compute backends registered with the service::

   osmo backend list

The table shows each backend's name, description, and online status. The service
derives ``ONLINE`` or ``OFFLINE`` from backend heartbeats; online status does not
imply that resources are available or that a workflow can be scheduled.

This is a read-only command using the same endpoint and permissions as
``osmo config show BACKEND``. It does not create, connect, or modify backends.

.. argparse-with-postprocess::
   :module: src.cli.main_parser
   :func: create_cli_parser
   :prog: osmo
   :path: backend
   :ref-prefix: cli_reference_backend
   :argument-anchor:
   :markdown:
