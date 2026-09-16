# OSMO CLI 能力说明

本文面向当前 Prana 分支的命令行用户，说明 CLI 能做什么、如何使用，以及操作边界。

- 核对日期：2026-09-16。
- 本机实测版本：`OSMO client version:  6.4.0.prana`。
- 源码基线：`2c72573c` 加本次 `backend list` 接入；命令入口以本机 `osmo --help` 和 [main_parser.py](../src/cli/main_parser.py) 为准。
- 验证范围：执行版本与命令帮助检查，并核对实现；本文示例未实际向集群提交任务、修改账号或传输数据。

## 定位与执行方式

OSMO CLI 是使用 OSMO 平台的命令行入口。它可以提交训练、仿真、数据处理等容器工作流，查看资源和任务状态，进入运行中的任务调试，传输文件，并管理工作流模板与访问凭据。

通常的使用链路是：

```text
编写 workflow.yaml → 登录 OSMO → 选择资源池 → 验证并提交
    → 服务端调度到 Kubernetes → 查看状态、日志、进入任务 → 获取产物
```

CLI 负责发送请求和提供本地交互；容器镜像、资源需求、任务依赖和输入输出由工作流定义，实际调度与运行由 OSMO 服务和计算集群完成。

工作流、App、资源、用户等命令需要可访问的 OSMO 服务和相应权限。`data` 命令直接使用存储 SDK 访问对象存储，另需对应的存储配置与凭据；登录 OSMO 不等于已经获得存储访问能力。

## 能力总览

表中的子命令是当前 CLI 实际注册的命令；能否操作具体资源仍由服务端权限决定。

| 命令入口 | 子命令 | 可以完成的工作 |
| --- | --- | --- |
| `login` | — | 浏览器 PKCE、设备码、密码、Token 和开发模式登录 |
| `logout` | — | 清除本地保存的登录凭据 |
| `version` | — | 查看客户端版本；服务可访问且已登录时还可显示服务端版本 |
| `workflow` | `submit`、`restart`、`validate`、`logs`、`events`、`cancel`、`query`、`list`、`exec`、`spec`、`port-forward`、`rsync` | 提交、查询、诊断、取消工作流，进入任务，转发端口与同步文件 |
| `workflow rsync` | `upload`、`download`、`status`、`stop` | 与任务文件系统传输文件，管理本地持续上传进程 |
| `app` | `create`、`update`、`info`、`show`、`spec`、`list`、`delete`、`rename`、`submit` | 保存、版本化、复用和提交工作流模板 |
| `task` | `list` | 跨工作流查看任务，按状态、用户、资源池、节点等条件筛选 |
| `data` | `upload`、`download`、`list`、`delete`、`check` | 上传、下载、列举、删除对象存储数据，检查访问权限 |
| `credential` | `set`、`list`、`delete` | 管理镜像仓库、数据存储和通用凭据 |
| `token` | `set`、`delete`、`list`、`roles` | 创建和撤销访问 Token，查看 Token 的角色 |
| `resource` | `list`、`info` | 查看节点资源及节点配置，按资源池或平台筛选 |
| `profile` | `set`、`list` | 设置默认资源池、邮件或 Slack 通知偏好 |
| `pool` | `list` | 查看可见资源池、GPU 配额、容量与使用情况 |
| `backend` | `list` | 查看计算后端的名称、描述及基于心跳的在线状态 |
| `user` | `list`、`create`、`update`、`delete`、`get` | 查看和管理用户，添加或移除角色 |
| `config` | `show` | 查看 GitOps 管理的当前配置 |

## 登录与选择资源

以下示例中的服务地址、资源池、工作流 ID、任务名、路径和存储桶均为占位值，执行前需要替换。修改类命令会作用于当前登录的服务。

```bash
# Check the installed version.
osmo version

# Sign in using the system browser (PKCE is the default).
osmo login https://osmo.example.com

# Use device flow on a machine without a local browser.
osmo login https://osmo.example.com --method code

# Use a provisioned token for automation.
osmo login https://osmo.example.com --method token --token-file /secure/osmo-token.txt

# Inspect backend connectivity, available pools and free resources.
osmo backend list
osmo pool list --mode free
osmo resource list --pool my-pool --mode free
osmo resource info my-node --pool my-pool

# Save the default pool and inspect the profile.
osmo profile set pool my-pool
osmo profile list
```

密码登录使用 `--method password --username USER --password-file FILE`，是否可用取决于身份提供方配置。`--method dev` 是开发部署的专用入口，不会绕过正常部署的认证。

`pool list` 中配额可用量与节点实际空闲量是不同概念；看到空闲 GPU 不代表某个工作流一定能立即调度，还需满足配额、资源需求及调度条件。

### 查看计算后端

Backend 是 OSMO 登记的计算集群接入配置，Pool 将工作流路由到相应后端资源，Node 是集群中的具体机器。

`osmo backend list` 调用只读接口 `GET api/configs/backend`，输出 `Name`、`Description`、`Status` 表格。`ONLINE` / `OFFLINE` 直接使用服务端根据心跳计算的 `online` 字段；已配置但尚未连接的后端可显示为离线。

此命令沿用配置查询接口的访问权限，不会创建后端或建立集群连接。在线不等于 GPU 空闲或能够立即调度；完整配置可通过 `osmo config show BACKEND` 查看。当前 `backend list` 只支持表格输出，没有 JSON 或筛选选项。

## 工作流：从提交到排障

### 验证和提交

```bash
# Validate against the service without starting a workflow.
osmo workflow validate workflow.yaml --pool my-pool

# Render and inspect the specification without submitting a run.
osmo workflow submit workflow.yaml --pool my-pool --dry-run

# Submit a run with a classification label.
osmo workflow submit workflow.yaml --pool my-pool --label project=demo

# Override a declared template parameter and task environment variable.
osmo workflow submit workflow.yaml --pool my-pool \
  --set epochs=10 --set-env RUN_MODE=train --priority NORMAL
```

- `--set` 和 `--set-string` 替换工作流中声明的模板参数，例如 `{{ epochs }}`；它们不是任意 YAML 字段的路径编辑器。前者会按情况转换数值，后者保留字符串。
- `--set-env` 设置任务环境变量，可以覆盖工作流中的同名变量。
- `--pool` 指定执行资源池；也可以使用个人默认资源池。
- `--priority` 可选 `HIGH`、`NORMAL`、`LOW`；低优先级工作流可能被抢占。
- `--label KEY=VALUE` 可重复传入。当前版本使用 labels 分类和筛选，已提交运行的 labels 不能通过 CLI 修改。
- `validate` 和 `--dry-run` 都调用服务端，不能当作离线校验。`validate` 使用 `validation_only=True`；`--dry-run` 输出服务端返回的 spec 后退出，不创建运行，也不等于真实执行成功。
- `--dry-run` 在实际提交前返回，不能据其输出判断 `--set-env` 的最终效果，也不会启动 `--rsync`。
- `submit` 还接受已有工作流 ID 以其 spec 重新提交；该方式不支持 `--dry-run` 和 `--set`。

### 查询、日志和控制

```bash
osmo workflow list --pool my-pool --label project=demo
osmo workflow query my-workflow-id --verbose
osmo workflow spec my-workflow-id
osmo workflow spec my-workflow-id --template

# Read the log stream, task errors and workflow events.
osmo workflow logs my-workflow-id
osmo workflow logs my-workflow-id --task train --error
osmo workflow events my-workflow-id

# Inspect active tasks for this workflow.
osmo task list --workflow-id my-workflow-id

# Cancel a queued or running workflow, or restart a failed workflow.
osmo workflow cancel my-workflow-id --message 'Stopped by operator'
osmo workflow restart my-failed-workflow-id --pool my-pool
```

`workflow list` 支持状态、用户、时间、优先级、App、标签和分页筛选。`task list` 默认只列出处理、调度、初始化和运行中的任务；查历史完成或失败任务时需要显式指定 `--status`。

`logs` 使用流式响应，没有 `--follow` 参数；`--error` 和 `--retry-id` 需要同时指定 `--task`。`restart` 面向失败工作流，不代表暂停后恢复内存状态，也不自动保证应用从 checkpoint 继续训练。

## 交互调试、端口转发和文件同步

这些能力作用于工作流中的任务，需要任务处于可连接状态，并且相应 Router 和运行时通道可用。

```bash
# Open a shell in a task. Use /bin/sh if bash is unavailable in its image.
osmo workflow exec my-workflow-id train
osmo workflow exec my-workflow-id train --entry /bin/sh

# Forward a local port to a service running inside the task.
osmo workflow port-forward my-workflow-id train --port 8888:8888

# Upload source files once or continuously in the background.
osmo workflow rsync upload my-workflow-id train ./src:/osmo/run/workspace/src
osmo workflow rsync upload my-workflow-id train ./src:/osmo/run/workspace/src --daemon

# Download results from the task filesystem.
osmo workflow rsync download my-workflow-id train /osmo/run/workspace/results:./results

# Inspect and stop local synchronization daemons.
osmo workflow rsync status
osmo workflow rsync stop my-workflow-id --task train
```

- `exec --group GROUP` 可向任务组发送命令；`--keep-alive` 在断线后重新执行入口命令，不是恢复原来的终端会话。
- `port-forward` 支持 `local_port:task_port`、端口范围和 `--udp`，默认监听本机 `localhost`。需要先在任务中启动 Jupyter、TensorBoard 或其他目标服务。
- `rsync upload --daemon` 持续监测本地变更并上传；下载是单次操作。可配置上传限速及同步间隔。
- `workflow submit --rsync ./src:/osmo/run/workspace/src` 可在提交后为 lead task 启动持续上传。
- `rsync stop` 停止本地同步进程，不取消工作流；不指定工作流时作用于所有匹配的本地同步进程。
- `/osmo/run/workspace` 可以用于任务内同步，但这些命令本身不提供跨工作流生命周期的持久开发环境保证。任务结束前应通过工作流输出或对象存储保存需要保留的产物。

## 对象存储与任务文件的区别

`data` 面向对象存储 URI，`workflow rsync` 面向正在运行的任务文件系统。上传对象不会自动把文件放入某个任务；需要在工作流输入中引用它，或使用 rsync 传入任务。

```bash
# Upload syntax puts the remote URI before the local path.
osmo data upload s3://my-bucket/input/ ./dataset

# List objects directly to stdout.
osmo data list s3://my-bucket/input/ --recursive --no-pager

# Download results, allowing a previous download to resume.
osmo data download s3://my-bucket/output/ ./results --resume

# Check read access using the configured storage credentials.
osmo data check s3://my-bucket/ --access-type READ
```

上传和下载支持 `--regex` 筛选、`--processes` 与 `--threads` 并发参数，以及 `--benchmark-out` 传输测量输出。支持的后端由仓库的[存储库](../src/lib/data/storage/)实现，使用时需按目标后端配置 URI 和认证。

`data delete URI` 会删除匹配的远端对象，当前参数中没有 `--dry-run` 或 `--force` 确认开关。`data check` 的检查精度取决于存储后端：例如自定义 S3 兼容端点走桶访问检查，返回通过不代表已验证所有对象的读写删除权限。自动化还应检查其 JSON `status`：当前实现遇到凭据检查失败时可输出 `status: fail`，不能只依赖进程退出码。

## App：复用和版本化工作流

App 是保存在服务端的可复用工作流模板。创建或更新 App 管理的是模板；`app submit` 才创建执行工作流。

```bash
osmo app create train-demo --description 'Reusable training workflow' --file workflow.yaml
osmo app update train-demo --file workflow.yaml
osmo app list
osmo app info train-demo
osmo app show train-demo
osmo app spec train-demo
osmo app submit train-demo --pool my-pool --set epochs=10
```

使用 `APP:VERSION` 可指定版本。`show` 查看参数，`spec` 查看工作流定义，`info` 查看版本信息。还支持 `rename` 和 `delete`；`delete --all` 删除全部版本。提交支持模板参数、环境变量、标签、优先级、dry-run 和 rsync。

## 凭据、Token 和用户管理

| 能力 | 用途与边界 |
| --- | --- |
| `credential set NAME --type REGISTRY` | 保存镜像仓库认证 |
| `credential set NAME --type DATA` | 保存数据访问凭据 |
| `credential set NAME --type GENERIC` | 保存工作流使用的通用键值凭据 |
| `credential list` / `delete NAME` | 列举或删除保存的凭据 |
| `token set NAME` | 创建访问 Token，可指定到期日期、描述和角色 |
| `token list` / `roles NAME` / `delete NAME` | 查看 Token、查询其角色或撤销 Token |
| `user list` / `get USER` | 查询用户与角色信息 |
| `user create` / `update` / `delete` | 创建、变更或删除用户，需相应管理权限 |

`credential set` 必须使用 `--payload KEY=VALUE ...` 或 `--payload-file KEY=FILE ...` 提供数据；后者逐个读取文件内容，适合避免在命令行中直接写入秘密。具体字段以 `osmo credential set --help` 为准。

Token 是访问 OSMO 的凭据；`credential` 保存的是工作流访问外部资源等用途的凭据，两者不可互换。替其他用户创建 Token 的 `token set --user USER` 需要管理员权限；指定角色也不代表可以越权。

## 配置检查与自动化输出

```bash
osmo config show SERVICE
osmo config show POOL my-pool --verbose
osmo config show BACKEND
osmo config show ROLE

osmo workflow list --format-type json
osmo workflow query my-workflow-id --format-type json
osmo token list --format-type json
osmo credential --format-type json list
```

可查询的配置类型：`BACKEND`、`BACKEND_TEST`、`GROUP_TEMPLATE`、`POD_TEMPLATE`、`POOL`、`RESOURCE_VALIDATION`、`ROLE`、`SERVICE`、`WORKFLOW`。

`config` 当前只有 `show`。配置修改应更新 Helm values 并通过 GitOps 重新部署；没有 `config set`、配置历史版本修改或回滚命令。

JSON 输出由各子命令分别支持，不是全局选项。特别是 `credential --format-type json list`，选项位于 `credential` 后、子命令前。`data list` 输出对象列表及统计文本，不能当作 JSON 解析。

使用 `osmo --log-level DEBUG COMMAND ...` 可以启用详细日志，使用 `osmo COMMAND --help` 或 `osmo GROUP SUBCOMMAND --help` 查询参数。

## 当前 CLI 的能力边界

- 没有部署 OSMO、创建 GKE 集群或安装 GPU 驱动的命令；这些属于仓库部署脚本、Terraform 和 Helm 的职责。
- 没有创建或修改资源池的 `pool create` / `pool update`，当前 `pool` 只提供 `list`。
- `backend` 只提供 `list`，不支持创建、修改或删除计算后端；后端配置仍由 Helm / GitOps 管理。
- 没有 `dev-environment create/start/stop` 等独立开发环境管理命令；现有交互能力围绕工作流任务提供。
- 没有 `workflow pause` / `resume`，也没有独立的 `task exec`；进入任务使用 `workflow exec`。
- 没有自动构建和上传用户镜像的命令。提交工作流前需要准备可拉取的镜像及对应运行程序。
- `.prana` 是构建版本标记，不代表服务已经连接成功、集群资源可用或当前账号具有全部权限。

## 本地重建安装

在仓库根目录执行：

```bash
./scripts/rebuild-install-cli.sh
osmo version
```

[重建安装脚本](../scripts/rebuild-install-cli.sh) 使用当前 checkout 和 Bazel 缓存构建，默认安装到 `~/.local/bin/osmo`。新程序通过 Prana 版本检查后才切换入口，保留旧安装；可通过 `--prefix DIRECTORY` 安装到其他目录。它不自动拉取 Git 远端更新。

## 维护依据

- [CLI 命令注册](../src/cli/main_parser.py)
- [计算后端查询](../src/cli/backend.py)
- [工作流参数与行为](../src/cli/workflow.py)
- [数据操作与权限检查](../src/cli/data.py)
- [App 模板管理](../src/cli/app.py)
- [凭据](../src/cli/credential.py)、[Token](../src/cli/access_token.py)、[用户](../src/cli/user.py)
- [只读配置入口](../src/cli/config.py)
- [现有 CLI 参考文档](user_guide/appendix/cli/)

后续命令变更时，应同时检查主解析器注册、本机帮助和处理函数，避免把未注册源码或旧版参考资料当作当前可用能力。
