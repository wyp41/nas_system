# Cloudflare 网页端配置

管理员只需设置一次；访问者按 [README](../README.md) 安装客户端即可。下文以 `nas.example.com` 为例，替换成自己的域名。

前提：域名已接入 Cloudflare，服务器能访问互联网，服务器上的 `cloudflared` 能连接 SSH 服务（通常是 `localhost:22`）。

## 1. 创建 Access 应用

在 [Cloudflare Zero Trust](https://one.dash.cloudflare.com/) → **Access controls → Applications** 创建 **Self-hosted** 应用：

- 名称：`NAS SSH`；Public hostname：`nas.example.com`，Path 留空。
- 创建 **Allow** 策略，在 **Include → Emails** 填写获准访问者的完整邮箱。
- 选择登录方式并保存；会话时长可按需要设置，例如 24 小时。

不要使用 `Everyone` 或 `Bypass` 放开所有身份。访问者不需要 Cloudflare 管理权限。

## 2. 创建 Tunnel 并发布 SSH

1. 在 **Networking → Tunnels** 创建 **Cloudflared** 类型的 Tunnel（已有健康 Tunnel 可复用）。
2. 选择服务器系统和架构，在服务器执行网页提供的安装命令，等待状态变为 **Healthy / Connected**。
3. 打开该 Tunnel 的 **Routes → Add route → Published application**，填入域名 `nas.example.com`，Service 选择 **SSH**，URL 填 `localhost:22`。
4. 保存，确认路由为 `nas.example.com → ssh://localhost:22`；若 SSH 在另一台内网机器，改填其内网地址和端口。

Tunnel 安装命令中的 token 只给服务器使用，不发给访问者、不提交到 Git。无需在路由器开放公网 SSH 端口。

## 3. 邀请或撤销访问者

把域名、SSH 用户、允许访问的远端目录和服务器 SSH 公钥指纹交给访问者，密码通过安全渠道单独提供。Cloudflare Access 仅控制连接权限，文件权限仍由服务器上的 SSH 账户决定。

新增用户：在 Access 应用的 Allow 策略中添加其邮箱。撤销用户：删除邮箱，并在 **Team & Resources → Users** 中 **Revoke** 其现有会话；共享 SSH 密码泄露时也要更换服务器密码。

需要 LAB 时，为 `lab.example.com` 重复应用和 SSH 路由配置，并在客户端设置 `labHost`；不需要则留空。

## 连接失败时

检查 Tunnel 健康状态、SSH 路由的地址和端口、Access 应用覆盖的域名、Allow 策略中的邮箱；可用 Policy tester 验证最终结果。

官方文档：[Tunnel](https://developers.cloudflare.com/tunnel/setup/)、[SSH 客户端](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/ssh/ssh-cloudflared-authentication/)、[Access 应用](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/)、[Access 策略](https://developers.cloudflare.com/cloudflare-one/access-controls/policies/)。
