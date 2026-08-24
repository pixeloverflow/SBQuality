#!/usr/bin/env bash
#
# SBQuailty - lib/common.sh
# 通用工具：颜色、宽度对齐、进度、结果存储、依赖安装、权限分级。
#
# 本文件被 source，不直接执行。所有函数以 sb_ 前缀，全局变量以 SB_ 前缀。
# 注意：入口不启用 set -Eeuo pipefail（bench_/ipq_ 依赖命令失败继续执行）。

# ===================== 颜色 =====================
if [ -t 1 ] && [ "${SB_NO_COLOR:-0}" -ne 1 ]; then
  SB_RED=$'\033[0;31m'
  SB_GREEN=$'\033[0;32m'
  SB_YELLOW=$'\033[0;33m'
  SB_BLUE=$'\033[0;34m'
  SB_CYAN=$'\033[0;36m'
  SB_WHITE=$'\033[1;37m'
  SB_DIM=$'\033[2m'
  SB_BOLD=$'\033[1m'
  SB_UNDERLINE=$'\033[4m'
  SB_NC=$'\033[0m'
else
  SB_RED='' SB_GREEN='' SB_YELLOW='' SB_BLUE='' SB_CYAN='' SB_WHITE=''
  SB_DIM='' SB_BOLD='' SB_UNDERLINE='' SB_NC=''
fi

SB_OK="${SB_GREEN}[√]${SB_NC}"
SB_WARN="${SB_YELLOW}[!]${SB_NC}"
SB_ERR="${SB_RED}[X]${SB_NC}"
SB_INFO="${SB_DIM}[i]${SB_NC}"

sb_ok()   { echo -e "  $SB_OK $*"; }
sb_warn() { echo -e "  $SB_WARN $*" >&2; }
sb_err()  { echo -e "  $SB_ERR $*" >&2; }
sb_info() { echo -e "  $SB_INFO ${SB_DIM}$*${SB_NC}"; }
sb_debug() { [ "${SB_DEBUG:-0}" -eq 1 ] && echo -e "  ${SB_DIM}[debug] $*${SB_NC}" >&2; return 0; }

# ===================== 运行目录与清理 =====================
# SB_RUN_DIR  结果存储根目录
# SB_TMP_DIR  各模块临时文件（二进制下载、fio 测试文件等）
sb_init_rundir() {
  [ -n "${SB_RUN_DIR:-}" ] && [ -d "$SB_RUN_DIR" ] && return 0
  SB_RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sbquality.XXXXXX") || {
    sb_err "无法创建临时目录"
    exit 1
  }
  SB_TMP_DIR="$SB_RUN_DIR/tmp"
  mkdir -p "$SB_RUN_DIR/rows" "$SB_TMP_DIR"
  : > "$SB_RUN_DIR/kv"
  : > "$SB_RUN_DIR/status"
  export SB_RUN_DIR SB_TMP_DIR
}

sb_cleanup_rundir() {
  if [ "${SB_DEBUG:-0}" -eq 1 ]; then
    [ -n "${SB_RUN_DIR:-}" ] && echo -e "\n  ${SB_DIM}调试模式：运行目录已保留 $SB_RUN_DIR${SB_NC}" >&2
    return 0
  fi
  [ -n "${SB_RUN_DIR:-}" ] && [ -d "$SB_RUN_DIR" ] && rm -rf -- "$SB_RUN_DIR"
  return 0
}

# ===================== 结果存储 =====================
# 标量：sb_kv_set <key> <value>        —— key 用点号分层，如 system.cpu.model
#      sb_kv_get <key> [default]
# 表格：sb_row_add <table> <col1> ...  —— 写入 rows/<table>.tsv，制表符分隔
#      sb_table_read <table>          —— 输出全部行（TSV）
#      sb_table_rows <table>          —— 行数
# 状态：sb_status_set <module> <ok|skip|fail> [reason]

sb_kv_set() {
  local key="$1"
  shift
  local value="$*"
  # 去掉可能破坏 TSV 的字符
  value=${value//$'\t'/ }
  value=${value//$'\n'/ }
  printf '%s\t%s\n' "$key" "$value" >> "$SB_RUN_DIR/kv"
}

sb_kv_get() {
  local key="$1" default="${2:-}" value
  # 用 index/substr 取值：不能用 $1="" 重建 $0，那会把值里的制表符换成空格
  value=$(awk -v k="$key" '
    index($0, k "\t") == 1 { v = substr($0, length(k) + 2) }
    END { print v }
  ' "$SB_RUN_DIR/kv" 2>/dev/null)
  [ -n "$value" ] && printf '%s' "$value" || printf '%s' "$default"
}

sb_kv_has() {
  awk -F'\t' -v k="$1" '$1 == k { found=1 } END { exit found ? 0 : 1 }' "$SB_RUN_DIR/kv" 2>/dev/null
}

# 列出某前缀下的全部 key（去重，保留最后一次写入的值，保持首次出现顺序）
sb_kv_prefix() {
  awk -v p="$1" '
    index($0, p) != 1 { next }
    {
      t = index($0, "\t")
      if (t == 0) next
      k = substr($0, 1, t - 1)
      val = substr($0, t + 1)
      if (!(k in seen)) { seen[k] = 1; order[++n] = k }
      v[k] = val
    }
    END { for (i = 1; i <= n; i++) printf "%s\t%s\n", order[i], v[order[i]] }
  ' "$SB_RUN_DIR/kv" 2>/dev/null
}

sb_row_add() {
  local table="$1"
  shift
  local out="$SB_RUN_DIR/rows/${table}.tsv" field line=""
  for field in "$@"; do
    field=${field//$'\t'/ }
    field=${field//$'\n'/ }
    line+="${field}"$'\t'
  done
  printf '%s\n' "${line%$'\t'}" >> "$out"
}

sb_table_read() {
  local f="$SB_RUN_DIR/rows/${1}.tsv"
  [ -s "$f" ] && cat "$f"
  return 0
}

sb_table_rows() {
  local f="$SB_RUN_DIR/rows/${1}.tsv"
  [ -s "$f" ] && wc -l < "$f" | tr -d ' ' || echo 0
}

sb_table_exists() {
  [ -s "$SB_RUN_DIR/rows/${1}.tsv" ]
}

# sb_split_tsv <行>  —— 按制表符切分，结果放进全局数组 SB_FIELDS
#
# 不能用 `IFS=$'\t' read -r -a arr`：制表符属于 IFS 空白类，bash 会把连续制表符
# 合并成一个分隔符并丢弃首尾空字段，导致含空单元格的行整体错列。
sb_split_tsv() {
  local rest="$1"
  SB_FIELDS=()
  while :; do
    SB_FIELDS+=("${rest%%$'\t'*}")
    case "$rest" in
      *$'\t'*) rest="${rest#*$'\t'}" ;;
      *) break ;;
    esac
  done
}

sb_status_set() {
  local module="$1" state="$2" reason="${3:-}"
  reason=${reason//$'\t'/ }
  printf '%s\t%s\t%s\n' "$module" "$state" "$reason" >> "$SB_RUN_DIR/status"
}

sb_status_read() {
  [ -s "$SB_RUN_DIR/status" ] && cat "$SB_RUN_DIR/status"
  return 0
}

# 跳过某模块并记录原因（同时在终端提示）
sb_skip() {
  local module="$1" reason="$2"
  sb_status_set "$module" skip "$reason"
  sb_warn "已跳过 ${module}：${reason}"
}

# ===================== 显示宽度与对齐 =====================
# 合并自 IPQuality:calculate_display_width 与 TcpQuality:speedtest_display_width。
# CJK 全角字符按 2 列宽度计算；先剥离 ANSI 转义序列。

sb_strip_ansi() {
  printf '%s' "$1" | sed $'s/\033\\[[0-9;]*[a-zA-Z]//g'
}

sb_display_width() {
  local text
  text=$(sb_strip_ansi "$1")
  # 逐字节判断：UTF-8 首字节 >= 0xC0 的多字节字符按全角 2 列计（覆盖 CJK、
  # 全角标点、方框绘制符），续字节不计宽。用 od 保证 mawk/gawk 行为一致。
  printf '%s' "$text" | od -An -tu1 -v 2>/dev/null | awk '
    {
      for (i = 1; i <= NF; i++) {
        b = $i + 0
        if (b < 0x80) w += 1                 # ASCII
        else if (b >= 0xC0) w += 2           # 多字节首字节
        # 0x80-0xBF 为续字节，不计宽
      }
    }
    END { print w + 0 }
  '
}

# sb_pad_right <text> <width>  左对齐补空格
sb_pad_right() {
  local text="$1" width="$2" w pad
  w=$(sb_display_width "$text")
  pad=$((width - w))
  [ "$pad" -lt 0 ] && pad=0
  printf '%s%*s' "$text" "$pad" ''
}

# sb_pad_left <text> <width>  右对齐
sb_pad_left() {
  local text="$1" width="$2" w pad
  w=$(sb_display_width "$text")
  pad=$((width - w))
  [ "$pad" -lt 0 ] && pad=0
  printf '%*s%s' "$pad" '' "$text"
}

# sb_pad_center <text> <width>
sb_pad_center() {
  local text="$1" width="$2" w pad left right
  w=$(sb_display_width "$text")
  pad=$((width - w))
  [ "$pad" -lt 0 ] && pad=0
  left=$((pad / 2))
  right=$((pad - left))
  printf '%*s%s%*s' "$left" '' "$text" "$right" ''
}

# ===================== 单位格式化（来自 YABS） =====================
# sb_format_size <KiB>  -> "1.5 GiB"
sb_format_size() {
  local raw="$1" result denom=1 unit="KiB"
  [[ "$raw" =~ ^[0-9]+$ ]] || { echo ""; return 0; }
  result=$raw
  if [ "$raw" -ge 1073741824 ]; then denom=1073741824; unit="TiB"
  elif [ "$raw" -ge 1048576 ]; then denom=1048576; unit="GiB"
  elif [ "$raw" -ge 1024 ]; then denom=1024; unit="MiB"
  fi
  result=$(awk -v a="$result" -v b="$denom" 'BEGIN { printf "%0.1f", a / b }')
  echo "$result $unit"
}

# sb_format_speed <KiB/s> -> "1.23 GB/s"  （fio terse v3 带宽字段固定为 KiB/s）
sb_format_speed() {
  local raw="$1" result unit="KB/s"
  [ -z "$raw" ] && { echo ""; return 0; }
  [[ "$raw" =~ ^[0-9]+$ ]] || { echo ""; return 0; }
  if [ "$raw" -ge 976563 ]; then
    unit="GB/s"; result=$(awk -v a="$raw" 'BEGIN { printf "%0.2f", a * 1024 / 1000000000 }')
  elif [ "$raw" -ge 977 ]; then
    unit="MB/s"; result=$(awk -v a="$raw" 'BEGIN { printf "%0.2f", a * 1024 / 1000000 }')
  else
    result=$(awk -v a="$raw" 'BEGIN { printf "%0.2f", a * 1024 / 1000 }')
  fi
  echo "$result $unit"
}

# sb_format_iops <n> -> "275.9k"
sb_format_iops() {
  local raw="$1" result
  [ -z "$raw" ] && { echo ""; return 0; }
  [[ "$raw" =~ ^[0-9]+$ ]] || { echo "$raw"; return 0; }
  if [ "$raw" -ge 1000 ]; then
    result=$(awk -v a="$raw" 'BEGIN { printf "%0.1f", a / 1000 }')
    echo "${result}k"
  else
    echo "$raw"
  fi
}

# ===================== JSON 转义 =====================
sb_json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/}
  s=${s//$'\n'/\\n}
  # 剥离 ANSI
  printf '%s' "$s" | sed $'s/\033\\[[0-9;]*[a-zA-Z]//g'
}

# 判断字符串是否可作为 JSON 数字裸输出
sb_is_number() {
  [[ "$1" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]
}

# sb_json_value <raw>  —— 数字裸输出，空值输出 null，其余加引号转义
sb_json_value() {
  local v="$1"
  if [ -z "$v" ] || [ "$v" = "null" ]; then
    printf 'null'
  elif sb_is_number "$v"; then
    printf '%s' "$v"
  else
    printf '"%s"' "$(sb_json_escape "$v")"
  fi
}

# ===================== HTML 转义 =====================
sb_html_escape() {
  local s
  s=$(sb_strip_ansi "$1")
  s=${s//&/&amp;}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  s=${s//\"/&quot;}
  printf '%s' "$s"
}

# ===================== 命令与依赖 =====================
sb_has() { command -v "$1" >/dev/null 2>&1; }

sb_is_nixos() {
  [ -e /etc/NIXOS ] || grep -qi '^ID=nixos' /etc/os-release 2>/dev/null
}

# sb_pkg_manager -> apt|dnf|yum|apk|pacman|zypper|brew|nix|""
sb_pkg_manager() {
  if sb_is_nixos; then echo nix; return; fi
  local m
  for m in apt-get dnf yum apk pacman zypper brew; do
    if sb_has "$m"; then
      [ "$m" = apt-get ] && echo apt || echo "$m"
      return
    fi
  done
  echo ""
}

# sb_install_deps <pkg...>  —— 合并自 TcpQuality:install_with_package_manager 与 IPQuality:install_packages
# 包名按发行版映射由调用方通过 sb_pkg_for 解析。
sb_install_deps() {
  [ "$#" -eq 0 ] && return 0
  local mgr
  mgr=$(sb_pkg_manager)
  [ -z "$mgr" ] && { sb_warn "未识别的包管理器，请手动安装：$*"; return 1; }
  if [ "$(id -u)" -ne 0 ] && [ "$mgr" != brew ] && [ "$mgr" != nix ]; then
    sb_warn "缺少依赖且当前非 root，无法自动安装：$*"
    return 1
  fi
  sb_info "正在安装依赖：$*"
  case "$mgr" in
    apt)    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1 ;;
    dnf)    dnf install -y -q "$@" >/dev/null 2>&1 ;;
    yum)    yum install -y -q "$@" >/dev/null 2>&1 ;;
    apk)    apk add --no-cache "$@" >/dev/null 2>&1 ;;
    pacman) pacman -Sy --noconfirm --needed "$@" >/dev/null 2>&1 ;;
    zypper) zypper --non-interactive install "$@" >/dev/null 2>&1 ;;
    brew)   brew install "$@" >/dev/null 2>&1 ;;
    nix)    sb_warn "NixOS 不自动写入 environment.systemPackages，请手动进入 nix shell 提供：$*"
            return 1 ;;
  esac
}

# sb_pkg_for <命令名>  —— 返回当前发行版下提供该命令的包名
sb_pkg_for() {
  local cmd="$1" mgr
  mgr=$(sb_pkg_manager)
  case "$cmd" in
    nping)
      [ "$mgr" = apk ] && echo nmap-nping || echo nmap ;;
    ss|ip)
      case "$mgr" in dnf|yum) echo iproute ;; *) echo iproute2 ;; esac ;;
    dig)
      case "$mgr" in apt) echo dnsutils ;; apk) echo bind-tools ;; *) echo bind-utils ;; esac ;;
    traceroute) echo traceroute ;;
    iperf3)     echo iperf3 ;;
    jq)         echo jq ;;
    curl)       echo curl ;;
    bc)         echo bc ;;
    fio)        echo fio ;;
    *)          echo "$cmd" ;;
  esac
}

# sb_require <命令名> [模块名]
# 存在返回 0；不存在则尝试安装，仍失败返回 1（由调用方决定跳过哪个模块）。
sb_require() {
  local cmd="$1"
  sb_has "$cmd" && return 0
  sb_install_deps "$(sb_pkg_for "$cmd")" >/dev/null 2>&1
  sb_has "$cmd"
}

# ===================== 网络 =====================
# 统一 curl 封装：SB_CURL_ARGS 承载 --interface / -x 代理等全局参数
SB_CURL_ARGS=""

sb_curl() {
  # shellcheck disable=SC2086
  curl $SB_CURL_ARGS -sL --connect-timeout "${SB_CURL_CONNECT_TIMEOUT:-8}" \
    --max-time "${SB_CURL_MAX_TIME:-20}" -A "$SB_USER_AGENT" "$@"
}

# 随机 UA（来自 IPQuality:generate_random_user_agent）
sb_gen_user_agent() {
  local chrome=$((RANDOM % 20 + 110))
  local build=$((RANDOM % 200 + 5000))
  local patch=$((RANDOM % 200))
  SB_USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${chrome}.0.${build}.${patch} Safari/537.36"
  export SB_USER_AGENT
}

# 探测 IPv4/IPv6 连通性 -> SB_IPV4_OK / SB_IPV6_OK (0/1)
sb_detect_ip_stack() {
  SB_IPV4_OK=0
  SB_IPV6_OK=0
  local v4 v6
  v4=$(sb_curl -4 -s --max-time 6 https://api.ipify.org 2>/dev/null)
  [ -z "$v4" ] && v4=$(sb_curl -4 -s --max-time 6 https://icanhazip.com 2>/dev/null | tr -d '[:space:]')
  v6=$(sb_curl -6 -s --max-time 6 https://api6.ipify.org 2>/dev/null)
  [ -z "$v6" ] && v6=$(sb_curl -6 -s --max-time 6 https://icanhazip.com 2>/dev/null | tr -d '[:space:]')
  if [[ "$v4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    SB_IPV4_OK=1
    SB_PUBLIC_IPV4="$v4"
  fi
  if [[ "$v6" == *:* ]]; then
    SB_IPV6_OK=1
    SB_PUBLIC_IPV6="$v6"
  fi
  export SB_IPV4_OK SB_IPV6_OK SB_PUBLIC_IPV4 SB_PUBLIC_IPV6
}

# ===================== 权限分级 =====================
# SB_PRIV=root  —— 可跑全部探测（含裸 TCP SYN）
# SB_PRIV=user  —— 跳过需要 CAP_NET_RAW 的探测
sb_detect_privilege() {
  if [ "$(id -u)" -eq 0 ]; then
    SB_PRIV=root
  else
    SB_PRIV=user
  fi
  export SB_PRIV
}

# 判断是否具备裸 socket 能力（root 或已授 cap_net_raw 的 nping）
sb_has_raw_socket() {
  [ "$SB_PRIV" = root ] && return 0
  sb_has getcap && sb_has nping || return 1
  getcap "$(command -v nping)" 2>/dev/null | grep -q 'cap_net_raw'
}

# ===================== 进度 =====================
# 单行进度：sb_progress <当前> <总数> <标签>
SB_PROGRESS_ACTIVE=0

sb_progress() {
  [ -t 2 ] || return 0
  local cur="$1" total="$2" label="${3:-}" width=30 filled empty pct
  [ "$total" -le 0 ] && total=1
  pct=$((cur * 100 / total))
  [ "$pct" -gt 100 ] && pct=100
  filled=$((pct * width / 100))
  empty=$((width - filled))
  printf '\r\033[K  %s[%s%s]%s %3d%%  %s' \
    "$SB_CYAN" \
    "$(printf '%*s' "$filled" '' | tr ' ' '#')" \
    "$(printf '%*s' "$empty" '')" \
    "$SB_NC" "$pct" "$label" >&2
  SB_PROGRESS_ACTIVE=1
}

sb_progress_done() {
  [ "$SB_PROGRESS_ACTIVE" -eq 1 ] && printf '\r\033[K' >&2
  SB_PROGRESS_ACTIVE=0
  return 0
}

# 无进度值的忙碌提示（模块内部长任务用）
sb_spin_msg() {
  [ -t 2 ] || return 0
  printf '\r\033[K  %s%s%s' "$SB_DIM" "$*" "$SB_NC" >&2
}

# ===================== 计时 =====================
sb_now() { date +%s; }

sb_elapsed_text() {
  local sec="$1" min
  if [ "$sec" -ge 60 ]; then
    min=$((sec / 60))
    echo "${min} 分 $((sec % 60)) 秒"
  else
    echo "${sec} 秒"
  fi
}
