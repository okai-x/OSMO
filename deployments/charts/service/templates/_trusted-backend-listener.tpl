{{/* SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0 */}}
{{- define "osmo.trusted-backend-listener" -}}
{{- $gateway := .Values.gateway }}
{{- $trusted := $gateway.trustedBackend | default dict }}
{{- if $trusted.enabled }}
- "@type": type.googleapis.com/envoy.config.listener.v3.Listener
  name: trusted_backend_listener
  address:
    socket_address: { address: 0.0.0.0, port_value: {{ $trusted.port | default 10081 }} }
  filter_chains:
  - filters:
    - name: envoy.filters.network.http_connection_manager
      typed_config:
        "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
        stat_prefix: trusted_backend
        normalize_path: true
        path_with_escaped_slashes_action: REJECT_REQUEST
        access_log:
        - name: envoy.access_loggers.file
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.access_loggers.file.v3.FileAccessLog
            path: /dev/stdout
            log_format:
              json_format:
                listener: trusted_backend
                path: "%PATH(NQ:ORIG_OR_PATH)%"
                response_code: "%RESPONSE_CODE%"
                response_flags: "%RESPONSE_FLAGS%"
        route_config:
          name: trusted_backend_routes
          virtual_hosts:
          - name: trusted_backend
            domains: ["*"]
            routes:
            - match: { prefix: /api/agent/ }
              route: { cluster: osmo-agent, timeout: 0s }
            - match:
                safe_regex:
                  regex: "^/api/configs/(backend|backend_test)/[^/]+$"
                headers:
                - name: :method
                  string_match: { exact: GET }
              route: { cluster: osmo-service, timeout: 60s }
            - match: { prefix: / }
              direct_response: { status: 404 }
        upgrade_configs:
        - upgrade_type: websocket
          enabled: true
        http_filters:
        - name: envoy.filters.http.lua
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.http.lua.v3.Lua
            default_source_code:
              inline_string: |
                function envoy_on_request(handle)
                  local headers = handle:headers()
                  headers:remove('authorization')
                  headers:remove('cookie')
                  headers:remove('x-osmo-workflow-id')
                  headers:remove('x-osmo-allowed-pools')
                  headers:replace('x-osmo-user', 'osmo-backend')
                  headers:replace('x-osmo-roles', 'osmo-backend')
                  headers:replace('x-osmo-token-name', 'trusted-network')
                end
        {{- if $gateway.authz.enabled }}
        - name: envoy.filters.http.ext_authz
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.http.ext_authz.v3.ExtAuthz
            transport_api_version: V3
            failure_mode_allow: false
            grpc_service:
              envoy_grpc:
                cluster_name: authz
              timeout: 1s
        {{- end }}
        - name: envoy.filters.http.router
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
{{- end }}
{{- end }}
