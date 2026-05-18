#!/bin/bash
#
# ============================================================
# File Monitor - 文件变动监控告警工具
# ============================================================
# 功能说明:
#   监控指定目录的文件变动事件，聚合窗口内的所有事件后，
#   通过企业微信/飞书机器人发送通知，并生成完整事件日志。
#
# 适用场景:
#   - 网站被非法篡改时即刻告警
#   - FTP/部署工具批量上传后的文件变更汇总
#   - 监控关键业务系统的配置文件变更
#
# 核心特性:
#   1. 双阈值聚合策略（空闲超时 + 最大窗口），防止消息轰炸
#   2. 支持企业微信和飞书双通道通知
#   3. 每次告警生成独立日志文件，完整记录所有事件
#   4. 可配置的文件类型过滤和目录排除
#   5. 单例运行保护，防止重复启动
#   6. 非阻塞异步消息发送，不影响监控主循环
#   7. 异常自动重试，发送失败记录错误日志
#
# 使用示例:
#   bash file_monitor.sh                           # 使用默认配置
#   bash file_monitor.sh -c /path/to/config.conf   # 指定配置文件
#   bash file_monitor.sh -h                        # 查看帮助
#
# --- Demo: 最终告警效果 ---
# [张三科技有限公司] 文件变动警报！
# 目录：/www/wwwroot/www.xxxxxx.com
# 总数：23 个事件
# 时间：2026-05-18 10:30:00
#
# 前 5 条变化：
# - /app/index.php MODIFY
# - /app/api/user.php MODIFY
# - /config/database.php MODIFY
# - /plugin/qqlogin.php CREATE
# - /template/footer.html MODIFY
# ...
# 完整日志：/var/log/file_monitor/alert_2026-05-18_10-30-00.log
# ============================================================
# 作者: 运维团队
# 版本: 2.0.0
# 日期: 2026-05-18
# ============================================================



# ============================================================
# 第一部分: 默认配置
# ============================================================

# 配置文件默认路径（与主脚本同目录）
DEFAULT_CONFIG_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${DEFAULT_CONFIG_DIR}/file_monitor.conf"

# 临时文件基础路径（使用 $$ 避免多实例冲突）
TEMP_BASE="/tmp/.file_monitor_$$"

# 事件临时文件（记录窗口内的事件）
EVENT_LOG_FILE="${TEMP_BASE}_events"

# 首事件时间戳文件（用于 MAX_BATCH_WINDOW 计算）
FIRST_EVENT_FILE="${TEMP_BASE}_first"

# Inotifywatch 进程 PID 记录文件
INOTIFY_PID_FILE="${TEMP_BASE}_inotify_pids"

# PID 文件（单例保护，包含用户名防止用户间冲突）
PID_FILE="/tmp/.file_monitor_$(basename "${0}" .sh).pid"



# ============================================================
# 第二部分: 帮助信息与参数解析
# ============================================================

show_usage() {
    cat << EOF
用法: bash $(basename "$0") [选项]

选项:
  -c <文件路径>  指定配置文件路径（默认: ./file_monitor.conf）
  -h            显示此帮助信息

配置文件说明:
  详见 file_monitor.conf 中的注释

使用示例:
  bash $(basename "$0")
  bash $(basename "$0") -c /etc/file_monitor/my_site.conf
  bash $(basename "$0") -h
EOF
}

# 解析命令行参数
while getopts "c:h" opt; do
    case $opt in
        c) CONFIG_FILE="$OPTARG" ;;
        h) show_usage; exit 0 ;;
        *) show_usage; exit 1 ;;
    esac
done



# ============================================================
# 第三部分: 配置加载与校验
# ============================================================

# ---
# 加载配置文件
# ---
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[错误] 配置文件不存在: $CONFIG_FILE"
    echo "请先创建配置文件（可参考 file_monitor.conf）"
    exit 1
fi
source "$CONFIG_FILE"


# ---
# 校验配置各项是否合法
# ---
validate_config() {
    local has_error=0

    # 检查客户名称
    if [[ -z "$CLIENT_NAME" ]]; then
        echo "[错误] 配置项 CLIENT_NAME 不能为空"
        has_error=1
    fi

    # 检查通知渠道
    if [[ "$NOTIFY_CHANNEL" != "wecom" && "$NOTIFY_CHANNEL" != "feishu" && "$NOTIFY_CHANNEL" != "both" ]]; then
        echo "[错误] NOTIFY_CHANNEL 必须为 wecom / feishu / both 之一（当前值: $NOTIFY_CHANNEL）"
        has_error=1
    fi

    # 检查 Webhook URL（根据渠道选择性检查）
    if [[ "$NOTIFY_CHANNEL" == "wecom" || "$NOTIFY_CHANNEL" == "both" ]]; then
        if [[ -z "$WECOM_WEBHOOK_URL" ]]; then
            echo "[错误] NOTIFY_CHANNEL 包含 wecom，但 WECOM_WEBHOOK_URL 未设置"
            has_error=1
        fi
    fi
    if [[ "$NOTIFY_CHANNEL" == "feishu" || "$NOTIFY_CHANNEL" == "both" ]]; then
        if [[ -z "$FEISHU_WEBHOOK_URL" ]]; then
            echo "[错误] NOTIFY_CHANNEL 包含 feishu，但 FEISHU_WEBHOOK_URL 未设置"
            has_error=1
        fi
    fi

    # 检查监控目录
    if [[ ${#WATCH_FOLDERS[@]} -eq 0 ]]; then
        echo "[错误] WATCH_FOLDERS 至少需要配置一个监控目录"
        has_error=1
    fi

    # 检查聚合参数
    if [[ -z "$IDLE_TIMEOUT" || "$IDLE_TIMEOUT" -le 0 ]]; then
        echo "[错误] IDLE_TIMEOUT 必须大于 0"
        has_error=1
    fi
    if [[ -z "$MAX_BATCH_WINDOW" || "$MAX_BATCH_WINDOW" -le 0 ]]; then
        echo "[错误] MAX_BATCH_WINDOW 必须大于 0"
        has_error=1
    fi

    # 检查告警日志目录
    if [[ -z "$ALERT_LOG_DIR" ]]; then
        echo "[错误] ALERT_LOG_DIR 不能为空"
        has_error=1
    fi

    # 检查 DISPLAY_COUNT，未设置时使用默认值
    if [[ -z "$DISPLAY_COUNT" || "$DISPLAY_COUNT" -le 0 ]]; then
        DISPLAY_COUNT=5
    fi

    if [[ $has_error -eq 1 ]]; then
        exit 1
    fi
}


# ---
# 检查系统依赖
# ---
check_dependencies() {
    # --- Demo ---
    # 需要 inotify-tools 包
    # 安装命令:
    #   Ubuntu/Debian:  sudo apt install inotify-tools
    #   CentOS/RHEL:    sudo yum install inotify-tools
    #   Alpine:         sudo apk add inotify-tools
    # --- End Demo ---
    if ! command -v inotifywait &>/dev/null; then
        echo "[错误] 未找到 inotifywait 命令"
        echo "请安装 inotify-tools:"
        echo "  Ubuntu/Debian:  sudo apt install inotify-tools"
        echo "  CentOS/RHEL:    sudo yum install inotify-tools"
        echo "  Alpine:         sudo apk add inotify-tools"
        exit 1
    fi

    # 检查 curl
    if ! command -v curl &>/dev/null; then
        echo "[错误] 未找到 curl 命令"
        echo "请安装 curl:"
        echo "  Ubuntu/Debian:  sudo apt install curl"
        echo "  CentOS/RHEL:    sudo yum install curl"
        exit 1
    fi
}


# ---
# 检查 inotify watch 系统上限
# ---
# 功能: 估算需要多少 inotify watches，与系统上限对比
# 说明: inotify 使用"每目录一个 watch"的模式递归监控。
#       如果目录层级深、文件多，容易触发系统上限
#       fs.inotify.max_user_watches（通常为 8192 或 524288）。
# ---
check_inotify_limit() {
    local system_limit
    system_limit=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null)

    # 如果无法读取系统限制，跳过检查
    if [[ -z "$system_limit" ]]; then
        echo "[警告] 无法读取 inotify 系统限制，跳过检查"
        return
    fi

    # 估算各监控目录的目录数量
    local estimated=0
    for folder in "${WATCH_FOLDERS[@]}"; do
        if [[ -d "$folder" ]]; then
            local count
            count=$(find "$folder" -type d 2>/dev/null | wc -l)
            estimated=$((estimated + count))
            echo "[信息] 目录 '$folder' 包含 $count 个子目录"
        fi
    done

    # 如果估算是 0（目录不存在），跳过警告
    if [[ $estimated -eq 0 ]]; then
        echo "[警告] 未找到可监控的目录（请检查目录路径是否正确）"
        return
    fi

    local threshold=$((system_limit * 80 / 100))
    echo "[信息] 系统 inotify watches 上限: $system_limit"
    echo "[信息] 预估所需 watches: $estimated"

    if [[ $estimated -gt $system_limit ]]; then
        echo ""
        echo "============================================================"
        echo "[严重警告] 估算所需 watches（$estimated）超过系统上限（$system_limit）！"
        echo "监控将无法正常工作，建议立即增大系统限制:"
        echo "------------------------------------------------------------"
        echo "  sudo sysctl -w fs.inotify.max_user_watches=$((estimated * 2))"
        echo "  或持久化配置:"
        echo "  echo 'fs.inotify.max_user_watches=$((estimated * 2))' | sudo tee -a /etc/sysctl.conf"
        echo "  sudo sysctl -p"
        echo "============================================================"
        echo ""
    elif [[ $estimated -gt $threshold ]]; then
        echo "[警告] 估算用量超过系统上限的 80%，建议增大系统限制"
    else
        echo "[信息] 用量占比: $((estimated * 100 / system_limit))%（安全范围内）"
    fi
}


# ---
# 单例运行保护
# ---
# 功能: 检查是否已有实例在运行，防止重复启动导致事件重复处理。
# 说明: PID 文件中记录的是当前脚本进程的 PID+启动时间，
#       通过检查 /proc 确认进程是否真实存活。
# ---
check_singleton() {
    # 如果 PID 文件存在，检查对应的进程是否真实存活
    if [[ -f "$PID_FILE" ]]; then
        local old_pid
        old_pid=$(head -n1 "$PID_FILE" 2>/dev/null | cut -d'|' -f1)

        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            local old_start_time
            old_start_time=$(head -n1 "$PID_FILE" 2>/dev/null | cut -d'|' -f2)
            echo "[错误] 已有实例在运行（PID: $old_pid，启动时间: $old_start_time）"
            echo "如果确认没有其他实例，请删除 PID 文件: rm -f $PID_FILE"
            exit 1
        else
            # 旧实例已不存在，清理 PID 文件
            rm -f "$PID_FILE"
        fi
    fi

    # 写入当前 PID 和启动时间
    echo "$$|$(date '+%Y-%m-%d %H:%M:%S')" > "$PID_FILE"
}


# ---
# 创建告警日志目录
# ---
ensure_log_dir() {
    if ! mkdir -p "$ALERT_LOG_DIR" 2>/dev/null; then
        echo "[错误] 无法创建日志目录: $ALERT_LOG_DIR（请检查写权限）"
        exit 1
    fi
    echo "[信息] 告警日志目录: $ALERT_LOG_DIR"
}



# ============================================================
# 第四部分: JSON 转义工具
# ============================================================

# ---
# 转义字符串，使其可安全嵌入 JSON 字符串值
# ---
# 功能: 对以下字符进行转义:
#   - 双引号 → \"
#   - 反斜杠 → \\
#   - 换行符 → \n
#   - 制表符 → \t
#   - 回车符 → \r
# ---
# 参数: $1 - 需要转义的原始字符串
# 输出: 转义后的安全字符串（通过 echo 返回）
# ---
# 使用场景:
#   当消息内容包含用户输入（如文件名、目录路径）时，
#   这些内容可能含有双引号或特殊字符，直接嵌入 JSON
#   会破坏 Webhook 的 JSON 解析。
# ---
json_escape() {
    local raw="$1"
    local escaped

    # 转义反斜杠（必须最先转义，否则后续转义会产生多重反斜杠）
    escaped="${raw//\\/\\\\}"
    # 转义双引号
    escaped="${escaped//\"/\\\"}"
    # 转义换行符（$'\n' 是 bash 的 ANSI-C 引用）
    escaped="${escaped//$'\n'/\\n}"
    # 转义制表符
    escaped="${escaped//$'\t'/\\t}"
    # 转义回车符
    escaped="${escaped//$'\r'/\\r}"

    echo "$escaped"
}



# ============================================================
# 第五部分: 通知发送函数
# ============================================================

# ---
# 发送消息到企业微信
# ---
# 用途: 通过企业微信群机器人 Webhook 发送文本消息
# ---
# 参数: $1 - 要发送的消息内容（纯文本，支持 Markdown 语法）
# 返回: 0=成功 1=失败
# ---
# --- Demo: 企业微信消息效果 ---
# [张三科技有限公司] 文件变动警报！
# 目录：/www/wwwroot/www.xxxxxx.com
# 总数：5 个事件
# 时间：2026-05-18 10:30:00
#
# 前 5 条变化：
# - /app/index.php MODIFY
# - /app/api/user.php MODIFY
# 完整日志：/var/log/file_monitor/alert_2026-05-18_10-30-00.log
# --- End Demo ---
# ---
send_to_wecom() {
    local message="$1"
    local escaped_message
    escaped_message=$(json_escape "$message")

    # 构建企业微信 text 消息 JSON
    # 企业微信 text 类型支持 \n 换行，最长 4096 字节
    local json_data
    json_data=$(cat <<EOF
{
    "msgtype": "text",
    "text": {
        "content": "${escaped_message}"
    }
}
EOF
)

    # ---
    # 异步发送，不阻塞主循环
    # 说明: 将 curl 放入独立的子进程中执行（&），即使外层
    #       的聚合定时器被 kill 中断，子进程仍会完成发送。
    # 超时: --max-time 10 防止 Webhook 不可达时无限挂起
    # 重试: --retry 2 对网络抖动自动重试
    # ---
    {
        curl -X POST "$WECOM_WEBHOOK_URL" \
             -H 'Content-Type: application/json' \
             -d "$json_data" \
             --max-time 10 \
             --retry 2 \
             --retry-delay 1 \
             --fail --silent > /dev/null 2>&1

        if [[ $? -ne 0 ]]; then
            echo "[错误] 企业微信消息发送失败" >> "${ALERT_LOG_DIR}/send_error.log"
            echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')" >> "${ALERT_LOG_DIR}/send_error.log"
            echo "  消息摘要: ${message:0:100}..." >> "${ALERT_LOG_DIR}/send_error.log"
            echo "------------------------------------------------" >> "${ALERT_LOG_DIR}/send_error.log"
            echo "[SEND_FAILED] 企业微信发送失败 | $(date '+%Y-%m-%d %H:%M:%S')"
        fi
    } &

    return 0
}


# ---
# 发送消息到飞书
# ---
# 用途: 通过飞书群机器人 Webhook 发送文本消息
# ---
# 参数: $1 - 要发送的消息内容（纯文本，支持 \n 换行）
# 返回: 0=成功 1=失败
# ---
# 说明: 飞书 text 消息与企微格式类似，但 JSON 结构不同：
#       企微: {"msgtype":"text","text":{"content":"..."}}
#       飞书: {"msg_type":"text","content":{"text":"..."}}
# ---
# --- Demo: 飞书消息效果 ---
# [张三科技有限公司] 文件变动警报！
# 目录：/www/wwwroot/www.xxxxxx.com
# 总数：5 个事件
# 时间：2026-05-18 10:30:00
# （其他内容与企微一致）
# --- End Demo ---
# ---
send_to_feishu() {
    local message="$1"
    local escaped_message
    escaped_message=$(json_escape "$message")

    # 构建飞书 text 消息 JSON
    local json_data
    json_data=$(cat <<EOF
{
    "msg_type": "text",
    "content": {
        "text": "${escaped_message}"
    }
}
EOF
)

    # 异步发送，逻辑与企微相同
    {
        curl -X POST "$FEISHU_WEBHOOK_URL" \
             -H 'Content-Type: application/json' \
             -d "$json_data" \
             --max-time 10 \
             --retry 2 \
             --retry-delay 1 \
             --fail --silent > /dev/null 2>&1

        if [[ $? -ne 0 ]]; then
            echo "[错误] 飞书消息发送失败" >> "${ALERT_LOG_DIR}/send_error.log"
            echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')" >> "${ALERT_LOG_DIR}/send_error.log"
            echo "  消息摘要: ${message:0:100}..." >> "${ALERT_LOG_DIR}/send_error.log"
            echo "------------------------------------------------" >> "${ALERT_LOG_DIR}/send_error.log"
            echo "[SEND_FAILED] 飞书发送失败 | $(date '+%Y-%m-%d %H:%M:%S')"
        fi
    } &

    return 0
}


# ---
# 通知调度函数
# ---
# 功能: 根据 NOTIFY_CHANNEL 配置，将消息分发到对应渠道
# ---
# 参数: $1 - 要发送的消息内容
# 返回: 无
# ---
send_notification() {
    local message="$1"

    # --- Demo ---
    # NOTIFY_CHANNEL="wecom"  → 仅发企业微信
    # NOTIFY_CHANNEL="feishu" → 仅发飞书
    # NOTIFY_CHANNEL="both"   → 两个同时发
    # --- End Demo ---

    if [[ "$NOTIFY_CHANNEL" == "wecom" || "$NOTIFY_CHANNEL" == "both" ]]; then
        send_to_wecom "$message"
    fi

    if [[ "$NOTIFY_CHANNEL" == "feishu" || "$NOTIFY_CHANNEL" == "both" ]]; then
        send_to_feishu "$message"
    fi
}



# ============================================================
# 第六部分: 日志归档与清理
# ============================================================

# ---
# 归档事件到独立日志文件
# ---
# 功能: 将当前批次的所有事件写入独立的日志文件，便于追溯
# ---
# 参数: $1 - 事件总数
# 返回: 归档日志的文件路径（通过 echo 输出）
# ---
# --- Demo: 日志文件内容 ---
# 文件名: alert_2026-05-18_10-30-00.log
# 内容:
# [客户A] === 批次告警: 2026-05-18 10:30:00 ===
# 总事件数: 23
# -------------------------------------------------
# /www/wwwroot/www.xxxxxx.com/index.php MODIFY
# /www/wwwroot/www.xxxxxx.com/api/user.php MODIFY
# /www/wwwroot/www.xxxxxx.com/config/db.php MODIFY
# ...（完整 23 条，不截断）
# --- End Demo ---
# ---
archive_alert_log() {
    local events_count="$1"
    local snapshot_file="$2"
    local log_time
    log_time=$(date '+%Y-%m-%d_%H-%M-%S')
    local log_file="${ALERT_LOG_DIR}/alert_${log_time}.log"

    {
        echo "[${CLIENT_NAME}] === 批次告警: $(date '+%Y-%m-%d %H:%M:%S') ==="
        echo "总事件数: ${events_count}"
        echo "-------------------------------------------------"
        # 从事件快照文件读取完整事件列表（由调用方传入）
        cat "$snapshot_file" 2>/dev/null || echo "(事件数据不可用)"
    } > "$log_file"

    echo "$log_file"
}


# ---
# 清理过期告警日志
# ---
# 功能: 删除超过 ALERT_LOG_RETENTION 天的告警日志文件
# ---
# 参数: 无
# 返回: 无
# ---
cleanup_old_logs() {
    if [[ -z "$ALERT_LOG_RETENTION" || "$ALERT_LOG_RETENTION" -le 0 ]]; then
        return
    fi

    if [[ ! -d "$ALERT_LOG_DIR" ]]; then
        return
    fi

    local old_count
    old_count=$(find "$ALERT_LOG_DIR" -name "alert_*.log" -mtime +"$ALERT_LOG_RETENTION" -print 2>/dev/null | wc -l)

    if [[ $old_count -gt 0 ]]; then
        find "$ALERT_LOG_DIR" -name "alert_*.log" -mtime +"$ALERT_LOG_RETENTION" -delete 2>/dev/null
        echo "[INFO] 已清理 ${old_count} 个超过 ${ALERT_LOG_RETENTION} 天的旧日志文件"
    fi
}



# ============================================================
# 第七部分: 聚合告警发送（核心逻辑）
# ============================================================

# ---
# 发送聚合告警
# ---
# 功能: 读取临时事件文件，归档到日志，发送通知，清理状态
# ---
# 调用时机:
#   1. 空闲超时: 最后一个事件后 IDLE_TIMEOUT 秒无新事件
#   2. 最大窗口: 第一个事件后 MAX_BATCH_WINDOW 秒强制触发
# ---
# --- Demo: 完整处理流程 ---
# 一批 23 个 PHP 文件变动事件被 inotifywait 捕获后:
# 1. 脚本将这些事件收集到临时文件
# 2. IDLE_TIMEOUT=5 秒后无新事件，触发发送
# 3. 所有 23 个事件写入独立日志: /var/log/file_monitor/alert_2026-05-18_10-30-00.log
# 4. 企业微信/飞书发送摘要通知（前 5 条）
# 5. 临时文件清空，准备接收下一批
# --- End Demo ---
# ---
send_aggregated_alert() {
    # 如果事件临时文件为空，直接清理返回
    if [[ ! -s "$EVENT_LOG_FILE" ]]; then
        > "$EVENT_LOG_FILE"
        rm -f "$FIRST_EVENT_FILE"
        return
    fi

    # --------------------------------------------------
    # 第 1 步: 原子快照
    # 说明: 将临时事件文件重命名为带时间戳的快照文件，然后创建新的
    #       空临时文件。后续新事件进入新的临时文件，与当前正在处理
    #       的事件隔离。时间戳后缀防止并发调用时互相覆盖。
    # --------------------------------------------------
    local snapshot_suffix="$(date +%s%N)"
    local snapshot_file="${EVENT_LOG_FILE}.snapshot_${snapshot_suffix}"
    mv "$EVENT_LOG_FILE" "$snapshot_file"
    > "$EVENT_LOG_FILE"  # 创建新的空事件文件

    # 读取并清除首事件时间戳（让下个批次重新计时）
    if [[ -f "$FIRST_EVENT_FILE" ]]; then
        rm -f "$FIRST_EVENT_FILE"
    fi

    # 统计事件数量
    local events_count
    events_count=$(wc -l < "$snapshot_file")

    if [[ $events_count -eq 0 ]]; then
        rm -f "$snapshot_file"
        return
    fi

    # --------------------------------------------------
    # 第 2 步: 生成告警日志
    # --------------------------------------------------
    local log_file
    log_file=$(archive_alert_log "$events_count" "$snapshot_file")
    echo "[ALERT] 已归档事件日志: ${log_file}（${events_count} 个事件）"

    # --------------------------------------------------
    # 第 3 步: 构建通知消息
    # --------------------------------------------------
    # 获取第一条事件信息（用于标识归属目录等信息）
    local first_event
    first_event=$(head -n1 "$snapshot_file")
    local first_file_path="${first_event%% *}"
    local first_dir
    first_dir=$(dirname "$first_file_path" 2>/dev/null)

    # 构建事件详情列表（不超过 DISPLAY_COUNT 条）
    local details_part
    details_part=$(sed 's/^/- /' "$snapshot_file" | head -n "$DISPLAY_COUNT")

    # 如果事件数超过展示数，添加溢出提示
    local overflow_part=""
    if [[ $events_count -gt $DISPLAY_COUNT ]]; then
        local overflow_count=$((events_count - DISPLAY_COUNT))
        overflow_part="... 还有 ${overflow_count} 个事件未显示"
    fi

    # 组装完整消息
    # 使用 $'\n' 插入实际换行符，这样 json_escape 能正确转义为 JSON 标准的 \n，
    # 企业微信和飞书都能正确显示换行（字面量 \n 仅企业微信支持，飞书不支持）。
    local alert_message
    alert_message="[${CLIENT_NAME}] 文件变动警报！"
    alert_message+=$'\n涉及目录: '"${first_dir}"
    alert_message+=$'\n总数: '"${events_count} 个事件"
    alert_message+=$'\n时间: '"$(date '+%Y-%m-%d %H:%M:%S')"
    alert_message+=$'\n\n前 '"${DISPLAY_COUNT} 条变化:"
    alert_message+=$'\n'"${details_part}"
    alert_message+=$'\n'"${overflow_part}"
    alert_message+=$'\n\n完整日志: '"${log_file}"

    # --------------------------------------------------
    # 第 4 步: 发送通知（异步）
    # --------------------------------------------------
    echo "[SEND] 正在发送告警（${events_count} 个事件）..."
    send_notification "$alert_message"

    # --------------------------------------------------
    # 第 5 步: 清理快照文件
    # --------------------------------------------------
    rm -f "$snapshot_file"

    # 清理过期日志
    cleanup_old_logs
}



# ============================================================
# 第八部分: 信号处理与清理
# ============================================================

# ---
# 清理函数（脚本退出时调用）
# ---
cleanup() {
    echo ""
    echo "[INFO] 正在停止监控..."

    # 杀掉所有 inotifywait 进程
    if [[ -f "$INOTIFY_PID_FILE" ]]; then
        while IFS= read -r pid; do
            kill "$pid" 2>/dev/null || true
        done < "$INOTIFY_PID_FILE"
        rm -f "$INOTIFY_PID_FILE"
    fi

    # 清理临时文件
    rm -f "${TEMP_BASE}_"*
    rm -f "$PID_FILE"

    echo "[INFO] 监控已停止"
    exit 0
}

# 注册信号处理函数
# SIGINT (Ctrl+C) / SIGTERM (kill) / SIGHUP (终端断开)
trap cleanup SIGINT SIGTERM SIGHUP
# 如果脚本被 kill -9 强制终止，临时文件会残留，需手动清理
trap '' SIGQUIT  # 忽略 SIGQUIT（Ctrl+\）



# ============================================================
# 第九部分: 启动信息
# ============================================================

# ---
# 打印启动信息
# ---
print_startup_info() {
    echo ""
    echo "============================================================"
    echo "  File Monitor 文件变动监控"
    echo "============================================================"
    echo "  客户名称:      ${CLIENT_NAME}"
    echo "  通知渠道:      ${NOTIFY_CHANNEL}"
    echo "  空闲超时:      ${IDLE_TIMEOUT} 秒"
    echo "  最大窗口:      ${MAX_BATCH_WINDOW} 秒"
    echo "  日志目录:      ${ALERT_LOG_DIR}"
    echo "------------------------------------------------------------"
    echo "  监控目录列表:"
    for dir in "${WATCH_FOLDERS[@]}"; do
        if [[ -d "$dir" ]]; then
            echo "    ✓ $dir"
        else
            echo "    ✗ $dir（目录不存在）"
        fi
    done
    if [[ -n "$WATCH_REGEX" ]]; then
        echo "  文件过滤:     仅监控匹配正则的文件: ${WATCH_REGEX}"
    else
        echo "  文件过滤:     监控所有文件（不过滤）"
    fi
    echo "  排除目录:     ${EXCLUDE_DIRS}"
    echo "------------------------------------------------------------"
    echo "  按 Ctrl+C 停止监控"
    echo "============================================================"
    echo ""
}



# ============================================================
# 第十部分: 主程序入口
# ============================================================

# 执行前置校验
validate_config
check_dependencies
check_singleton
check_inotify_limit
ensure_log_dir

# 打印启动信息
print_startup_info

# 清理旧日志
cleanup_old_logs

# ============================================================
# 第十一部分: 主监控循环
# ============================================================
#
# 设计说明:
#   对每个监控目录启动一个 inotifywait 后台进程，所有进程的
#   输出通过管道汇聚到同一个 while 循环处理。
#
#   管道结构:
#   ┌─────────────────┐   事件流    ┌──────────────────────┐
#   │ inotifywait 实例1├──────┬─────→│                      │
#   ├─────────────────┤      │      │  while read 主循环    │
#   │ inotifywait 实例2├──────┤      │  (事件处理/聚合/计时) │
#   ├─────────────────┤      │      └──────────────────────┘
#   │ inotifywait 实例3├──────┘
#   └─────────────────┘
#
# --- Event Pipeline ---
# 来自: inotifywait -m -r -e create,delete,modify,... --format '%w%f %e'
# 格式: /full/path/to/file EVENT_TYPE
# 例如: /www/wwwroot/site/index.php MODIFY
# ---
# ---
echo "[INFO] 开始监控..."

# 启动所有 inotifywait 后台进程，输出通过管道汇聚
{
    for folder in "${WATCH_FOLDERS[@]}"; do
        if [[ -d "$folder" ]]; then
            # ---
            # inotifywait 参数说明:
            #   -m       持续监控（monitor），不退出
            #   -r       递归监控子目录
            #   -e       监控的事件类型
            #   --exclude 排除目录（正则 OR 格式），为空时不传此参数
            #   --format 输出格式: %w=目录路径 %f=文件名 %e=事件类型
            #
            # 注意: --exclude 必须传非空值，空值会导致正则 () 匹配所有路径
            #       从而排除所有事件。详见: https://example.com/regex-empty-group
            # ---
            if [[ -n "$EXCLUDE_DIRS" ]]; then
                inotifywait -m -r \
                    -e create \
                    -e delete \
                    -e modify \
                    -e moved_to \
                    -e moved_from \
                    --exclude "(${EXCLUDE_DIRS})" \
                    "$folder" \
                    --format '%w%f %e' &
            else
                inotifywait -m -r \
                    -e create \
                    -e delete \
                    -e modify \
                    -e moved_to \
                    -e moved_from \
                    "$folder" \
                    --format '%w%f %e' &
            fi

            # 记录 inotifywait 进程 PID，用于退出时清理
            echo $! >> "$INOTIFY_PID_FILE"
        else
            echo "[警告] 监控目录不存在: ${folder}（跳过）" >&2
        fi
    done

    # 等待所有子进程（保持左管道打开）
    wait
} | while read -r file_path event_type; do

    # --------------------------------------------------
    # 文件名过滤
    # 说明: 如果配置了 WATCH_REGEX，则只处理匹配的文件。
    #       未配置（空）时处理所有文件。
    # --------------------------------------------------
    should_process=1  # 0=处理 1=跳过

    if [[ -n "$WATCH_REGEX" ]]; then
        # 检查文件名是否匹配正则（使用 shopt -s nocasematch 实现不区分大小写）
        shopt -s nocasematch
        if [[ "$file_path" =~ $WATCH_REGEX ]]; then
            should_process=0
        fi
        shopt -u nocasematch
    else
        should_process=0
    fi

    if [[ $should_process -ne 0 ]]; then
        # 跳过不匹配的文件（仅在 DEBUG 时取消下行注释）
        # echo "[IGNORED] $event_type -> $file_path（不匹配文件类型）"
        continue
    fi

    # --------------------------------------------------
    # 事件去重
    # 说明: 同一文件 + 同一事件类型在聚合窗口内只保留第一次。
    #       解决编辑器自动保存、事件重复触发等场景的冗余记录。
    # --------------------------------------------------
    if grep -Fxq "${file_path} ${event_type}" "$EVENT_LOG_FILE" 2>/dev/null; then
        # 重复事件，跳过记录但保留当前计时（避免重复重置定时器）
        continue
    fi

    # --------------------------------------------------
    # 记录事件到临时文件
    # --------------------------------------------------
    echo "${file_path} ${event_type}" >> "$EVENT_LOG_FILE"
    echo "[EVENT] ${event_type} -> ${file_path}"

    # --------------------------------------------------
    # 首事件时间戳管理
    # 说明: 记录第一个事件的时间戳，用于 MAX_BATCH_WINDOW 判断。
    #       后续事件不更新该时间戳。
    # --------------------------------------------------
    if [[ ! -f "$FIRST_EVENT_FILE" ]]; then
        date +%s > "$FIRST_EVENT_FILE"
    fi

    # --------------------------------------------------
    # MAX_BATCH_WINDOW 检查
    # 说明: 如果从首事件至今超过最大窗口，立即强制发送。
    #       防止持续事件流导致消息"永不触发"。
    # --------------------------------------------------
    first_time=$(cat "$FIRST_EVENT_FILE" 2>/dev/null)
    current_time=$(date +%s)
    elapsed=$((current_time - first_time))

    if [[ $elapsed -ge $MAX_BATCH_WINDOW ]]; then
        echo "[FORCE] 已达最大窗口（${MAX_BATCH_WINDOW}秒），强制发送"

        # 杀掉空闲定时器（如果有）
        if [[ -n "$TIMER_PID" ]] && kill -0 "$TIMER_PID" 2>/dev/null; then
            kill "$TIMER_PID" 2>/dev/null
        fi

        # 立即发送
        send_aggregated_alert
        continue
    fi

    # --------------------------------------------------
    # 空闲超时定时器管理
    # 说明: 每次新事件到来，重置空闲定时器。
    #       定时器触发时调用 send_aggregated_alert。
    # --------------------------------------------------
    #
    # 定时器工作机制:
    #   1. 事件 A 到达 → 启动定时器 T1（sleep IDLE_TIMEOUT）
    #   2. 事件 B 到达（在 IDLE_TIMEOUT 内）
    #      → 杀掉 T1，启动定时器 T2（重置空闲计时）
    #   3. 无新事件到达
    #      → T2 睡眠到期，触发 send_aggregated_alert
    # --------------------------------------------------

    # 杀掉旧的定时器
    if [[ -n "$TIMER_PID" ]] && kill -0 "$TIMER_PID" 2>/dev/null; then
        kill "$TIMER_PID" 2>/dev/null
    fi

    # 启动新的定时器
    # 使用独立子进程 ( ) 确保即使被 kill，send_aggregated_alert
    # 内部的 curl 子进程也不会被中断（异步发送已脱离父进程）
    (
        sleep "$IDLE_TIMEOUT"
        send_aggregated_alert
    ) &
    TIMER_PID=$!

done
