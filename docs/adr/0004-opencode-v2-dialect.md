---
status: accepted
---

# OpenCode 2 是现有 Client 上的方言，不是第四个 engine

POCOX 已经用服务种类 `opencode` 选定唯一的 `OpenCodeEngine`，控制器只走 `/opencode/v1`。OpenCode 2 换了原生 HTTP，但没有换产品入口。

决定：在原生 `Client` 里按检测到的主版本选择方言，把 OpenCode 2 的报文译回宿主、折叠和网关已经在读的 1.19 形状。`Client::gateway()` 永远不启用方言。不新增服务种类、协议或 Flutter 入口。

没有选择再做一个 engine。分发只看服务种类，不看版本。再做一个会复制网关、折叠和会话准入，而版本差异只发生在 `opencode serve` 的报文上。

代价：方言必须按路由改路径、方法和响应，不能只在 `request` 里替换字符串。验证靠对本机已安装的 `opencode` 跑命令，不另写夹具测试。共享数据库若被用户自己的 OpenCode 进程占着，写入仍由现有的所有权检查拒绝；方言不去停那个进程。

详见 [OpenCode V2 wire](../opencode-v2-wire.md)。
