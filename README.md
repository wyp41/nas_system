# NAS System

通过 Cloudflare Access 与 SSH/SFTP 访问 `nas`、`lab` 的跨平台部署脚本。

## 选择平台

| 平台 | 入口 | 功能 |
| --- | --- | --- |
| macOS | [Mac/README.md](Mac/README.md) | 安装并配置 NAS SFTP、VFS 缓存、桌面挂载和 launchd 自动启动 |
| Windows | [Windows/README.md](Windows/README.md) | 安装 cloudflared、rclone、WinFsp、OpenSSH Client，配置 SSH，并将 NAS 挂载到 `Z:` |

密码不会写入仓库：macOS 使用登录钥匙串；Windows 挂载密码由当前用户的 DPAPI 加密保存，交互式 SSH 连接仍会单独询问密码。

## SSH 别名

- `nas` → `nas.wyp.life`
- `lab` → `lab.wyp.life`

两个入口均通过 `cloudflared access ssh` 或本机 Cloudflare TCP 桥接访问服务器。

## NAS 服务端设置

以下步骤主要在 Cloudflare 网页控制台中完成。开始前确认：

- `wyp.life` 已接入当前 Cloudflare 账户。
- NAS 上的 SSH 服务可以通过 `localhost:22` 访问。
- NAS 可以访问互联网并运行 `cloudflared`。

客户端使用 `nas.wyp.life`，并通过 Cloudflare Access 身份验证和 NAS SSH 密码两层验证访问。

### 1. 创建 Cloudflare Access 应用

1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com/)，进入 **Zero Trust**。
2. 进入 **Access controls → Applications**。
3. 选择 **Create new application**。
4. 选择 **Self-hosted and private**，然后选择 **Add public hostname**。
5. 填写应用：
   - Application name：`NAS SSH`
   - Subdomain：`nas`
   - Domain：`wyp.life`
   - Path：留空
   - Session Duration：按需要设置，例如 `24 hours`
6. 在 **Access policies** 中创建 Allow policy：
   - Policy name：`Allow NAS users`
   - Action：`Allow`
   - Include selector：少量用户选择 `Emails`，填写每个获准用户的完整邮箱
   - 如果整个可信组织都可访问，可选择 `Emails ending in` 并填写组织邮箱域名
7. 选择用户需要使用的身份提供商；如果身份提供商支持 MFA，建议启用 MFA。
8. 保存并创建应用。

不要在 Allow policy 中使用 `Include → Everyone`，也不要为普通用户建立 `Bypass` policy，否则会绕过预期的身份限制。Access 应用默认拒绝没有匹配 Allow policy 的身份。

### 2. 在网页中创建 Tunnel

1. 在 Cloudflare 控制台进入 **Networking → Tunnels**。
2. 选择 **Create Tunnel**，connector 类型选择 **Cloudflared**。
3. Tunnel name 填写 `nas`，然后选择 **Save tunnel**。
4. 在 **Setup Environment** 中选择 NAS 使用的操作系统和架构。
5. 网页会生成安装及注册命令。只在 NAS 终端中执行该命令。
6. 返回网页，等待 connector 状态变为 **Connected** 或 tunnel 状态变为 **Healthy**。

安装命令包含 tunnel token。该 token 相当于 tunnel 凭据，不要提交到 GitHub，也不要提供给客户端用户。

如果 NAS 已经出现在 **Networking → Tunnels** 且状态正常，直接使用现有 tunnel，不要重复创建或安装第二个 `cloudflared` 服务。

### 3. 添加 SSH Published Application

1. 打开 `nas` tunnel。
2. 进入 **Routes**，选择 **Add route → Published application**。
3. 填写 route：
   - Subdomain：`nas`
   - Domain：`wyp.life`
   - Path：留空
   - Service type：`SSH`
   - URL：`localhost:22`
4. 选择 **Add route** 保存。
5. 回到 route 列表，确认显示 `nas.wyp.life → ssh://localhost:22`。

`cloudflared` 从 NAS 主动连接 Cloudflare，因此不需要在路由器上做 22 端口转发，也不需要把 SSH 端口暴露到公网。

### 4. 在网页中新增访问者

1. 进入 **Access controls → Applications**。
2. 找到 `NAS SSH`，选择 **Configure**。
3. 打开 `Allow NAS users` policy。
4. 在 **Include → Emails** 中加入访问者登录 Cloudflare Access 时使用的完整邮箱。
5. 保存 policy 和应用。
6. 进入 **Access controls → Policies → Policy tester**，输入该邮箱，确认结果为 **Allow**。

访问者不需要 Cloudflare 控制台管理权限，只需要被 Access policy 放行。然后让对方按 [Mac/README.md](Mac/README.md) 或 [Windows/README.md](Windows/README.md) 部署客户端，并通过安全渠道单独提供 NAS SSH 密码。

当前客户端最终都以 SSH 用户 `wyp` 访问 `/home/wyp/disk/data/storage`。Cloudflare Access 控制谁能到达 NAS，SSH 密码控制其能否登录。

### 5. 撤销访问者

1. 在 `NAS SSH` 应用的 `Allow NAS users` policy 中删除该用户邮箱并保存。
2. 进入 **Team & Resources → Users**。
3. 选中该用户，选择 **Action → Revoke**，使其现有 Access 会话失效。

如需让所有用户重新验证，可进入 **Access controls → Applications → NAS SSH → Configure**，选择 **Revoke existing tokens**。如果多人共用的 SSH 密码也可能泄露，还需要在 NAS 上轮换密码。

### 6. 网页端排查

连接失败时依次检查：

- **Networking → Tunnels**：`nas` tunnel 是否为 **Healthy**。
- Tunnel 的 **Routes**：是否存在 `nas.wyp.life → SSH localhost:22`。
- **Access controls → Applications**：`NAS SSH` 是否覆盖完整域名 `nas.wyp.life`。
- Access policy：Action 是否为 `Allow`，用户邮箱是否匹配。
- **Policy tester**：该用户的最终结果是否为 `Allow`。

`lab.wyp.life` 如需开放给其他人，使用相同流程创建 `LAB SSH` Access 应用，并在相应 tunnel 中添加 `lab.wyp.life → SSH localhost:22` route。Windows 部署程序默认会依次验证 `nas.wyp.life` 和 `lab.wyp.life`。

Cloudflare 官方参考：[创建 Tunnel](https://developers.cloudflare.com/tunnel/setup/)、[客户端 cloudflared 连接 SSH](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/ssh/ssh-cloudflared-authentication/)、[创建 Access 应用](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/)、[Access policy](https://developers.cloudflare.com/cloudflare-one/access-controls/policies/)。
