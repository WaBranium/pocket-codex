# OpenCode 宿主

POCOX 如何托管本机已安装的 OpenCode，并让控制器仍走原来的入口。这里只记录这条边界上的词，不是整个产品的词汇表。

## Language

**Engine**:
按服务种类选定的那一个会话引擎。OpenCode 只有 `OpenCodeEngine`，1.19 和 2.x 共用，不按版本再分。
_Avoid_: 第四个 engine、V2 engine、adapter

**Gateway**:
控制器调用的封闭 HTTP API，路径是 `/opencode/v1`。它不是 OpenCode 自己的协议。
_Avoid_: V1、OpenCode API

**Native wire**:
`opencode serve` 对 POCOX 主机说的协议。1.19 和 2.x 是这条协议的两个版本，不是两个入口。
_Avoid_: V1 API、上游 API

**Dialect**:
原生 `Client` 内部的翻译，把 OpenCode 2 的 native wire 译回宿主已经在解的 1.19 形状。网关客户端不做这层翻译。
_Avoid_: 新引擎、适配器、V1 client

**Occupancy**:
原生服务器在 active 列表里点名的会话是忙；没有点名的会话是空闲。忙会挡住写入。
_Avoid_: 重试态、三态、合成的 retry
