# File Monitor 文件变动监控告警工具

实时监控指定目录的文件变动事件，聚合后通过企业微信/飞书发送通知，并生成完整事件日志。

## 功能特性

- **实时监控** — 基于 inotify 机制，毫秒级捕获文件创建、修改、删除、移动事件
- **双阈值聚合** — `空闲超时` + `最大窗口` 组合策略，防消息轰炸
- **多通道通知** — 支持企业微信、飞书机器人，可单发或双发
- **文件过滤** — 按扩展名/类型正则过滤，支持排除目录
- **完整日志** — 每次告警生成独立日志文件，100% 记录所有事件
- **非阻塞发送** — 异步 HTTP 请求，不影响监控主循环
- **错误重试** — 网络抖动自动重试，失败记录错误日志
- **单例保护** — PID 文件防止重复启动
- **资源预警** — 自动估算 inotify watch 用量，超限提前告警
- **配置分离** — 所有配置项外置，升级脚本不影响配置
- **日志清理** — 自动清理过期日志，避免磁盘堆积

## 适用场景

- 网站被非法篡改时即刻告警
- FTP / 部署工具批量上传后的文件变更汇总
- 监控关键业务系统的配置文件变更
- 多客户统一管理，通过消息前缀区分来源

## 文件结构

```
├── file_monitor.sh         # 主脚本
├── file_monitor.conf       # 配置文件（所有可配项）
├── file_monitor.service    # systemd 服务模板（可选）
└── README.md               # 本文件
```

## 快速开始

### 1. 安装依赖

```bash
# Ubuntu / Debian
sudo apt install inotify-tools curl

# CentOS / RHEL
sudo yum install inotify-tools curl

# Alpine
sudo apk add inotify-tools curl
```

### 2. 修改配置

编辑 `file_monitor.conf`，至少修改以下几项：

```bash
CLIENT_NAME="贵司名称"
NOTIFY_CHANNEL="wecom"
WECOM_WEBHOOK_URL="https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=你的key"
WATCH_FOLDERS=("/www/wwwroot/你的站点")
```

### 3. 运行

```bash
# 使用默认配置
bash file_monitor.sh

# 自定义配置文件
bash file_monitor.sh -c /etc/file_monitor/my.conf

# 查看帮助
bash file_monitor.sh -h
```

### 4. 停止

按 `Ctrl+C`，脚本自动清理 inotify 进程和临时文件。

## 配置详解

### 基础配置

| 配置项 | 必填 | 说明 | 示例 |
|--------|------|------|------|
| `CLIENT_NAME` | 是 | 消息头部标识，多客户时区分来源 | `"张三科技有限公司"` |
| `NOTIFY_CHANNEL` | 是 | 通知渠道: wecom / feishu / both | `"wecom"` |
| `WECOM_WEBHOOK_URL` | 条件 | 企微 Webhook，渠道含 wecom 时必填 | `"https://qyapi.weixin.qq.com/..."` |
| `FEISHU_WEBHOOK_URL` | 条件 | 飞书 Webhook，渠道含 feishu 时必填 | `"https://open.feishu.cn/..."` |

### 监控配置

| 配置项 | 必填 | 说明 | 示例 |
|--------|------|------|------|
| `WATCH_FOLDERS` | 是 | 监控目录列表（空格分隔） | `("/www/site1" "/www/site2")` |
| `EXCLUDE_DIRS` | 否 | 排除的目录（正则 OR） | `"runtime\|cache\|logs\|node_modules"` |
| `WATCH_REGEX` | 否 | 监控文件类型（正则，空=全部） | `'\.(php\|html\|js)$'` |

### 聚合策略

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `IDLE_TIMEOUT` | 5 | 空闲超时（秒），无新事件后等待多久发送 |
| `MAX_BATCH_WINDOW` | 60 | 最大窗口（秒），从首事件起最多等多久强制发送 |

双阈值示意图：

```
事件:  A  B  C  D              E  F  G  H  I  J  K ...
时间:  0  2  4  6              0  2  4  6  8  10 12 ...
          ↑                              ↑
      空闲5秒触发                   第60秒强制发送
      (批量收尾)                    (流式事件兜底)
```

## 环境变量

支持用环境变量覆盖 Webhook URL，优先级高于配置文件，适合避免密钥落盘：

| 环境变量 | 覆盖配置项 | 使用示例 |
|----------|-----------|---------|
| `FILE_MONITOR_WECOM_URL` | `WECOM_WEBHOOK_URL` | 临时设置（推荐） |
| `FILE_MONITOR_FEISHU_URL` | `FEISHU_WEBHOOK_URL` | 配合 systemd |

```bash
# 单次运行（密钥不落盘）
FILE_MONITOR_WECOM_URL="https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxx" \
FILE_MONITOR_FEISHU_URL="https://open.feishu.cn/open-apis/bot/v2/hook/xxx" \
bash file_monitor.sh

# systemd 配合 EnvironmentFile
# 在 file_monitor.service 中添加:
# EnvironmentFile=/etc/file_monitor/env
# /etc/file_monitor/env 内容（建议 600 权限）:
#   FILE_MONITOR_WECOM_URL="https://..."
#   FILE_MONITOR_FEISHU_URL="https://..."
```

### 其他

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `DISPLAY_COUNT` | 5 | 通知消息中展示的事件条数 |
| `ALERT_LOG_DIR` | `/var/log/file_monitor` | 告警事件日志目录 |
| `ALERT_LOG_RETENTION` | 30 | 日志保留天数（0=永不过期） |

## 通知效果示例

**企业微信 / 飞书消息：**

```
[张三科技有限公司] 文件变动警报！
涉及目录: /www/wwwroot/www.xxxxxx.com
总数: 23 个事件
时间: 2026-05-18 10:30:00

前 5 条变化:
- /app/index.php MODIFY
- /app/api/user.php MODIFY
- /config/database.php MODIFY
- /plugin/qqlogin.php CREATE
- /template/footer.html MODIFY
... 还有 18 个事件未显示

完整日志: /var/log/file_monitor/alert_2026-05-18_10-30-00.log
```

**归档日志文件 `alert_2026-05-18_10-30-00.log`：**

```
[张三科技有限公司] === 批次告警: 2026-05-18 10:30:00 ===
总事件数: 23
-------------------------------------------------
/www/wwwroot/www.xxxxxx.com/app/index.php MODIFY
/www/wwwroot/www.xxxxxx.com/app/api/user.php MODIFY
/www/wwwroot/www.xxxxxx.com/config/database.php MODIFY
...（完整 23 条，不截断）
```

## Webhook 获取方式

### 企业微信

1. 打开目标企业微信群 → 点击右上角 `...` → 群机器人
2. 点击"添加机器人" → 创建一个新机器人
3. 复制 Webhook URL → 粘贴到 `WECOM_WEBHOOK_URL`

### 飞书

1. 打开目标飞书群 → 点击右上角 `...` → 设置 → 群机器人
2. 点击"添加机器人" → 选择"自定义机器人" → 完成配置
3. 复制 Webhook URL → 粘贴到 `FEISHU_WEBHOOK_URL`

## 高级用法

### systemd 服务管理

```bash
# 修改 file_monitor.service 中的路径和用户
vim file_monitor.service

# 安装服务
sudo cp file_monitor.service /etc/systemd/system/
sudo systemctl daemon-reload

# 启动 / 停止 / 重启
sudo systemctl start   file_monitor
sudo systemctl stop    file_monitor
sudo systemctl restart file_monitor

# 开机自启
sudo systemctl enable  file_monitor

# 查看状态和日志
sudo systemctl status  file_monitor
sudo journalctl -u file_monitor -f
```

### 多配置同时运行

每个配置使用不同的配置文件，互不干扰：

```bash
bash file_monitor.sh -c /etc/file_monitor/customer_a.conf
bash file_monitor.sh -c /etc/file_monitor/customer_b.conf
```

### 增大 inotify watch 上限

如果监控目录过大（如 Discuz! 论坛），可能需要增大系统限制：

```bash
# 查看当前限制
cat /proc/sys/fs/inotify/max_user_watches

# 临时增大
sudo sysctl -w fs.inotify.max_user_watches=1048576

# 永久生效
echo 'fs.inotify.max_user_watches=1048576' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

脚本启动时会自动估算所需 watches 数并与系统上限对比，超限会给出警告。

## 常见问题

**Q: 启动报错 `inotifywait not found`**

A: 未安装 inotify-tools，见"安装依赖"章节。

**Q: 如何只监控 .php 文件？**

```bash
WATCH_REGEX='\.php$'
```

**Q: 消息没有收到？**

1. 检查 Webhook URL 是否正确
2. 检查网络连通性
3. 查看 `目录中.log/send_error.log` 是否有发送失败记录

**Q: 如何调试事件捕获？**

临时将 while 循环中 `continue` 前面的注释去掉，开启 IGNORED 日志。

**Q: 日志文件太多占用磁盘？**

调低 `ALERT_LOG_RETENTION`（日志保留天数）即可自动清理。

## 许可证

MIT
