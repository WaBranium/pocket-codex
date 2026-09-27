# OpenCode 2.0.18 后端验收记录

日期：2026-09-27。平台：macOS arm64。

本记录只覆盖 Rust 后端和 OpenCode HTTP/SSE 连接层。它不代表 Flutter 桌面包或真实模型执行已经验收。

## 用户服务只读验收

本机官方注册文件报告 OpenCode `2.0.18`，注册文件为当前用户所有、权限 `0600`，服务 PID 与 `/api/info` 一致。验收使用只读 discovery，凭据只在 Rust 内存中使用；没有调用 ensure、stop、重启、prompt、create、interrupt 或任何审批接口。

运行命令：

```sh
PCX_LIVE_OPENCODE=1 \
PCX_OPENCODE_DIRECTORY=/Users/wangdejiang6 \
  cargo test -p pocket-codex-host-svc --test opencode_live_readonly \
  -- --ignored --nocapture
```

结果：`1 passed`。直连和 Pocket loopback gateway 均成功完成协议协商、会话列表、状态、权限、Forms 和 SSE 连接；测试停止的只有自有 gateway，随后再次读取上游 `/api/info`，版本和 PID 未改变。当前选择的用户目录没有会话，因此没有历史正文可比对；测试没有为了制造样本而写入用户服务。

## 隔离真实服务验收

使用安装的官方 `opencode v2.0.18` 二进制，在临时 HOME、XDG 目录、项目目录和随机服务密码下启动一个测试自有服务。Rust 测试创建一个空会话，读取直连列表和空历史，再通过 Pocket gateway 读取并比较，最后只回收测试自有进程。

运行命令：

```sh
PCX_RUN_REAL_OPENCODE=1 \
PCX_TEST_OPENCODE_BINARY="$HOME/Library/Application Support/ai.opencode.desktop/cli/2.0.18/opencode-cli" \
  cargo test -p pocket-codex-host-svc --test opencode_v2_live \
  -- --ignored --nocapture
```

结果：`1 passed`。未发送模型 prompt，所以没有验证供应商调用、真实输出、工具执行或真实审批生命周期。测试完成后只剩用户原有的 OpenCode 进程。

## 自动化结果

- OpenCode v2 合同测试：13 项通过。
- 版本化 Pocket gateway v2：5 项通过，覆盖协商/分页、SSE、prompt/interrupt、权限/typed Forms、目录和 session 越权、停止 gateway 不影响上游。
- v1 HTTP/gateway 回归：13 项 HTTP、4 项 gateway 通过。
- discovery：10 项通过；连接协商：2 项通过。
- bridge Rust 测试：106 项通过，6 项按现有规则忽略。
- `cargo fmt --check`、`cargo clippy --workspace --all-targets -- -D warnings`、`cargo test --workspace --locked` 均通过。

## 当前限制

用户服务当前没有可供只读验收的会话和历史，因此“真实用户历史正文通过 gateway 完整一致”仍待用户服务中存在安全可读会话后复测。真实模型输出、执行中权限/Forms、interrupt、Flutter FRB 生成后的桥接和桌面 UI 尚未在本次后端验收中声明通过。
