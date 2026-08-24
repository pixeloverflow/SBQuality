#!/usr/bin/env bash
#
# SBQuailty — 三合一 VPS 评测脚本
#
# 融合自：
#   - Yet-Another-Bench-Script (Mason Rowe)  系统 / 磁盘 / CPU / 国际带宽
#   - IPQuality (xykt)                       IP 质量、风控评分、流媒体解锁
#   - TcpQuality (ibsgss)                    中国三网回程、丢包、国际互联、测速
#
# 一次运行产出统一的终端报告 + JSON + HTML/Markdown，不做在线上传。
#
# 用法: bash sbquality.sh [选项]

SB_VERSION="v2026-08-23"

# 入口不启用 set -Eeuo pipefail：bench_/ipq_ 大量依赖「命令失败继续执行」。
# 严格模式只在 cn_* 的关键子流程内局部启用。
set -o pipefail 2>/dev/null || true

# ===================== 定位自身与加载模块 =====================
SB_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || printf '.')
SB_LIB_DIR="$SB_SCRIPT_DIR/lib"
SB_ASSET_DIR="$SB_SCRIPT_DIR/assets"
SB_BIN_DIR="$SB_SCRIPT_DIR/bin"
export SB_SCRIPT_DIR SB_LIB_DIR SB_ASSET_DIR SB_BIN_DIR

for _m in common bench ipinfo cnnet report; do
  if [ -r "$SB_LIB_DIR/$_m.sh" ]; then
    # shellcheck source=/dev/null
    . "$SB_LIB_DIR/$_m.sh"
  else
    echo "[X] 缺少模块 lib/$_m.sh" >&2
    exit 1
  fi
done
unset _m

# ===================== 默认配置 =====================
SB_PROFILE=quick            # quick | all
SB_DEBUG=0
SB_DRY_RUN=0
SB_LANG=cn                  # cn | en （影响 ipq_ 文案与报告标题）
SB_WANT_V4=1
SB_WANT_V6=1
SB_NO_ROOTFS=0
SB_NO_SUDO=0
SB_ASSUME_YES=0
SB_FULL_IP=0                # 报告中是否显示完整 IP（默认打码）
SB_IFACE=""                 # -i 指定的出口网卡
SB_PROXY=""                 # -x 指定的代理

SB_OUT_TXT=""
SB_OUT_JSON=""
SB_OUT_HTML=""
SB_OUT_MD=""

# 模块开关：-1 表示「未显式指定」，由档位决定
SB_MOD_SYSTEM=-1
SB_MOD_DISK=-1
SB_MOD_CPU=-1
SB_MOD_IP=-1
SB_MOD_BANDWIDTH=-1
SB_MOD_CN=-1
SB_EXPLICIT_MODULE=0

# 透传给各模块的额外参数
SB_CN_EXTRA_ARGS=()

sb_show_help() {
  cat <<EOF
${SB_BOLD}SBQuailty ${SB_VERSION}${SB_NC} — 三合一 VPS 评测（系统 / IP 质量 / 国际带宽 / 中国三网回程）

用法:
  bash sbquality.sh [选项]
  sudo bash sbquality.sh -a

档位:
  (默认)              快速档，约 8-12 分钟
                      系统信息 + fio 磁盘 + IP 质量(精简) + iperf3(3 节点) + 三网回程线路识别
  -a, --all           全量档，约 30-45 分钟
                      追加 Geekbench 6、IP 质量全量(10 库)、iperf3 全节点、
                      三网丢包/大包/教育网、国际互联、单线程测速

单模块（指定任一项后只跑被指定的模块）:
  --system            系统与硬件信息
  --disk              磁盘性能 (fio，回退 dd)
  --cpu               CPU 跑分 (Geekbench)
  --ip                IP 质量、风控评分、流媒体解锁
  --bandwidth         国际带宽 (iperf3)
  --cn                中国三网回程、丢包、国际互联、单线程测速

跳过:
  --skip-system --skip-disk --skip-cpu --skip-ip --skip-bandwidth --skip-cn

输出:
  -o <file>           纯文本报告（去除 ANSI 颜色）
  --json <file>       统一 JSON
  --html <file>       单文件 HTML 报告
  --md <file>         Markdown 报告

其它:
  -4                  仅检测 IPv4
  -6                  仅检测 IPv6
  -i <iface>          指定出口网卡（所有 HTTP 请求走该网卡）
  -x <proxy>          通过代理发起 HTTP 请求，如 socks5://127.0.0.1:1080
  --route-protocol <tcp|udp|both>
                      回程线路识别使用的探测协议，默认 tcp
                      both 会 TCP/UDP 各跑一遍：部分线路对 TCP 隐藏跳点但回应 UDP
  -E, --en            英文界面（IP 质量部分；其余段落为中文）
  -f, --full-ip       报告中显示完整 IP（默认对公网 IP 打码）
  -y, --yes           自动确认（不交互提权询问）
  --no-sudo           非 root 时不尝试提权，直接以降级模式运行
  --no-rootfs         三网探测不使用临时 Debian rootfs，直接在宿主运行
  --dry-run           不做真实探测，用假数据验证三种报告渲染
  --debug             保留临时文件并输出调试信息
  -h, --help          显示本帮助

权限说明:
  三网丢包探测需要发送裸 TCP SYN 包，必须 root。非 root 时该子项会被跳过并
  在报告中标注 SKIP，三网回程线路识别自动降级为 traceroute 模式，其余模块正常运行。
EOF
}

# ===================== 参数解析 =====================
# 手写 case 循环而非 getopts：需要长参数，且要把 -bj 式省份简写透传给 cn_ 模块。
sb_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)      sb_show_help; exit 0 ;;
      -a|--all)       SB_PROFILE=all; shift ;;
      --system)       SB_MOD_SYSTEM=1;    SB_EXPLICIT_MODULE=1; shift ;;
      --disk)         SB_MOD_DISK=1;      SB_EXPLICIT_MODULE=1; shift ;;
      --cpu)          SB_MOD_CPU=1;       SB_EXPLICIT_MODULE=1; shift ;;
      --ip)           SB_MOD_IP=1;        SB_EXPLICIT_MODULE=1; shift ;;
      --bandwidth)    SB_MOD_BANDWIDTH=1; SB_EXPLICIT_MODULE=1; shift ;;
      --cn)           SB_MOD_CN=1;        SB_EXPLICIT_MODULE=1; shift ;;
      --skip-system)    SB_MOD_SYSTEM=0; shift ;;
      --skip-disk)      SB_MOD_DISK=0; shift ;;
      --skip-cpu)       SB_MOD_CPU=0; shift ;;
      --skip-ip)        SB_MOD_IP=0; shift ;;
      --skip-bandwidth) SB_MOD_BANDWIDTH=0; shift ;;
      --skip-cn)        SB_MOD_CN=0; shift ;;
      -o)
        [ -n "${2:-}" ] || { echo "[X] -o 缺少文件名" >&2; exit 1; }
        SB_OUT_TXT="$2"; shift 2 ;;
      --json)
        [ -n "${2:-}" ] || { echo "[X] --json 缺少文件名" >&2; exit 1; }
        SB_OUT_JSON="$2"; shift 2 ;;
      --html)
        [ -n "${2:-}" ] || { echo "[X] --html 缺少文件名" >&2; exit 1; }
        SB_OUT_HTML="$2"; shift 2 ;;
      --md)
        [ -n "${2:-}" ] || { echo "[X] --md 缺少文件名" >&2; exit 1; }
        SB_OUT_MD="$2"; shift 2 ;;
      -4)             SB_WANT_V6=0; shift ;;
      -6)             SB_WANT_V4=0; shift ;;
      -i)
        [ -n "${2:-}" ] || { echo "[X] -i 缺少网卡名" >&2; exit 1; }
        SB_IFACE="$2"; SB_CURL_ARGS+=" --interface $2"; shift 2 ;;
      -x)
        [ -n "${2:-}" ] || { echo "[X] -x 缺少代理地址" >&2; exit 1; }
        SB_PROXY="$2"; SB_CURL_ARGS+=" -x $2"; shift 2 ;;
      --route-protocol)
        case "${2:-}" in
          tcp|udp|both) SB_CN_EXTRA_ARGS+=(--route-protocol "$2"); shift 2 ;;
          *) echo "[X] --route-protocol 只支持 tcp / udp / both" >&2; exit 1 ;;
        esac ;;
      -E|--en)        SB_LANG=en; shift ;;
      -f|--full-ip)   SB_FULL_IP=1; shift ;;
      -y|--yes)       SB_ASSUME_YES=1; shift ;;
      --no-sudo)      SB_NO_SUDO=1; shift ;;
      --no-rootfs)    SB_NO_ROOTFS=1; shift ;;
      --dry-run)      SB_DRY_RUN=1; shift ;;
      --debug)        SB_DEBUG=1; SB_CN_EXTRA_ARGS+=(--debug); shift ;;
      # 省份简写 (-bj/-sh/-gd...) 与 --province 透传给三网模块
      --province)
        [ -n "${2:-}" ] || { echo "[X] --province 缺少参数" >&2; exit 1; }
        SB_CN_EXTRA_ARGS+=(--province "$2"); shift 2 ;;
      -??|-???)
        SB_CN_EXTRA_ARGS+=("$1"); shift ;;
      *)
        echo "[X] 不支持的参数: $1" >&2
        echo "    使用 -h 查看帮助。" >&2
        exit 1 ;;
    esac
  done

  if [ "$SB_WANT_V4" -eq 0 ] && [ "$SB_WANT_V6" -eq 0 ]; then
    echo "[X] -4 与 -6 不能同时使用" >&2
    exit 1
  fi
}

# 根据档位与显式开关，确定每个模块最终是否运行
sb_resolve_modules() {
  local default_on
  if [ "$SB_EXPLICIT_MODULE" -eq 1 ]; then
    # 显式指定了模块：未指定的一律关闭
    default_on=0
  else
    default_on=1
  fi
  [ "$SB_MOD_SYSTEM" -eq -1 ]    && SB_MOD_SYSTEM=$default_on
  [ "$SB_MOD_DISK" -eq -1 ]      && SB_MOD_DISK=$default_on
  [ "$SB_MOD_IP" -eq -1 ]        && SB_MOD_IP=$default_on
  [ "$SB_MOD_BANDWIDTH" -eq -1 ] && SB_MOD_BANDWIDTH=$default_on
  [ "$SB_MOD_CN" -eq -1 ]        && SB_MOD_CN=$default_on
  # CPU 跑分只在全量档或显式指定时运行（Geekbench 单项就要 15+ 分钟）
  if [ "$SB_MOD_CPU" -eq -1 ]; then
    if [ "$SB_EXPLICIT_MODULE" -eq 1 ]; then
      SB_MOD_CPU=0
    elif [ "$SB_PROFILE" = all ]; then
      SB_MOD_CPU=1
    else
      SB_MOD_CPU=0
    fi
  fi
}

# ===================== 提权 =====================
sb_maybe_elevate() {
  [ "$SB_PRIV" = root ] && return 0
  [ "$SB_NO_SUDO" -eq 1 ] && return 0
  [ "$SB_MOD_CN" -eq 1 ] || return 0        # 只有三网探测需要 root
  [ "$SB_PROFILE" = all ] || [ "$SB_EXPLICIT_MODULE" -eq 1 ] || return 0
  sb_has sudo || return 0
  sb_has_raw_socket && return 0

  echo
  echo -e "  ${SB_YELLOW}三网丢包探测需要发送裸 TCP SYN 包，必须以 root 运行。${SB_NC}"
  echo -e "  ${SB_DIM}选择「否」将跳过丢包探测，回程线路识别降级为 traceroute 模式，其余模块不受影响。${SB_NC}"
  if [ "$SB_ASSUME_YES" -ne 1 ]; then
    if [ ! -t 0 ]; then
      echo -e "  ${SB_DIM}非交互环境，按降级模式继续。${SB_NC}"
      return 0
    fi
    local answer=""
    read -r -p "  使用 sudo 重新运行以获得完整结果？[y/N] " answer
    case "$answer" in
      [yY]|[yY][eE][sS]) ;;
      *) echo -e "  ${SB_DIM}继续以降级模式运行。${SB_NC}"; return 0 ;;
    esac
  fi
  echo -e "  ${SB_DIM}正在通过 sudo 重新运行...${SB_NC}"
  exec sudo -E bash "$SB_SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")" "${SB_ORIGINAL_ARGS[@]}"
}

# ===================== 临时 rootfs =====================
# root + 需要三网探测时，默认进入一次性 Debian rootfs 运行：
# nping/traceroute/iperf3/bpftrace 等依赖装在 rootfs 里，不污染宿主包环境。
# guest 与宿主共享网络命名空间，所以测出来的仍是这台机器的网络。
sb_should_use_rootfs() {
  [ "${SBQUALITY_INSIDE_ROOTFS:-0}" -eq 1 ] && return 1   # 已在 rootfs 内
  [ "$SB_NO_ROOTFS" -eq 1 ] && return 1
  [ "$SB_DRY_RUN" -eq 1 ] && return 1
  [ "$SB_PRIV" = root ] || return 1
  [ "$SB_MOD_CN" -eq 1 ] || return 1
  [ "$(uname -s)" = Linux ] || return 1
  [ -r "$SB_ASSET_DIR/rootfs.sh" ] || return 1
  return 0
}

# 把用户指定的输出路径改写成 guest 内的固定文件名，跑完再搬回宿主原路径
sb_run_in_rootfs() {
  local out_dir rc i arg
  out_dir=$(mktemp -d "${TMPDIR:-/tmp}/sbquality-out.XXXXXX") || {
    sb_warn "无法创建输出目录，改为直接在宿主运行"
    return 1
  }

  local -a guest_args=()
  i=0
  while [ "$i" -lt "${#SB_ORIGINAL_ARGS[@]}" ]; do
    arg="${SB_ORIGINAL_ARGS[i]}"
    case "$arg" in
      -o)      guest_args+=(-o /tmp/sbquality-report.txt);      i=$((i + 2)); continue ;;
      --json)  guest_args+=(--json /tmp/sbquality-report.json);  i=$((i + 2)); continue ;;
      --html)  guest_args+=(--html /tmp/sbquality-report.html);  i=$((i + 2)); continue ;;
      --md)    guest_args+=(--md /tmp/sbquality-report.md);      i=$((i + 2)); continue ;;
      *)       guest_args+=("$arg") ;;
    esac
    i=$((i + 1))
  done

  echo -e "  ${SB_DIM}正在准备临时 Debian rootfs（依赖装在 rootfs 内，不改动宿主）...${SB_NC}"
  echo -e "  ${SB_DIM}如需直接在宿主运行，请加 --no-rootfs${SB_NC}"
  echo

  local -a rootfs_args=(--source-dir "$SB_SCRIPT_DIR" --output "$out_dir")
  [ "$SB_DEBUG" -eq 1 ] && rootfs_args+=(--debug)

  bash "$SB_ASSET_DIR/rootfs.sh" "${rootfs_args[@]}" -- "${guest_args[@]}"
  rc=$?

  # 把 guest 产出的报告搬到用户指定的路径
  local pair src dst
  for pair in "txt:$SB_OUT_TXT" "json:$SB_OUT_JSON" "html:$SB_OUT_HTML" "md:$SB_OUT_MD"; do
    dst="${pair#*:}"
    [ -n "$dst" ] || continue
    src="$out_dir/sbquality-report.${pair%%:*}"
    if [ -f "$src" ]; then
      mv -- "$src" "$dst" && sb_ok "报告已写入 $dst"
    else
      sb_warn "rootfs 内未生成 ${pair%%:*} 报告"
    fi
  done
  rm -rf -- "$out_dir"
  exit "$rc"
}

# ===================== 页首 =====================
sb_print_banner() {
  echo
  echo -e "${SB_CYAN}  ┌────────────────────────────────────────────────────────┐${SB_NC}"
  echo -e "${SB_CYAN}  │${SB_NC}  ${SB_BOLD}SBQuailty${SB_NC}  综合网络与性能评测              ${SB_DIM}${SB_VERSION}${SB_NC}  ${SB_CYAN}│${SB_NC}"
  echo -e "${SB_CYAN}  │${SB_NC}  ${SB_DIM}YABS + IPQuality + TcpQuality 融合${SB_NC}                    ${SB_CYAN}│${SB_NC}"
  echo -e "${SB_CYAN}  └────────────────────────────────────────────────────────┘${SB_NC}"
  echo
  echo -e "  ${SB_DIM}开始时间：$(date '+%Y-%m-%d %H:%M:%S %Z')${SB_NC}"
  local profile_text="快速档"
  [ "$SB_PROFILE" = all ] && profile_text="全量档"
  [ "$SB_EXPLICIT_MODULE" -eq 1 ] && profile_text="自定义"
  echo -e "  ${SB_DIM}运行档位：${profile_text}    权限：${SB_PRIV}${SB_NC}"
  echo
}

# 列出本次将要运行的模块
sb_print_plan() {
  local -a on=()
  [ "$SB_MOD_SYSTEM" -eq 1 ]    && on+=("系统信息")
  [ "$SB_MOD_DISK" -eq 1 ]      && on+=("磁盘性能")
  [ "$SB_MOD_CPU" -eq 1 ]       && on+=("CPU 跑分")
  [ "$SB_MOD_IP" -eq 1 ]        && on+=("IP 质量")
  [ "$SB_MOD_BANDWIDTH" -eq 1 ] && on+=("国际带宽")
  [ "$SB_MOD_CN" -eq 1 ]        && on+=("三网回程")
  if [ "${#on[@]}" -eq 0 ]; then
    sb_err "没有可执行的测试项"
    exit 1
  fi
  local joined="" item
  for item in "${on[@]}"; do
    joined+="${joined:+  ·  }${item}"
  done
  echo -e "  ${SB_DIM}测试项目：${joined}${SB_NC}"
  echo
}

# ===================== 主流程 =====================
sb_main() {
  SB_ORIGINAL_ARGS=("$@")
  sb_parse_args "$@"
  sb_resolve_modules

  sb_init_rundir
  trap 'sb_cleanup_rundir' EXIT
  trap 'echo; sb_warn "已中断，正在清理..."; sb_cleanup_rundir; exit 130' INT TERM

  sb_gen_user_agent
  sb_detect_privilege
  sb_maybe_elevate

  # 满足条件时整个评测转入临时 rootfs 运行，本进程只负责搬运报告
  if sb_should_use_rootfs; then
    sb_run_in_rootfs
  fi

  local start_time
  start_time=$(sb_now)

  sb_print_banner
  sb_print_plan

  # 记录运行元信息
  sb_kv_set meta.version "$SB_VERSION"
  sb_kv_set meta.time "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  sb_kv_set meta.time_iso "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  sb_kv_set meta.profile "$SB_PROFILE"
  sb_kv_set meta.privilege "$SB_PRIV"

  if [ "$SB_DRY_RUN" -eq 1 ]; then
    sb_info "dry-run 模式：填充示例数据，不执行真实探测"
    report_fill_dry_run
  else
    sb_detect_ip_stack
    [ "$SB_WANT_V4" -eq 0 ] && SB_IPV4_OK=0
    [ "$SB_WANT_V6" -eq 0 ] && SB_IPV6_OK=0
    if [ "$SB_IPV4_OK" -eq 0 ] && [ "$SB_IPV6_OK" -eq 0 ]; then
      sb_warn "未检测到可用的 IPv4/IPv6 连通性，联网测试项将全部跳过"
    fi
    sb_kv_set meta.ipv4_online "$SB_IPV4_OK"
    sb_kv_set meta.ipv6_online "$SB_IPV6_OK"

    [ "$SB_MOD_SYSTEM" -eq 1 ]    && bench_run_system
    [ "$SB_MOD_DISK" -eq 1 ]      && bench_run_disk
    [ "$SB_MOD_CPU" -eq 1 ]       && bench_run_cpu
    [ "$SB_MOD_IP" -eq 1 ]        && ipq_run
    [ "$SB_MOD_BANDWIDTH" -eq 1 ] && bench_run_iperf
    [ "$SB_MOD_CN" -eq 1 ]        && cn_run
  fi

  local end_time elapsed
  end_time=$(sb_now)
  elapsed=$((end_time - start_time))
  sb_kv_set meta.elapsed "$elapsed"

  # ---- 报告输出 ----
  report_render_tui
  [ -n "$SB_OUT_TXT" ]  && report_write_text "$SB_OUT_TXT"
  [ -n "$SB_OUT_JSON" ] && report_write_json "$SB_OUT_JSON"
  [ -n "$SB_OUT_HTML" ] && report_write_html "$SB_OUT_HTML"
  [ -n "$SB_OUT_MD" ]   && report_write_md "$SB_OUT_MD"

  echo
  echo -e "  ${SB_DIM}总耗时：$(sb_elapsed_text "$elapsed")${SB_NC}"
  echo
  return 0
}

sb_main "$@"
