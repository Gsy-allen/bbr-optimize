# bbr-optimize

`bbr-optimize` 是一个面向 **Ubuntu / Debian VPS** 的一次性初始化脚本，用于启用 **BBR + FQ**，并根据业务场景与机器资源生成一组克制、可解释、可恢复的网络参数。

项目当前提供的脚本文件：

- `enable-bbr-fq.sh`

## 设计目标

本项目专注于 **BBR + FQ** 及其直接相关参数，不试图成为“万能网络优化脚本”。

脚本会完成以下工作：

- 启用 `net.ipv4.tcp_congestion_control=bbr`
- 启用 `net.core.default_qdisc=fq`
- 根据业务场景与资源档位调整以下参数：
  - `net.core.netdev_max_backlog`
  - `net.core.somaxconn`
  - `net.ipv4.tcp_max_syn_backlog`
  - `net.ipv4.tcp_notsent_lowat`

设计原则：

- 范围清晰
- 参数可解释
- 变更可恢复
- 避免无边界扩展

## 支持系统

仅支持以下系统：

- Ubuntu
- Debian

## 功能特性

- 中文交互菜单
- 支持 `--scenario` 非交互执行
- 根据 CPU / 内存 / 带宽自动确定资源档位
- 执行前自动备份相关配置
- 自动轮转备份，默认保留最近 **5** 份
- 执行后打印参数变更前后对比
- 打印生成的 sysctl 配置内容
- 支持通过备份目录恢复
- 非交互终端下若未指定 `--scenario`，会直接报错退出

## 业务场景

可用场景：

- `streaming-relay`：流媒体中转，偏持续吞吐
- `proxy-relay`：代理转发，均衡通用
- `high-concurrency-edge`：高并发入口机，偏大量新连接接入
- `general-server`：通用服务器，保守稳妥
- `auto`：自动保守模式，适用于用途暂不明确的情况

说明：

- 场景表示 **业务用途**
- CPU / 内存 / 带宽不是顶层场景，而是第二层约束
- 资源只用于在已选场景内收敛参数，不替代业务意图

## 快速开始

### 1. 交互模式

```bash
sudo bash enable-bbr-fq.sh
```

### 2. 指定场景执行

```bash
sudo bash enable-bbr-fq.sh --scenario proxy-relay
```

其他示例：

```bash
sudo bash enable-bbr-fq.sh --scenario streaming-relay
sudo bash enable-bbr-fq.sh --scenario high-concurrency-edge
sudo bash enable-bbr-fq.sh --scenario general-server
sudo bash enable-bbr-fq.sh --scenario auto
```

### 3. 查看帮助

```bash
bash enable-bbr-fq.sh --help
```

## 恢复配置

脚本每次执行前都会生成一个备份目录，例如：

```bash
/root/bbr-fq-backup-20260329-123456
```

如需恢复，可执行：

```bash
sudo bash enable-bbr-fq.sh --restore /root/bbr-fq-backup-20260329-123456
```

恢复过程会尝试：

- 恢复 `/etc/sysctl.d/99-bbr-fq-tuned.conf`
- 恢复 `/etc/sysctl.conf`（如果备份中存在）
- 执行 `sysctl --system`
- 尽量恢复主网卡 qdisc

## 变更范围

脚本会写入：

- `/etc/sysctl.d/99-bbr-fq-tuned.conf`

脚本会检查并打印以下参数的变更前后对比：

- `net.core.default_qdisc`
- `net.ipv4.tcp_congestion_control`
- `net.core.netdev_max_backlog`
- `net.core.somaxconn`
- `net.ipv4.tcp_max_syn_backlog`
- `net.ipv4.tcp_notsent_lowat`

## 备份内容

每次执行时，脚本会备份：

- `/etc/sysctl.conf`（如果存在）
- 旧的 `/etc/sysctl.d/99-bbr-fq-tuned.conf`（如果存在）
- 当前目标 sysctl 参数快照
- 当前 qdisc 状态
- 相关 sysctl 配置的潜在冲突位置

## 常见问题

### 为什么不默认加入更多 TCP/UDP 优化参数？

因为本项目的目标不是堆砌参数，而是提供一个范围受控、行为明确的 BBR + FQ 初始化脚本。参数越多，副作用和不可解释性通常也越强。

### 为什么运行 `bash enable-bbr-fq.sh` 时会等待输入？

在交互终端中运行时，脚本会显示菜单并等待输入场景编号。

如果当前不是交互终端，且未传入 `--scenario`，脚本会直接报错退出，而不会停在不可见的输入状态。

### 为什么暂不支持 CentOS / AlmaLinux / Rocky？

因为项目当前只针对 Ubuntu / Debian 的行为做了约束与验证。扩大系统支持范围需要额外测试，否则只会增加不确定性。

## 推荐用法

对于普通 VPS，推荐优先使用：

```bash
sudo bash enable-bbr-fq.sh --scenario general-server
```

对于明确的代理/转发场景：

```bash
sudo bash enable-bbr-fq.sh --scenario proxy-relay
```

如果暂时无法准确判断业务类型：

```bash
sudo bash enable-bbr-fq.sh --scenario auto
```

## 注意事项

该脚本会直接修改系统网络参数。尽管它已经提供：

- 备份
- 恢复
- 参数打印
- 基本验证

仍建议你：

- 优先在新机或可回滚环境中测试
- 根据实际业务场景选择参数集
- 不要将其视为适用于所有网络负载的通用优化器
