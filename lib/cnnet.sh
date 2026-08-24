#!/usr/bin/env bash
#
# SBQuailty - lib/cnnet.sh
# 中国三网：回程线路识别、nping 丢包探测、国际互联、单线程测速
#
# 移植自 TcpQuality (ibsgss)。移植范围说明：
#
#   逐字搬运（保持原有判定精度）:
#     - route_label_from_ip_trace  三网回程线路识别的 awk 判定（ASN/前缀规则）
#     - education_route_label_from_ip_trace  教育网专用判定（HKIX/国际中转回溯）
#     - extract_trace_ips / route_needs_10099_hidden_tcp_retry
#     - query_cymru_asn / build_asn_map   Team Cymru 批量 ASN 查询
#     - probe_target / test_one / combine_probe_results   nping 丢包与延迟
#     - get_ipv6_route                    IPv6 二层发包回退所需的路由/MAC 解析
#     - international_latency_test_one    iPerf3 双向 RTT/重传（端口轮换与备用节点）
#     - speedtest_run_probe               TOS 固定 IP 单线程测速 + 连接级重传
#     - speedtest_retrans_trace_*         bpftrace 重传去重
#
#   与原版的差别:
#     - 站点/CDN 国际互联每个域名取首个公网 IP（原版最多探测 2 个再合并）
#     - 未移植北京三段限速测速（会改宿主 qdisc/ifb）
#
#   已删除（按「不做在线上传」的设计决定）:
#     - upload_report / rank session / 各类 debug bundle 上传
#
# 全局变量前缀 CN_，函数前缀 cn_。

CN_GET_NODES_URL="${SBQUALITY_GET_NODES_URL:-https://tcpquality.ibsgss.uk/getNodes}"
CN_ROUTE_ASN_API="${SBQUALITY_ROUTE_ASN_API:-https://tcpquality.ibsgss.uk/route/asn?format=tsv}"

CN_PACKETS="${SBQUALITY_PACKETS:-50}"       # 每节点发包数
CN_PARALLEL=8                                # 并行节点数，按内存自动调整
CN_ROUTE_PROTOCOL=tcp
CN_APPLE_DOWNLOAD_URL="https://mensura.cdn-apple.com/api/v1/gm/large"

# 无负载 SYN 的 IP 包总长（40 = IPv4 头 20 + TCP 头 20；IPv6 为 60）
CN_PACKET_SIZES=(0)

# IPv4 大包回程：混合大小包发送，用来暴露只对大包生效的 QoS/限速策略。
# 大包占 3/4，小包占 1/4（与 TcpQuality 一致）。
CN_LARGE_BIG_SIZES=(900 950 1000 1050 1100 1150 1200 1200 900)
CN_LARGE_SMALL_SIZES=(120 240 480)
CN_LARGE_PRECHECK_DOMAIN="www.cloudflare.com"
CN_LARGE_PRECHECK_PACKETS=20
CN_LARGE_PRECHECK_SIZE=1200
CN_LARGE_FIREWALL_LIMITED=0
CN_LARGE_PRECHECK_LOSS=""

# 单次探测的运行时开关，由 cn_test_one / cn_test_large_one 设置
CN_LARGE_MODE=0
CN_PACKET_SIZE_OVERRIDE=""
CN_IPV6_FORCE_L2=0

CN_RESULT_DIR=""

# ===================== 初始化与依赖 =====================
cn_init() {
  CN_RESULT_DIR="$SB_TMP_DIR/cnnet"
  mkdir -p "$CN_RESULT_DIR"
  cn_auto_parallel
}

# 并行数按可用内存推算：每个 nping/traceroute 子进程约占 30MB
cn_auto_parallel() {
  local mem_mb=0
  if [ -r /proc/meminfo ]; then
    mem_mb=$(awk '/^MemTotal:/ {print int($2 / 1024); exit}' /proc/meminfo 2>/dev/null)
  fi
  if   [ "$mem_mb" -ge 4096 ]; then CN_PARALLEL=16
  elif [ "$mem_mb" -ge 2048 ]; then CN_PARALLEL=12
  elif [ "$mem_mb" -ge 1024 ]; then CN_PARALLEL=8
  elif [ "$mem_mb" -ge 512 ];  then CN_PARALLEL=4
  else                              CN_PARALLEL=2
  fi
}

# ===================== 节点获取 =====================
# 节点域名、真实 IP 与端口全部由 getNodes 提供，脚本内不内置节点。
CN_CDN4_NODES=() CN_CDN6_NODES=() CN_CERNET_NODES=() CN_CERNET2_NODES=()
CN_NODES_LOADED=0
CN_NODES_ERROR=""

cn_load_nodes() {
  local scope="${1:-all}" tmp url sep line
  local type family prov isp host ip port target backup_host backup_ip backup_port backup_target
  [ "$CN_NODES_LOADED" -eq 1 ] && return 0
  sb_has curl || { CN_NODES_ERROR="缺少 curl"; return 1; }

  tmp=$(mktemp)
  sep="?"
  [[ "$CN_GET_NODES_URL" == *"?"* ]] && sep="&"
  url="${CN_GET_NODES_URL}${sep}format=tsv&scope=${scope}"
  # 优先走 IPv4；失败再让 curl 自选协议
  if ! curl -4 -fsSL --connect-timeout 5 --max-time 30 "$url" > "$tmp" 2>/dev/null; then
    if ! curl -fsSL --connect-timeout 5 --max-time 30 "$url" > "$tmp" 2>/dev/null; then
      CN_NODES_ERROR="无法从 getNodes 获取节点列表（$url）"
      rm -f "$tmp"
      return 1
    fi
  fi

  CN_CDN4_NODES=() CN_CDN6_NODES=() CN_CERNET_NODES=() CN_CERNET2_NODES=()
  while IFS= read -r line; do
    line=${line//$'\t'/'|'}
    IFS='|' read -r type family prov isp host ip port target backup_host backup_ip backup_port backup_target <<< "$line"
    [ "$type" = "type" ] && continue
    [ -n "$ip" ] || continue
    port=${port:-80}
    case "$type:$family" in
      cdn:4)     CN_CDN4_NODES+=("$prov|$isp|$host|$ip|$port|$backup_host|$backup_ip|${backup_port:-80}") ;;
      cdn:6)     CN_CDN6_NODES+=("$prov|$isp|$host|$ip|$port|$backup_host|$backup_ip|${backup_port:-80}") ;;
      cernet:4)  CN_CERNET_NODES+=("$prov|教育网|$host|$ip|$port|$backup_host|$backup_ip|${backup_port:-443}") ;;
      cernet2:6) CN_CERNET2_NODES+=("$prov|教育网|$host|$ip|$port|$backup_host|$backup_ip|${backup_port:-443}") ;;
    esac
  done < "$tmp"
  rm -f "$tmp"

  if [ "${#CN_CDN4_NODES[@]}" -gt 0 ] || [ "${#CN_CDN6_NODES[@]}" -gt 0 ] ||
     [ "${#CN_CERNET_NODES[@]}" -gt 0 ] || [ "${#CN_CERNET2_NODES[@]}" -gt 0 ]; then
    CN_NODES_LOADED=1
    return 0
  fi
  CN_NODES_ERROR="getNodes 返回内容为空"
  return 1
}

# cn_print_nodes <cdn4|cdn6|cernet|cernet2>
cn_print_nodes() {
  local -n arr="CN_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')_NODES"
  [ "${#arr[@]}" -eq 0 ] && return 0
  printf '%s\n' "${arr[@]}"
}

cn_node_count() {
  local -n arr="CN_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')_NODES"
  echo "${#arr[@]}"
}

# ===================== 省份筛选 =====================
CN_SELECTED_PROVINCES=""

cn_province_from_code() {
  local code
  code=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  code=${code#-}
  case "$code" in
    he|河北) echo "河北" ;;   sx|山西) echo "山西" ;;
    ln|辽宁) echo "辽宁" ;;   jl|吉林) echo "吉林" ;;
    hl|黑龙江) echo "黑龙江" ;; js|江苏) echo "江苏" ;;
    zj|浙江) echo "浙江" ;;   ah|安徽) echo "安徽" ;;
    fj|福建) echo "福建" ;;   jx|江西) echo "江西" ;;
    sd|山东) echo "山东" ;;   ha|河南) echo "河南" ;;
    hb|湖北) echo "湖北" ;;   hn|湖南) echo "湖南" ;;
    gd|广东) echo "广东" ;;   gx|广西) echo "广西" ;;
    hi|海南) echo "海南" ;;   sc|四川) echo "四川" ;;
    gz|贵州) echo "贵州" ;;   yn|云南) echo "云南" ;;
    sn|陕西) echo "陕西" ;;   gs|甘肃) echo "甘肃" ;;
    qh|青海) echo "青海" ;;   nx|宁夏) echo "宁夏" ;;
    xj|新疆) echo "新疆" ;;   xz|西藏) echo "西藏" ;;
    nm|内蒙古) echo "内蒙古" ;; bj|北京) echo "北京" ;;
    tj|天津) echo "天津" ;;   sh|上海) echo "上海" ;;
    cq|重庆) echo "重庆" ;;
    *) return 1 ;;
  esac
}

cn_add_province_filter() {
  local prov
  prov=$(cn_province_from_code "$1") || return 1
  case "|$CN_SELECTED_PROVINCES|" in
    *"|$prov|"*) ;;
    *) CN_SELECTED_PROVINCES="${CN_SELECTED_PROVINCES:+$CN_SELECTED_PROVINCES|}$prov" ;;
  esac
  return 0
}

cn_province_selected() {
  [ -z "$CN_SELECTED_PROVINCES" ] && return 0
  case "|$CN_SELECTED_PROVINCES|" in
    *"|$1|"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ===================== IP 工具 =====================
cn_is_public_ipv4() {
  awk -F. -v ip="$1" 'BEGIN {
    if (split(ip, a, ".") != 4) exit 1
    for (i = 1; i <= 4; i++) if (a[i] !~ /^[0-9]+$/ || a[i] < 0 || a[i] > 255) exit 1
    if (a[1] == 0 || a[1] == 10 || a[1] == 127 || a[1] >= 224) exit 1
    if (a[1] == 100 && a[2] >= 64 && a[2] <= 127) exit 1
    if (a[1] == 169 && a[2] == 254) exit 1
    if (a[1] == 172 && a[2] >= 16 && a[2] <= 31) exit 1
    if (a[1] == 192 && a[2] == 168) exit 1
    if (a[1] == 198 && (a[2] == 18 || a[2] == 19)) exit 1
    exit 0
  }'
}

# IPv6 二层发包所需的接口/源地址/MAC —— 逐字移植自 TcpQuality:get_ipv6_route
# 部分云厂商的 IPv6 需要显式二层发包，nping 才能收到 SYN-ACK。
cn_get_ipv6_route() {
  local target="$1" route_info iface source_ip next_hop source_mac dest_mac

  if sb_has ip; then
    route_info=$(ip -6 route get "$target" 2>/dev/null | head -1)
    iface=$(printf '%s\n' "$route_info" | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
    source_ip=$(printf '%s\n' "$route_info" | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
    next_hop=$(printf '%s\n' "$route_info" | awk '{for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')
    if [ -n "$iface" ] && [ -z "$source_ip" ]; then
      source_ip=$(ip -6 addr show dev "$iface" scope global 2>/dev/null | awk '/inet6 / {sub(/\/.*/,"",$2); print $2; exit}')
    fi
    next_hop=${next_hop:-$target}
    source_mac=$(ip link show dev "$iface" 2>/dev/null | awk '/link\/ether/ {print $2; exit}')
    dest_mac=$(ip -6 neigh show "$next_hop" dev "$iface" 2>/dev/null | awk '/lladdr/ {for (i=1;i<=NF;i++) if ($i=="lladdr") {print $(i+1); exit}}')
    if [ -z "$dest_mac" ] && sb_has ping; then
      ping -6 -c 1 -W 1 -I "$iface" "$next_hop" >/dev/null 2>&1 || true
      dest_mac=$(ip -6 neigh show "$next_hop" dev "$iface" 2>/dev/null | awk '/lladdr/ {for (i=1;i<=NF;i++) if ($i=="lladdr") {print $(i+1); exit}}')
    fi
  fi

  source_ip=${source_ip%%\%*}
  case "$source_ip" in
    [23]*:*)
      if [ -n "$iface" ] &&
         [[ "$source_mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] &&
         [[ "$dest_mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
        printf '%s|%s|%s|%s\n' "$iface" "$source_ip" "$source_mac" "$dest_mac"
        return 0
      fi ;;
  esac
  return 1
}

# ===================== traceroute 与 ASN =====================
# 以下三个 awk 程序逐字移植自 TcpQuality，内含三网回程识别的全部领域规则，
# 修改需同步上游，不要「顺手简化」。

cn_extract_trace_ips() {
  awk '
    function public_v4(ip, parts, k) {
      if (split(ip, parts, ".") != 4) return 0
      for (k = 1; k <= 4; k++) if (parts[k] !~ /^[0-9]+$/ || parts[k] < 0 || parts[k] > 255) return 0
      if (parts[1] == 0 || parts[1] == 10 || parts[1] == 127 || parts[1] >= 224) return 0
      if (parts[1] == 100 && parts[2] >= 64 && parts[2] <= 127) return 0
      if (parts[1] == 169 && parts[2] == 254) return 0
      if (parts[1] == 172 && parts[2] >= 16 && parts[2] <= 31) return 0
      if (parts[1] == 192 && parts[2] == 168) return 0
      if (parts[1] == 198 && (parts[2] == 18 || parts[2] == 19)) return 0
      return 1
    }
    function public_v6(ip) {
      if (ip !~ /:/ || ip !~ /^[0-9A-Fa-f:]+$/) return 0
      if (ip ~ /^::1$/ || ip ~ /^fe80:/ || ip ~ /^fc/ || ip ~ /^fd/) return 0
      return 1
    }
    /bad integer value|unknown arguments/ { in_usage = 1; next }
    /^usage:/ { in_usage = 1; next }
    in_usage { next }
    /^#/ || /^target[[:space:]]/ || /^traceroute[[:space:]]/ || / -> .*hops max/ || /^NextTrace[[:space:]]/ || /^IP Geo Data Provider:/ { next }
    {
      for (i = 1; i <= NF; i++) {
        field = $i
        gsub(/[^0-9A-Fa-f:.%]/, " ", field)
        count = split(field, tokens, /[[:space:]]+/)
        for (j = 1; j <= count; j++) {
          token = tokens[j]
          sub(/%.*/, "", token)
          gsub(/^:+|:+$/, "", token)
          if (public_v4(token)) print token
          else if (public_v6(token)) print token
        }
      }
    }
  ' "$1"
}

# 10099（联通 A网）之后国内段被隐藏时，TCP traceroute 需要重试一次
cn_route_needs_10099_retry() {
  awk '
    function public_v4(ip, parts, k) {
      if (split(ip, parts, ".") != 4) return 0
      for (k = 1; k <= 4; k++) if (parts[k] !~ /^[0-9]+$/ || parts[k] < 0 || parts[k] > 255) return 0
      if (parts[1] == 0 || parts[1] == 10 || parts[1] == 127 || parts[1] >= 224) return 0
      if (parts[1] == 100 && parts[2] >= 64 && parts[2] <= 127) return 0
      if (parts[1] == 169 && parts[2] == 254) return 0
      if (parts[1] == 172 && parts[2] >= 16 && parts[2] <= 31) return 0
      if (parts[1] == 192 && parts[2] == 168) return 0
      if (parts[1] == 198 && (parts[2] == 18 || parts[2] == 19)) return 0
      return 1
    }
    function is_10099(ip) {
      return ip ~ /^103\.214\./ || ip ~ /^103\.228\.68\./ || ip ~ /^103\.239\.176\./ || ip ~ /^118\.26\.151\./ || ip ~ /^162\.219\.(3[2-9]|85)\./ || ip ~ /^162\.245\.124\./ || ip ~ /^202\.77\.23\./ || ip ~ /^203\.160\.(66|75)\./
    }
    function is_4837(ip) { return ip ~ /^219\.158\./ }
    function is_9929(ip) { return ip ~ /^210\.14\./ || ip ~ /^210\.51\./ || ip ~ /^210\.78\./ || ip ~ /^218\.105\./ }
    function is_163(ip)  { return ip ~ /^202\.97\./ || ip ~ /^202\.96\./ || ip ~ /^219\.141\./ || ip ~ /^219\.142\./ || ip ~ /^106\.37\./ }
    /^#/ || /^target[[:space:]]/ || /^traceroute[[:space:]]/ { next }
    {
      line = $0
      has_ip = 0
      while (match(line, /[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*/)) {
        ip = substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
        if (!public_v4(ip)) continue
        has_ip = 1
        if (is_10099(ip)) { seen_10099 = 1; after_10099 = 1; continue }
        if (!after_10099) continue
        if (is_4837(ip) || is_9929(ip)) seen_unicom_domestic = 1
        if (is_163(ip)) seen_163 = 1
      }
      if (after_10099 && !seen_163 && !has_ip && $0 ~ /\*/) hidden_after_10099++
    }
    END { exit !(seen_10099 && seen_163 && !seen_unicom_domestic && hidden_after_10099 >= 2) }
  ' "$1"
}

# Team Cymru whois 批量查询：一次连接查完全部跳点 IP，避免逐个 whois
cn_query_cymru_asn() {
  local ip_file="$1" out_file="$2" req_file
  req_file=$(mktemp)
  {
    echo "begin"
    echo "verbose"
    sort -u "$ip_file"
    echo "end"
  } > "$req_file"
  if sb_has timeout; then
    timeout 35 bash -c 'exec 3<>/dev/tcp/whois.cymru.com/43; cat "$1" >&3; cat <&3' _ "$req_file" > "$out_file" 2>/dev/null || true
  else
    bash -c 'exec 3<>/dev/tcp/whois.cymru.com/43; cat "$1" >&3; cat <&3' _ "$req_file" > "$out_file" 2>/dev/null || true
  fi
  rm -f "$req_file"
}

cn_build_asn_map() {
  awk -F'|' '
    NR == 1 { next }
    {
      asn = $1; ip = $2; owner = $7
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", asn)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", ip)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", owner)
      count = split(asn, values, /[[:space:]]+/)
      asn = values[count]
      if (asn ~ /^[0-9]+$/ && ip ~ /^[0-9A-Fa-f:.]+$/) print tolower(ip) "|" asn "|" owner
    }
  ' "$1" > "$2"
}

# 用 TcpQuality 的 ASN 接口补齐 Cymru 查不到的跳点（可选，失败不影响主流程）
cn_append_server_asn_meta() {
  local ip_file="$1" map_file="$2" response_file
  [ -s "$ip_file" ] || return 0
  response_file=$(mktemp)
  if curl -4 -fsSL --connect-timeout 5 --max-time 20 \
      -X POST -H 'content-type: text/plain; charset=utf-8' \
      --data-binary "@$ip_file" "$CN_ROUTE_ASN_API" > "$response_file" 2>/dev/null; then
    awk -F'\t' '
      NR == 1 { next }
      {
        ip = tolower($1); asn = $2; owner = $3
        sub(/^[Aa][Ss]/, "", asn)
        gsub(/[|\r\n]+/, " ", owner)
        if (ip ~ /^[0-9A-Fa-f:.]+$/ && asn ~ /^[0-9]+$/) print ip "|" asn "|" owner
      }
    ' "$response_file" >> "$map_file"
  fi
  rm -f "$response_file"
}

# ===================== 回程线路识别（核心判定） =====================
# 逐字移植自 TcpQuality:route_label_from_ip_trace。
# 输入：traceroute 原始输出、IP→ASN 映射表、跳点 IP 列表、目标运营商
# 输出：线路标签（CN2GIA / CN2GT / CTGGIA / 163 / 4837 / 9929 / 10099 / CMI /
#       CMIN2 / CERNET / CERNET2 / CSTNET / Hidden）
cn_route_label_from_ip_trace() {
  local trace_file="$1" asn_map_file="$2" trace_ip_file="$3" target_isp="${4:-}"
  awk -F'|' -v target_isp="$target_isp" '
    function infer_asn_from_ip(ip) {
      if (ip ~ /^59\.43\./) return "4809"
      if (ip ~ /^203\.22\.182\./ || ip ~ /^203\.22\.178\./ || ip ~ /^203\.22\.179\./ || ip ~ /^203\.128\.224\./ || ip ~ /^69\.194\./) return "23764"
      if (ip ~ /^2400:9380:/) return "23764"
      if (ip ~ /^202\.97\./ || ip ~ /^202\.96\./ || ip ~ /^219\.141\./ || ip ~ /^219\.142\./ || ip ~ /^106\.37\./) return "4134"
      if (ip ~ /^240e:/) return "4134"
      if (ip ~ /^219\.158\./) return "4837"
      if (ip ~ /^2408:/) return "4837"
      if (ip ~ /^223\.120\./ || ip ~ /^223\.119\./) return "58453"
      if (ip ~ /^221\.183\./ || ip ~ /^111\.24\./ || ip ~ /^111\.13\./) return "9808"
      if (ip ~ /^2402:4f00:f000:/) return "58807"
      if (ip ~ /^2409:8080:/) return "9808"
      if (ip ~ /^103\.214\./ || ip ~ /^103\.228\.68\./ || ip ~ /^103\.239\.176\./ || ip ~ /^118\.26\.151\./ || ip ~ /^162\.219\.(3[2-9]|85)\./ || ip ~ /^162\.245\.124\./ || ip ~ /^202\.77\.23\./ || ip ~ /^203\.160\.(66|75)\./) return "10099"
      if (ip ~ /^2401:8a00:/) return "10099"
      if (ip ~ /^210\.14\./ || ip ~ /^210\.51\./ || ip ~ /^210\.78\./ || ip ~ /^218\.105\./) return "9929"
      if (ip ~ /^59\.64\./ || ip ~ /^101\.4\./ || ip ~ /^101\.76\./ || ip ~ /^111\.114\./ || ip ~ /^113\.54\./ || ip ~ /^115\.24\./ || ip ~ /^115\.156\./ || ip ~ /^183\.172\./ || ip ~ /^202\.38\.19/ || ip ~ /^202\.112\./ || ip ~ /^202\.113\./ || ip ~ /^202\.114\./ || ip ~ /^202\.115\./ || ip ~ /^202\.116\./ || ip ~ /^202\.117\./ || ip ~ /^202\.118\./ || ip ~ /^202\.119\./ || ip ~ /^202\.120\./ || ip ~ /^202\.194\./ || ip ~ /^202\.196\./ || ip ~ /^202\.197\./ || ip ~ /^202\.198\./ || ip ~ /^202\.200\./ || ip ~ /^202\.201\./ || ip ~ /^202\.202\./ || ip ~ /^202\.207\./ || ip ~ /^210\.2[6-9]\./ || ip ~ /^210\.3[0-9]\./ || ip ~ /^210\.4[0-7]\./ || ip ~ /^219\.22[4-9]\./ || ip ~ /^222\.(1[6-9]|2[0-3])\./ || ip ~ /^222\.19[2-9]\./ || ip ~ /^222\.20[0-7]\./) return "4538"
      if (ip ~ /^2001:252:/) return "23911"
      if (ip ~ /^2001:da8:/ || ip ~ /^2001:250:/ || ip ~ /^2402:f000:/) return "23910"
      if (ip ~ /^159\.226\./) return "7497"
      return ""
    }
    function has_asn(v) { return index(all_asn, "AS" v " ") > 0 }
    function add_asn(asn) {
      if (asn != "" && index(all_asn, "AS" asn " ") == 0) all_asn = all_asn "AS" asn " "
    }
    function is_ctgnet_ip(ip) {
      return ip ~ /^203\.22\.182\./ || ip ~ /^203\.22\.178\./ || ip ~ /^203\.22\.179\./ || ip ~ /^203\.128\.224\./ || ip ~ /^69\.194\./ || ip ~ /^2400:9380:/
    }
    function is_ctgnet_transit_ip(ip) { return is_ctgnet_ip(ip) }
    function is_163_ip(ip) {
      return ip ~ /^202\.97\./ || ip ~ /^202\.96\./ || ip ~ /^219\.141\./ || ip ~ /^219\.142\./ || ip ~ /^106\.37\./ || ip ~ /^240e:/
    }
    function is_telecom_access_asn(asn) {
      return asn == "4134" || asn == "4811" || asn == "4812" || asn == "4847" || asn == "23724" || asn == "134756" || asn == "133776" || asn == "139201" || asn == "139203" || asn == "148969" || asn == "38283" || asn == "58540" || asn == "58563"
    }
    function is_telecom_access_ip(ip) {
      return ip ~ /^1\.202\./ || ip ~ /^27\.129\./ || ip ~ /^36\.110\./ || ip ~ /^36\.112\./ || ip ~ /^58\.213\./ || ip ~ /^101\.95\./ || ip ~ /^101\.226\./ || ip ~ /^106\.227\./ || ip ~ /^111\.74\./ || ip ~ /^117\.21\./ || ip ~ /^117\.68\./ || ip ~ /^124\.127\./ || ip ~ /^140\.249\./ || ip ~ /^180\.102\./ || ip ~ /^183\.47\./ || ip ~ /^219\.148\./ || ip ~ /^220\.181\./
    }
    function is_mobile_access_asn(asn) { return asn == "24547" || asn == "132510" }
    function is_mobile_access_ip(ip) { return ip ~ /^111\.63\./ || ip ~ /^183\.201\./ || ip ~ /^183\.203\./ }
    function is_cmin2_asn(asn) { return asn == "58807" }
    function is_cmi_asn(asn) { return asn == "58453" || asn == "9808" || asn ~ /^5604[0-8]$/ }
    function compact_combo_label(label,   parts, n) {
      n = split(label, parts, "->")
      if (n > 2) return parts[1] "->" parts[n]
      return label
    }
    function mobile_label_before(last,   h, has_cmin2, has_cmi) {
      if (last <= 1) return ""
      for (h = 1; h < last; h++) {
        if (is_cmin2_asn(asns[h])) has_cmin2 = 1
        if (is_cmi_asn(asns[h]) || (target_isp == "移动" && (is_mobile_access_asn(asns[h]) || is_mobile_access_ip(ips[h])))) has_cmi = 1
      }
      if (has_cmin2 && has_cmi) return "CMIN2->CMI"
      if (has_cmin2) return "CMIN2"
      if (has_cmi) return "CMI"
      return ""
    }
    function is_oversea_cn2_ip(ip) { return ip ~ /^2605:9d80:/ }
    function is_unicom_backbone_ip(ip) {
      return ip ~ /^210\.14\./ || ip ~ /^210\.51\./ || ip ~ /^210\.78\./ || ip ~ /^218\.105\./ || ip ~ /^219\.158\./ || ip ~ /^2408:/
    }
    function is_unicom_backbone_asn(asn) { return asn == "9929" || asn == "4837" || asn == "4808" }
    function is_unicom_access_asn(asn) {
      return asn == "17816" || asn == "135061" || asn == "136958" || asn == "140979"
    }
    function is_unicom_route_hop(h) {
      return is_unicom_backbone_asn(asns[h]) || is_unicom_backbone_ip(ips[h]) || is_unicom_access_asn(asns[h])
    }
    function is_10099_entry_ip(ip) {
      return ip ~ /^103\.214\./ || ip ~ /^103\.228\.68\./ || ip ~ /^103\.239\.176\./ || ip ~ /^118\.26\.151\./ || ip ~ /^162\.219\.(3[2-9]|85)\./ || ip ~ /^162\.245\.124\./ || ip ~ /^202\.77\.23\./ || ip ~ /^203\.160\.(66|75)\./ || ip ~ /^2401:8a00:/
    }
    # ASN 查询结果是权威判断；前缀只在 ASN 缺失时作为兜底。
    function is_10099_hop(asn, ip) { return asn == "10099" || (asn == "" && is_10099_entry_ip(ip)) }
    function has_163_before(last,   h) {
      if (last <= 1) return 0
      for (h = 1; h < last; h++) {
        if (asns[h] == "4134" || asns[h] == "4847" || is_163_ip(ips[h])) return 1
      }
      return 0
    }
    function unicom_domestic_label_from_hop(first,   h, has_4837) {
      for (h = first + 1; h <= max_hop; h++) {
        if (asns[h] == "9929" || ips[h] ~ /^210\.14\./ || ips[h] ~ /^210\.51\./ || ips[h] ~ /^210\.78\./ || ips[h] ~ /^218\.105\./) return "9929"
        if (asns[h] == "4837" || asns[h] == "4808" || is_unicom_access_asn(asns[h]) || ips[h] ~ /^219\.158\./ || ips[h] ~ /^2408:/) has_4837 = 1
      }
      if (has_4837) return "4837"
      return ""
    }
    function unicom_route_combo_label(   h, first_unicom, domestic, mobile_transit) {
      for (h = 1; h <= max_hop; h++) {
        if (is_10099_hop(asns[h], ips[h])) {
          first_unicom = h
          domestic = unicom_domestic_label_from_hop(h)
          if (domestic != "") return "10099->" domestic
          return "10099"
        }
        if (is_unicom_route_hop(h)) { first_unicom = h; break }
      }
      domestic = unicom_domestic_label_from_hop(first_unicom - 1)
      mobile_transit = mobile_label_before(first_unicom)
      if (target_isp == "联通" && domestic != "" && mobile_transit != "") return compact_combo_label(mobile_transit "->" domestic)
      if (target_isp == "联通" && domestic != "" && has_163_before(first_unicom)) return "163->" domestic
      return domestic
    }
    function has_cn2_to_163(first,   h, n) {
      if (first <= 0) return 0
      for (h = first; h <= max_hop; h++) {
        if (ips[h] !~ /^59\.43\.245\./) continue
        for (n = h + 1; n <= max_hop; n++) {
          if (ips[n] ~ /^59\.43\./) continue
          return asns[n] == "4134" || asns[n] == "4847" || is_163_ip(ips[n]) || (target_isp == "电信" && (is_telecom_access_asn(asns[n]) || is_telecom_access_ip(ips[n])))
        }
      }
      return 0
    }
    function is_mainland_backbone_hop(asn, ip) {
      if (is_10099_hop(asn, ip)) return 1
      if (asn == "9929" || asn == "4837" || asn == "4808") return 1
      if (asn == "4809") return !is_oversea_cn2_ip(ip)
      if (asn == "4134" || asn == "4847") return 1
      if (is_163_ip(ip)) return 1
      if (target_isp == "电信" && (is_telecom_access_asn(asn) || is_telecom_access_ip(ip))) return 1
      if (asn == "23764" || is_ctgnet_ip(ip)) return !is_ctgnet_transit_ip(ip)
      if (asn == "58807" || asn == "58453" || asn == "9808") return 1
      if (asn ~ /^5604[0-8]$/) return 1
      if (target_isp == "移动" && (is_mobile_access_asn(asn) || is_mobile_access_ip(ip))) return 1
      if (asn == "23911" || asn == "23910" || asn == "4538" || asn == "7497") return 1
      return 0
    }
    function label_from_mainland_hop(hop, asn, ip,   h) {
      if (is_10099_hop(asn, ip)) return "10099"
      if (asn == "9929") return "9929"
      if (asn == "4837" || asn == "4808") return "4837"
      if (asn == "4134" || asn == "4847" || is_163_ip(ip)) return "163"
      if (target_isp == "电信" && (is_telecom_access_asn(asn) || is_telecom_access_ip(ip))) return "163"
      if (asn == "23764" || is_ctgnet_ip(ip)) return ""
      if (asn == "4809") {
        if (has_cn2_to_163(hop)) return "CN2GT"
        for (h = hop; h <= max_hop; h++) {
          if (asns[h] == "23764" || is_ctgnet_ip(ips[h])) return "CTGGIA"
        }
        return "CN2GIA"
      }
      if (asn == "58807") return "CMIN2"
      if (asn == "58453" || asn == "9808" || asn ~ /^5604[0-8]$/) return "CMI"
      if (target_isp == "移动" && (is_mobile_access_asn(asn) || is_mobile_access_ip(ip))) return "CMI"
      if (asn == "23911" || asn == "23910") return "CERNET2"
      if (asn == "4538") return "CERNET"
      if (asn == "7497") return "CSTNET"
      return ""
    }
    function is_local_probe_asn(asn) { return asn == "" || asn == "749" }
    function is_target_isp_hop(asn, ip) {
      if (target_isp == "电信") return is_163_ip(ip) || is_telecom_access_asn(asn) || is_telecom_access_ip(ip)
      if (target_isp == "联通") return is_unicom_backbone_asn(asn) || is_unicom_backbone_ip(ip) || is_unicom_access_asn(asn)
      if (target_isp == "移动") return asn == "58807" || asn == "58453" || asn == "9808" || asn ~ /^5604[0-8]$/ || is_mobile_access_asn(asn) || is_mobile_access_ip(ip)
      return 0
    }
    function visible_hops_match_target_isp(   h) {
      if (max_hop <= 0) return 0
      for (h = 1; h <= max_hop; h++) {
        if (is_local_probe_asn(asns[h])) continue
        if (is_target_isp_hop(asns[h], ips[h])) continue
        return 0
      }
      return 1
    }
    function label_from_target_ip(   asn) {
      if (dest_ip == "" || !visible_hops_match_target_isp()) return ""
      asn = asn_by_ip[dest_ip]
      if (asn == "") asn = infer_asn_from_ip(dest_ip)
      if (target_isp == "电信" && (is_163_ip(dest_ip) || is_telecom_access_asn(asn) || is_telecom_access_ip(dest_ip))) return "163"
      if (target_isp == "联通" && (is_unicom_backbone_asn(asn) || is_unicom_backbone_ip(dest_ip) || is_unicom_access_asn(asn))) return unicom_route_combo_label()
      if (target_isp == "移动" && asn == "58807") return "CMIN2"
      if (target_isp == "移动" && (asn == "58453" || asn == "9808" || asn ~ /^5604[0-8]$/ || is_mobile_access_asn(asn) || is_mobile_access_ip(dest_ip))) return "CMI"
      return ""
    }
    function classify(   hop, label, first_cn2, has_ctgnet, has_cn2) {
      for (hop = 1; hop <= max_hop; hop++) {
        if (asns[hop] == "23764" || is_ctgnet_ip(ips[hop])) has_ctgnet = 1
        if (ips[hop] ~ /^59\.43\./) {
          has_cn2 = 1
          if (first_cn2 == 0) first_cn2 = hop
        }
      }
      if (has_cn2) {
        if (has_cn2_to_163(first_cn2)) return "CN2GT"
        if (has_ctgnet) return "CTGGIA"
        return "CN2GIA"
      }
      label = unicom_route_combo_label()
      if (label != "") return label
      if (has_asn("58807")) return "CMIN2"
      for (hop = 1; hop <= max_hop; hop++) {
        if (!is_mainland_backbone_hop(asns[hop], ips[hop])) continue
        label = label_from_mainland_hop(hop, asns[hop], ips[hop])
        if (label != "") return label
      }
      if (has_asn("23911")) return "CERNET2"
      if (has_asn("9929")) return "9929"
      if (has_asn("4837") || has_asn("4808")) return "4837"
      if (has_asn("4847")) return "163"
      if (has_asn("58453") || has_asn("9808") || has_asn("56040") || has_asn("56041") || has_asn("56042") || has_asn("56044") || has_asn("56045") || has_asn("56046") || has_asn("56047") || has_asn("56048")) return "CMI"
      if (has_ctgnet || has_asn("23764")) return "CTGGIA"
      if (has_asn("23910")) return "CERNET2"
      if (has_asn("4538")) return "CERNET"
      if (has_asn("7497")) return "CSTNET"
      label = label_from_target_ip()
      if (label != "") return label
      return "Hidden"
    }
    FILENAME == ARGV[1] { asn_by_ip[$1] = $2; next }
    FILENAME == ARGV[2] {
      ip = $0
      if (seen_ip[ip]++) next
      asn = asn_by_ip[ip]
      if (asn == "") asn = infer_asn_from_ip(ip)
      max_hop++
      ips[max_hop] = ip
      asns[max_hop] = asn
      add_asn(asn)
      next
    }
    /^#/ { if (NF >= 6) dest_ip = $6; next }
    /^target[[:space:]]/ { if (split($0, target_fields, /[[:space:]]+/) >= 2) dest_ip = target_fields[2]; next }
    /bad integer value|unknown arguments/ { in_usage = 1; next }
    /^usage:/ { in_usage = 1; next }
    in_usage { next }
    /^traceroute[[:space:]]/ || / -> .*hops max/ || /^NextTrace[[:space:]]/ || /^IP Geo Data Provider:/ { next }
    {
      while (match($0, /[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*/)) {
        ip = substr($0, RSTART, RLENGTH)
        $0 = substr($0, RSTART + RLENGTH)
        if (seen_ip[ip]++) continue
        asn = asn_by_ip[ip]
        if (asn == "") asn = infer_asn_from_ip(ip)
        max_hop++
        ips[max_hop] = ip
        asns[max_hop] = asn
        add_asn(asn)
      }
    }
    END { print classify() }
  ' "$asn_map_file" "$trace_ip_file" "$trace_file"
}

# ===================== 教育网回程线路识别 =====================
# 逐字移植自 TcpQuality:education_route_label_from_ip_trace。
# 教育网出国路径和三网不同：常见形态是「国际线路 -> HKIX/国内骨干 -> CERNET」，
# 所以先定位第一个教育网跳点，再往前回溯识别中转，拿不到结果时退回通用判定。
cn_education_route_label_from_ip_trace() {
  local trace_file="$1" asn_map_file="$2" trace_ip_file="$3" family="$4"
  local fallback label
  fallback=$(cn_route_label_from_ip_trace "$trace_file" "$asn_map_file" "$trace_ip_file" "教育网")
  label=$(awk -F'|' -v family="$family" '
    function infer_education_asn(ip) {
      if (ip ~ /^59\.64\./ || ip ~ /^101\.4\./ || ip ~ /^101\.6\./ || ip ~ /^101\.76\./ || ip ~ /^111\.114\./ || ip ~ /^113\.54\./ || ip ~ /^115\.24\./ || ip ~ /^115\.156\./ || ip ~ /^183\.172\./ || ip ~ /^202\.38\.19/ || ip ~ /^202\.112\./ || ip ~ /^202\.113\./ || ip ~ /^202\.114\./ || ip ~ /^202\.115\./ || ip ~ /^202\.116\./ || ip ~ /^202\.117\./ || ip ~ /^202\.118\./ || ip ~ /^202\.119\./ || ip ~ /^202\.120\./ || ip ~ /^202\.194\./ || ip ~ /^202\.196\./ || ip ~ /^202\.197\./ || ip ~ /^202\.198\./ || ip ~ /^202\.200\./ || ip ~ /^202\.201\./ || ip ~ /^202\.202\./ || ip ~ /^202\.207\./ || ip ~ /^210\.2[6-9]\./ || ip ~ /^210\.3[0-9]\./ || ip ~ /^210\.4[0-7]\./ || ip ~ /^219\.22[4-9]\./ || ip ~ /^222\.(1[6-9]|2[0-3])\./ || ip ~ /^222\.19[2-9]\./ || ip ~ /^222\.20[0-7]\./) return "4538"
      if (ip ~ /^2001:252:/) return "23911"
      if (ip ~ /^2001:da8:/ || ip ~ /^2001:250:/ || ip ~ /^2402:f000:/) return "23910"
      return ""
    }
    function infer_route_asn(ip,   asn) {
      asn = infer_education_asn(ip)
      if (asn != "") return asn
      if (ip ~ /^59\.43\./) return "4809"
      if (ip ~ /^203\.22\.182\./ || ip ~ /^203\.22\.(178|179)\./ || ip ~ /^203\.128\.224\./ || ip ~ /^69\.194\./ || ip ~ /^2400:9380:/) return "23764"
      if (ip ~ /^202\.97\./ || ip ~ /^202\.96\./ || ip ~ /^219\.141\./ || ip ~ /^219\.142\./ || ip ~ /^106\.37\./ || ip ~ /^240e:/) return "4134"
      if (ip ~ /^219\.158\./ || (ip ~ /^2408:/ && ip !~ /^2408:8120:/)) return "4837"
      if (ip ~ /^223\.120\./ || ip ~ /^223\.119\./) return "58453"
      if (ip ~ /^221\.183\./ || ip ~ /^111\.24\./ || ip ~ /^111\.13\./ || ip ~ /^2409:8080:/) return "9808"
      if (ip ~ /^2402:4f00:f000:/) return "58807"
      if (ip ~ /^2401:3cc0:/) return "7578"
      if (ip ~ /^103\.214\./ || ip ~ /^103\.228\.68\./ || ip ~ /^103\.239\.176\./ || ip ~ /^118\.26\.151\./ || ip ~ /^162\.219\.(3[2-9]|85)\./ || ip ~ /^162\.245\.124\./ || ip ~ /^202\.77\.23\./ || ip ~ /^203\.160\.(66|75)\./ || ip ~ /^2401:8a00:/) return "10099"
      if (ip ~ /^210\.14\./ || ip ~ /^210\.51\./ || ip ~ /^210\.78\./ || ip ~ /^218\.105\./ || ip ~ /^2408:8120:/) return "9929"
      return ""
    }
    function is_education_asn(asn, owner,   lower_owner) {
      lower_owner = tolower(owner)
      return asn == "4538" || asn == "23910" || asn == "23911" || asn == "24350" || lower_owner ~ /cernet/
    }
    function is_education_hop(asn, owner, ip) {
      return is_education_asn(asn, owner) || infer_education_asn(ip) != ""
    }
    function is_hkix_ip(ip) {
      return ip ~ /^123\.255\.(8[8-9]|9[0-5])\./ || ip ~ /^2001:7fa:/
    }
    function is_he_exchange_ip(ip) { return ip == "2001:504:13::210:122" }
    function is_ctggia_ip(ip) { return ip ~ /^59\.43\./ }
    function is_ctggia_hop(asn, owner, ip,   lower_owner) {
      lower_owner = tolower(owner)
      return asn == "23764" || is_ctggia_ip(ip) || lower_owner ~ /china telecom global|ctgnet|ctg[- ]/
    }
    function compact_owner(owner,   value, words, count, i, result, candidate) {
      value = owner
      sub(/[[:space:]]+-[[:space:]].*$/, "", value)
      gsub(/,/, "", value)
      gsub(/[[:space:]]+(Limited|Ltd\.?|Inc\.?|LLC|Corporation|Corp\.?|Company|Co\.?)$/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (length(value) <= 9) return value
      count = split(value, words, /[[:space:]]+/)
      for (i = 1; i <= count; i++) {
        candidate = result (result == "" ? "" : " ") words[i]
        if (length(candidate) > 9) break
        result = candidate
      }
      return result != "" ? result : substr(value, 1, 9)
    }
    function is_generic_owner_label(label,   lower_label) {
      lower_label = tolower(label)
      return lower_label == "global" || lower_label == "network" || lower_label == "networks" || lower_label == "internet" || lower_label == "communications" || lower_label == "telecom"
    }
    function transit_label(asn, owner, ip,   lower_owner, label) {
      if (is_hkix_ip(ip)) return "HKIX"
      if (is_he_exchange_ip(ip)) return "HE"
      if (is_ctggia_hop(asn, owner, ip)) return "CTGGIA"
      if (asn == "4134") return "163"
      if (asn == "4837") return "4837"
      if (asn == "58807") return "CMIN2"
      if (asn == "10099") return "10099"
      if (asn == "9929") return "9929"
      if (asn == "58453" || asn == "9808" || asn ~ /^5604[0-8]$/) return "CMI"
      if (asn == "7578" || asn == "137409") return "GSL"
      lower_owner = tolower(owner)
      if (lower_owner ~ /chinanet[- ]backbone/) return "163"
      if (lower_owner ~ /china169[- ]backbone/) return "4837"
      if (lower_owner ~ /china unicom industrial internet|cuii/) return "9929"
      if (lower_owner ~ /china mobile international|cmi-int/) return "CMI"
      if (lower_owner ~ /global secure layer/) return "GSL"
      if (asn == "6939" || lower_owner ~ /hurricane electric/) return "HE"
      if (lower_owner ~ /ntt/) return "NTT"
      if (lower_owner ~ /arelion|twelve99|telia carrier/) return "Arelion"
      if (lower_owner ~ /cogent/) return "Cogent"
      if (lower_owner ~ /tata communications/) return "Tata"
      label = compact_owner(owner)
      if (is_generic_owner_label(label)) return asn != "" ? "AS" asn : ""
      return label != "" ? label : (asn != "" ? "AS" asn : "")
    }
    function domestic_label(asn, owner, ip,   lower_owner) {
      lower_owner = tolower(owner)
      if (asn == "4134" || ip ~ /^202\.97\./ || ip ~ /^202\.96\./ || ip ~ /^219\.141\./ || ip ~ /^219\.142\./ || ip ~ /^106\.37\./ || ip ~ /^240e:/ || lower_owner ~ /chinanet[- ]backbone/) return "163"
      if (asn == "9929" || ip ~ /^210\.14\./ || ip ~ /^210\.51\./ || ip ~ /^210\.78\./ || ip ~ /^218\.105\./ || ip ~ /^2408:8120:/ || lower_owner ~ /china unicom industrial internet|cuii/) return "9929"
      if (asn == "4837" || ip ~ /^219\.158\./ || (ip ~ /^2408:/ && ip !~ /^2408:8120:/) || lower_owner ~ /china169[- ]backbone/) return "4837"
      return ""
    }
    function is_international_label(label) {
      return label == "CTGGIA" || label == "10099" || label == "CMI" || label == "CMIN2" || label == "HE" || label == "GSL" || label == "NTT" || label == "Arelion" || label == "Cogent" || label == "Tata"
    }
    FILENAME == ARGV[1] {
      asn_by_ip[tolower($1)] = $2
      owner_by_ip[tolower($1)] = $3
      next
    }
    FILENAME == ARGV[2] {
      ip = tolower($0)
      if (seen[ip]++) next
      hop++
      ips[hop] = ip
      asns[hop] = asn_by_ip[ip]
      owners[hop] = owner_by_ip[ip]
      if (asns[hop] == "") asns[hop] = infer_route_asn(ip)
      next
    }
    END {
      first_education = 0
      for (h = 1; h <= hop; h++) {
        if (is_education_hop(asns[h], owners[h], ips[h])) { first_education = h; break }
      }
      if (first_education == 0) exit
      for (h = 1; h < first_education; h++) {
        if (is_hkix_ip(ips[h]) && first_hkix == 0) first_hkix = h
        candidate = transit_label(asns[h], owners[h], ips[h])
        if (is_international_label(candidate)) {
          if (first_international == "") first_international = candidate
          if (candidate == "CMIN2") { seen_cmin2 = 1; international = candidate }
          else if (candidate == "CMI" && seen_cmin2) { international = "CMIN2->CMI" }
          else { international = candidate }
          last_international = h
        }
      }
      if (first_hkix > 0) {
        for (h = first_hkix - 1; h >= 1; h--) {
          candidate = transit_label(asns[h], owners[h], ips[h])
          if (candidate == "" || candidate == "HKIX" || candidate == "163" || candidate == "4837" || candidate == "9929") continue
          if (is_international_label(candidate)) { upstream = candidate; break }
          if (fallback_upstream == "") fallback_upstream = candidate
        }
        if (upstream == "") upstream = fallback_upstream
        print (upstream != "" ? upstream "->HKIX" : "HKIX")
        exit
      }
      if (last_international > 0) {
        for (h = last_international + 1; h < first_education; h++) {
          domestic = domestic_label(asns[h], owners[h], ips[h])
          if (domestic != "") { first_domestic = domestic; break }
        }
        if (first_domestic != "") {
          print (international !~ /->/ ? international "->" first_domestic : international)
        } else if (international ~ /->/) {
          print international
        } else if (first_international != "" && first_international != international) {
          print first_international "->" international
        } else {
          print international
        }
        exit
      }
      for (h = first_education - 1; h >= 1; h--) {
        if (is_education_hop(asns[h], owners[h], ips[h])) continue
        transit = transit_label(asns[h], owners[h], ips[h])
        if (transit != "") break
      }
      if (transit == "") transit = "Hidden"
      print transit
    }
  ' "$asn_map_file" "$trace_ip_file")
  printf '%s' "${label:-$fallback}"
}

# ===================== 单节点 traceroute =====================
# cn_route_trace_one <family> <protocol> <prov> <isp> <host> <idx> <port> <ip> <prefix> [包长]
# 包长即 traceroute 的探测包总字节数；大包回程用 1200 以暴露只对大包生效的绕行。
cn_route_trace_one() {
  local family="$1" protocol="$2" prov="$3" isp="$4" host="$5" idx="$6" port="${7:-80}" target_ip="${8:-}" prefix="${9:-route}"
  local packet_length="${10:-44}"
  local outfile="${CN_RESULT_DIR}/${prefix}_${idx}" trace_file="${CN_RESULT_DIR}/${prefix}_trace_${idx}"
  local probe_arg="-T" output rc retry_output
  [ "$protocol" = udp ] && probe_arg="-U"

  if [ -z "$target_ip" ]; then
    echo "FAIL|$prov|$isp|$protocol|$host|NO_NODE_IP" > "$outfile"
    return
  fi

  local -a args=(-n "-${family}" "$probe_arg" -p "$port" -q 3 -w 2 -m 30 "$target_ip" "$packet_length")
  if output=$(traceroute "${args[@]}" 2>&1); then rc=0; else rc=$?; fi

  {
    printf '# %s|%s|%s|%s|%s|%s\n' "$prov" "$isp" "$protocol" "$host" "$idx" "$target_ip"
    printf 'target %s\n' "$target_ip"
    printf '%s\n' "$output"
  } > "$trace_file"

  # 10099 之后国内段被隐藏时重试一次，把隐藏的国内跳点打出来
  if [ "$family" = 4 ] && [ "$protocol" = tcp ] && cn_route_needs_10099_retry "$trace_file"; then
    retry_output=$(traceroute "${args[@]}" 2>&1) || true
    {
      printf '\n# retry 10099 hidden domestic segment|%s|%s|%s|%s|%s|%s\n' "$prov" "$isp" "$protocol" "$host" "$idx" "$target_ip"
      printf 'target %s\n' "$target_ip"
      printf '%s\n' "$retry_output"
    } >> "$trace_file"
  fi

  if cn_extract_trace_ips "$trace_file" | grep -q .; then
    echo "TRACE|$prov|$isp|$protocol|$host|$idx" > "$outfile"
    return
  fi
  if [[ "$output" == *"peration not permitted"* ]]; then
    echo "FAIL|$prov|$isp|$protocol|$host|PERMISSION" > "$outfile"
  elif [ "$rc" -ne 0 ]; then
    echo "FAIL|$prov|$isp|$protocol|$host|TRACE_ERROR" > "$outfile"
  else
    echo "FAIL|$prov|$isp|$protocol|$host|NO_HOPS" > "$outfile"
  fi
}

# cn_collect_routes <family> <节点组> <输出文件> <prefix> [education] [包长]
# 并行跑完全部 traceroute，再一次性批量查 ASN，最后逐条判定线路标签。
# 第 5 个参数为 education 时改用教育网专用判定；第 6 个参数指定探测包长。
cn_collect_routes() {
  local family="$1" group="$2" out_file="$3" prefix="$4" mode="${5:-normal}" packet_length="${6:-44}"
  local idx=0 total=0 prov isp host ip port _bh _bi _bp
  local raw_file ip_file cymru_file asn_map_file trace_ip_file
  local status protocol value label

  # --route-protocol both 时 TCP/UDP 各跑一遍：部分线路对 TCP 探测隐藏跳点，
  # 但对 UDP 会回 ICMP，两种协议的结果合起来才看得全。
  local -a protocols=()
  if [ "$CN_ROUTE_PROTOCOL" = both ]; then
    protocols=(tcp udp)
  else
    protocols=("$CN_ROUTE_PROTOCOL")
  fi

  local node_count=0 protocol
  while IFS='|' read -r prov isp host ip port _bh _bi _bp; do
    cn_province_selected "$prov" && node_count=$((node_count + 1))
  done < <(cn_print_nodes "$group")
  [ "$node_count" -eq 0 ] && return 0
  total=$((node_count * ${#protocols[@]}))

  for protocol in "${protocols[@]}"; do
    while IFS='|' read -r prov isp host ip port _bh _bi _bp; do
      cn_province_selected "$prov" || continue
      idx=$((idx + 1))
      while [ "$(jobs -pr | wc -l | tr -d ' ')" -ge "$CN_PARALLEL" ]; do sleep 0.2; done
      sb_progress "$idx" "$total" "回程线路识别 ${prov}${isp} (${protocol})"
      cn_route_trace_one "$family" "$protocol" "$prov" "$isp" "$host" "$idx" "${port:-80}" "$ip" "$prefix" "$packet_length" &
    done < <(cn_print_nodes "$group")
  done
  wait
  sb_progress_done

  raw_file=$(mktemp); ip_file=$(mktemp); cymru_file=$(mktemp); asn_map_file=$(mktemp)
  for idx in $(seq 1 "$total"); do
    [ -f "${CN_RESULT_DIR}/${prefix}_${idx}" ] && cat "${CN_RESULT_DIR}/${prefix}_${idx}" >> "$raw_file"
    [ -f "${CN_RESULT_DIR}/${prefix}_trace_${idx}" ] && \
      cn_extract_trace_ips "${CN_RESULT_DIR}/${prefix}_trace_${idx}" >> "$ip_file"
  done
  sort -u "$ip_file" -o "$ip_file" 2>/dev/null || true

  if [ -s "$ip_file" ]; then
    sb_spin_msg "正在批量查询跳点 ASN..."
    cn_query_cymru_asn "$ip_file" "$cymru_file"
    cn_build_asn_map "$cymru_file" "$asn_map_file"
    cn_append_server_asn_meta "$ip_file" "$asn_map_file"
    sb_progress_done
  fi

  while IFS='|' read -r status prov isp protocol host value; do
    if [ "$status" = TRACE ] && [ -f "${CN_RESULT_DIR}/${prefix}_trace_${value}" ]; then
      trace_ip_file="${CN_RESULT_DIR}/${prefix}_trace_${value}.ips"
      cn_extract_trace_ips "${CN_RESULT_DIR}/${prefix}_trace_${value}" > "$trace_ip_file"
      if [ "$mode" = education ]; then
        label=$(cn_education_route_label_from_ip_trace "${CN_RESULT_DIR}/${prefix}_trace_${value}" \
                  "$asn_map_file" "$trace_ip_file" "$family")
      else
        label=$(cn_route_label_from_ip_trace "${CN_RESULT_DIR}/${prefix}_trace_${value}" \
                  "$asn_map_file" "$trace_ip_file" "$isp")
      fi
      echo "OK|$prov|$isp|$protocol|$host|${label:-Hidden}" >> "$out_file"
    elif [ -n "$status" ]; then
      echo "$status|$prov|$isp|$protocol|$host|${value:-Hidden}" >> "$out_file"
    fi
  done < "$raw_file"

  rm -f "$raw_file" "$ip_file" "$cymru_file" "$asn_map_file"
}

# ===================== nping 丢包探测 =====================
cn_nping_random_source_port() { printf '%s\n' $((20000 + RANDOM % 40000)); }
cn_nping_random_seq() { printf '%s\n' $((((RANDOM << 16) ^ RANDOM) & 0x7ffffffe)); }

# 从 nping 原始输出中，按四元组匹配 SENT/RCVD 求最小 RTT。
# 不能直接用 nping 汇总的 rtt：并发探测时它会把别的流的响应算进来。
cn_nping_matching_min_rtt() {
  printf '%s\n' "$1" | awk '
    function ep_ip(ep) { sub(/:[0-9]+$/, "", ep); return tolower(ep) }
    function ep_port(ep) { if (match(ep, /:[0-9]+$/)) return substr(ep, RSTART + 1); return "" }
    function parse_tcp_line(line, prefix,   time_s, body, parts, left, right) {
      time_s = line; sub(/^[^(]*\(/, "", time_s); sub(/s\).*/, "", time_s)
      body = line; sub(/^.* TCP /, "", body)
      split(body, parts, " > ")
      if (!parts[1] || !parts[2]) return 0
      left = parts[1]; right = parts[2]; sub(/ .*/, "", right)
      if (!ep_port(left) || !ep_port(right)) return 0
      if (prefix == "sent") {
        sent_time = time_s + 0; sent_src_ip = ep_ip(left); sent_src_port = ep_port(left)
        sent_dst_ip = ep_ip(right); sent_dst_port = ep_port(right); have_sent = 1
      } else {
        rcvd_time = time_s + 0; rcvd_src_ip = ep_ip(left); rcvd_src_port = ep_port(left)
        rcvd_dst_ip = ep_ip(right); rcvd_dst_port = ep_port(right)
      }
      return 1
    }
    /^SENT .* TCP / && !have_sent { parse_tcp_line($0, "sent") }
    /^RCVD .* TCP / && have_sent {
      if (parse_tcp_line($0, "rcvd") &&
          rcvd_src_ip == sent_dst_ip && rcvd_src_port == sent_dst_port &&
          rcvd_dst_ip == sent_src_ip && rcvd_dst_port == sent_src_port) {
        rtt_ms = (rcvd_time - sent_time) * 1000
        if (!found || rtt_ms < min_rtt) min_rtt = rtt_ms
        found = 1
      }
    }
    END { if (found) printf "%.3f\n", min_rtt; else exit 1 }
  '
}

# cn_probe_target <group> <family> <prov> <isp> <host> <ip> <port>
# 输出：状态|省|运营商|域名|IP|发送|接收|丢包率|平均延迟
cn_probe_target() {
  local group="$1" family="$2" prov="$3" isp="$4" host="$5" ip="$6" port="${7:-80}"

  if [ "$family" = 4 ] && [ -n "$ip" ] && ! cn_is_public_ipv4 "$ip"; then ip=""; fi
  if [ -z "$ip" ]; then
    echo "FAIL|$prov|$isp|$host|GETNODES|0|0|100.00|0"
    return
  fi

  local -a base_args=(--tcp -p "$port" --flags syn)
  local -a l2_args=()
  local l2_ready=0 l2_failed=0 use_l2=0
  local iface src_ip src_mac dst_mac route_data
  [ "$family" = 6 ] && base_args=(-6 "${base_args[@]}")

  local sent=0 rcvd=0 rtt_sum=0 i raw one_sent one_rcvd one_rtt sport tseq
  local header_size=40
  [ "$family" = 6 ] && header_size=60

  # 大包模式下按 3:1 的比例混合大小包；比例用「剩余配额」而非固定概率，
  # 保证发完 CN_PACKETS 个包时大小包数量正好符合目标。
  local big_target=0 big_used=0 small_used=0 remaining big_remaining small_remaining
  [ "$CN_LARGE_MODE" -eq 1 ] && big_target=$(((CN_PACKETS * 3 + 3) / 4))

  # IPv6 预检已确认三层发不通时，直接从二层开始，不浪费前几个包
  if [ "$family" = 6 ] && [ "$CN_IPV6_FORCE_L2" -eq 1 ]; then
    if route_data=$(cn_get_ipv6_route "$ip"); then
      IFS='|' read -r iface src_ip src_mac dst_mac <<< "$route_data"
      l2_args=(-6 -e "$iface" -S "$src_ip" --source-mac "$src_mac" --dest-mac "$dst_mac" --tcp -p "$port" --flags syn)
      l2_ready=1
      use_l2=1
    else
      l2_failed=1
    fi
  fi

  local packet_size payload_size
  for ((i = 1; i <= CN_PACKETS; i++)); do
    if [ -n "$CN_PACKET_SIZE_OVERRIDE" ]; then
      packet_size="$CN_PACKET_SIZE_OVERRIDE"
    elif [ "$CN_LARGE_MODE" -eq 1 ]; then
      remaining=$((CN_PACKETS - i + 1))
      big_remaining=$((big_target - big_used))
      small_remaining=$((CN_PACKETS - big_target - small_used))
      if [ "$big_remaining" -ge "$remaining" ] || [ "$small_remaining" -le 0 ] || \
         [ $((RANDOM % remaining)) -lt "$big_remaining" ]; then
        packet_size="${CN_LARGE_BIG_SIZES[$((RANDOM % ${#CN_LARGE_BIG_SIZES[@]}))]}"
        big_used=$((big_used + 1))
      else
        packet_size="${CN_LARGE_SMALL_SIZES[$((RANDOM % ${#CN_LARGE_SMALL_SIZES[@]}))]}"
        small_used=$((small_used + 1))
      fi
    else
      packet_size="$header_size"    # 无负载 SYN
    fi
    payload_size=0
    [ "$packet_size" -gt "$header_size" ] && payload_size=$((packet_size - header_size))

    local -a cur_args=("${base_args[@]}")
    [ "$use_l2" -eq 1 ] && cur_args=("${l2_args[@]}")
    sport=$(cn_nping_random_source_port)
    tseq=$(cn_nping_random_seq)
    cur_args+=(-g "$sport" --seq "$tseq")
    [ "$payload_size" -gt 0 ] && cur_args+=(--data-length "$payload_size")

    raw=$(nping "${cur_args[@]}" -c 1 "$ip" 2>&1) || true
    one_sent=$(printf '%s\n' "$raw" | sed -nE 's/.*sent:[[:space:]]*([0-9]+).*/\1/p' | head -1)
    one_rcvd=$(printf '%s\n' "$raw" | sed -nE 's/.*Rcvd:[[:space:]]*([0-9]+).*/\1/p' | head -1)
    if [[ "$one_rcvd" =~ ^[0-9]+$ ]] && [ "$one_rcvd" -gt 0 ] && one_rtt=$(cn_nping_matching_min_rtt "$raw"); then
      one_rcvd=1
    elif [[ "$one_rcvd" =~ ^[0-9]+$ ]] && [ "$one_rcvd" -gt 0 ]; then
      # 收到的包不属于本次四元组，按丢包计
      one_rcvd=0; one_rtt=""
    fi

    # IPv6 三层发包失败时，回退到显式二层发包（部分云厂商必需）
    if { ! [[ "$one_sent" =~ ^[0-9]+$ ]] || [ "$one_sent" -ne 1 ] || \
         ! [[ "$one_rcvd" =~ ^[0-9]+$ ]] || [ "$one_rcvd" -eq 0 ]; } && \
       [ "$family" = 6 ] && [ "$use_l2" -eq 0 ] && [ "$l2_failed" -eq 0 ]; then
      if [ "$l2_ready" -eq 0 ]; then
        if route_data=$(cn_get_ipv6_route "$ip"); then
          IFS='|' read -r iface src_ip src_mac dst_mac <<< "$route_data"
          l2_args=(-6 -e "$iface" -S "$src_ip" --source-mac "$src_mac" --dest-mac "$dst_mac" --tcp -p "$port" --flags syn)
          l2_ready=1
        else
          l2_failed=1
        fi
      fi
      if [ "$l2_ready" -eq 1 ]; then
        use_l2=1
        sport=$(cn_nping_random_source_port); tseq=$(cn_nping_random_seq)
        local -a l2_retry_args=("${l2_args[@]}" -g "$sport" --seq "$tseq")
        [ "$payload_size" -gt 0 ] && l2_retry_args+=(--data-length "$payload_size")
        raw=$(nping "${l2_retry_args[@]}" -c 1 "$ip" 2>&1) || true
        one_sent=$(printf '%s\n' "$raw" | sed -nE 's/.*sent:[[:space:]]*([0-9]+).*/\1/p' | head -1)
        one_rcvd=$(printf '%s\n' "$raw" | sed -nE 's/.*Rcvd:[[:space:]]*([0-9]+).*/\1/p' | head -1)
        if [[ "$one_rcvd" =~ ^[0-9]+$ ]] && [ "$one_rcvd" -gt 0 ] && one_rtt=$(cn_nping_matching_min_rtt "$raw"); then
          one_rcvd=1
        elif [[ "$one_rcvd" =~ ^[0-9]+$ ]] && [ "$one_rcvd" -gt 0 ]; then
          one_rcvd=0; one_rtt=""
        fi
      fi
    fi

    if ! [[ "$one_sent" =~ ^[0-9]+$ ]] || [ "$one_sent" -ne 1 ] || ! [[ "$one_rcvd" =~ ^[0-9]+$ ]]; then
      echo "FAIL|$prov|$isp|$host|$ip|0|0|100.00|NPING_ERROR"
      return
    fi

    sent=$((sent + one_sent))
    if [ "$one_rcvd" -gt 0 ]; then
      [[ "$one_rtt" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
        echo "FAIL|$prov|$isp|$host|$ip|0|0|100.00|NPING_ERROR"
        return
      }
      rcvd=$((rcvd + 1))
      rtt_sum=$(awk -v a="$rtt_sum" -v b="$one_rtt" 'BEGIN { printf "%.6f", a + b }')
    fi
  done

  local loss avg
  loss=$(awk -v s="$sent" -v r="$rcvd" 'BEGIN { if (s == 0) print "100.00"; else printf "%.2f", (s - r) * 100 / s }')
  if [ "$rcvd" -gt 0 ]; then
    avg=$(awk -v sum="$rtt_sum" -v r="$rcvd" 'BEGIN { printf "%.3f", sum / r }')
  else
    avg=0
  fi
  echo "OK|$prov|$isp|$host|$ip|$sent|$rcvd|$loss|$avg"
}

# 主备节点结果合并：主节点丢包偏高时用备用节点复核，两者都 OK 则取均值
cn_combine_probe_results() {
  local primary="$1" backup="$2"
  local ps pp pi ph pip psent prcv ploss plat bs _bp _bi _bh _bip bsent brcv bloss blat
  IFS='|' read -r ps pp pi ph pip psent prcv ploss plat <<< "$primary"
  IFS='|' read -r bs _bp _bi _bh _bip bsent brcv bloss blat <<< "$backup"
  if [ "$ps" != OK ] || [ "$bs" != OK ]; then
    echo "$backup"
    return
  fi
  local sent=$((psent + bsent)) rcv=$((prcv + brcv)) loss lat
  loss=$(awk -v a="$ploss" -v b="$bloss" 'BEGIN { printf "%.2f", (a + b) / 2 }')
  lat=$(awk -v a="$plat" -v b="$blat" 'BEGIN {
    if (a > 0 && b > 0) printf "%.3f", (a + b) / 2; else if (a > 0) printf "%.3f", a; else printf "%.3f", b }')
  echo "OK|$pp|$pi|$ph|$pip|$sent|$rcv|$loss|$lat"
}

# cn_test_one <group> <family> <prov> <isp> <host> <idx> <ip> <port> <backup_host> <backup_ip> <backup_port>
cn_test_one() {
  local group="$1" family="$2" prov="$3" isp="$4" host="$5" idx="$6"
  local ip="${7:-}" port="${8:-80}" backup_host="${9:-}" backup_ip="${10:-}" backup_port="${11:-80}"
  local outfile="${CN_RESULT_DIR}/${group}_${idx}" primary backup p_status p_loss b_status b_loss

  primary=$(cn_probe_target "$group" "$family" "$prov" "$isp" "$host" "$ip" "$port")
  IFS='|' read -r p_status _ _ _ _ _ _ p_loss _ <<< "$primary"

  if [ -n "$backup_ip" ] && { [ "$p_status" != OK ] || awk -v l="$p_loss" 'BEGIN { exit !(l + 0 > 15) }'; }; then
    backup=$(cn_probe_target "$group" "$family" "$prov" "$isp" "$backup_host" "$backup_ip" "$backup_port")
    IFS='|' read -r b_status _ _ _ _ _ _ b_loss _ <<< "$backup"
    if [ "$p_status" != OK ] || awk -v l="$p_loss" 'BEGIN { exit !(l + 0 >= 100) }'; then
      printf '%s\n' "$backup" > "$outfile"
      return
    fi
    if [ "$b_status" = OK ]; then
      if awk -v l="$b_loss" 'BEGIN { exit !(l + 0 > 0) }'; then
        cn_combine_probe_results "$primary" "$backup" > "$outfile"
      else
        printf '%s\n' "$backup" > "$outfile"
      fi
      return
    fi
  fi
  printf '%s\n' "$primary" > "$outfile"
}

# 大包模式：同一套探测逻辑，只是把 CN_LARGE_MODE 打开
cn_test_large_one() {
  local CN_LARGE_MODE=1 CN_PACKET_SIZE_OVERRIDE=""
  cn_test_one "$@"
}

# 大包预检：先拿 Cloudflare 试 1200B。丢包 ≥80% 说明本机出口对大包有拦截/限速，
# 这时再去测三网节点没有意义（结果全是 100% 丢包），直接标记跳过。
cn_large_packet_precheck() {
  local ip result status _p _i _h _ip sent rcv loss lat
  ip=$(cn_resolve_first_public_ipv4 "$CN_LARGE_PRECHECK_DOMAIN" || true)
  if [ -z "$ip" ]; then
    CN_LARGE_FIREWALL_LIMITED=1
    CN_LARGE_PRECHECK_LOSS="100.00"
    return 1
  fi
  local CN_PACKETS="$CN_LARGE_PRECHECK_PACKETS"
  local CN_PACKET_SIZE_OVERRIDE="$CN_LARGE_PRECHECK_SIZE"
  result=$(cn_probe_target largepre 4 Cloudflare 预检 "$CN_LARGE_PRECHECK_DOMAIN" "$ip" 443)
  IFS='|' read -r status _p _i _h _ip sent rcv loss lat <<< "$result"
  CN_LARGE_PRECHECK_LOSS="${loss:-100.00}"
  if [ "$status" != OK ] || awk -v l="${loss:-100}" 'BEGIN { exit !(l + 0 >= 80) }'; then
    CN_LARGE_FIREWALL_LIMITED=1
    return 1
  fi
  CN_LARGE_FIREWALL_LIMITED=0
  return 0
}

# IPv6 预检：三层发包收不到 SYN-ACK 时，后续统一走二层，省得每个节点各试一遍
cn_ipv6_nping_precheck() {
  local ip raw sent rcv sport tseq
  CN_IPV6_FORCE_L2=0
  ip=$(cn_resolve_first_public_ipv6 "$CN_LARGE_PRECHECK_DOMAIN" || true)
  [ -n "$ip" ] || return 0
  sport=$(cn_nping_random_source_port)
  tseq=$(cn_nping_random_seq)
  raw=$(nping -6 --tcp -p 443 -g "$sport" --seq "$tseq" --flags syn -c 5 "$ip" 2>&1 || true)
  sent=$(printf '%s\n' "$raw" | sed -nE 's/.*sent:[[:space:]]*([0-9]+).*/\1/p' | head -1)
  rcv=$(printf '%s\n' "$raw" | sed -nE 's/.*Rcvd:[[:space:]]*([0-9]+).*/\1/p' | head -1)
  if [[ "$rcv" =~ ^[0-9]+$ ]] && [ "$rcv" -gt 0 ] && ! cn_nping_matching_min_rtt "$raw" >/dev/null; then
    rcv=0
  fi
  if [[ "$sent" =~ ^[0-9]+$ ]] && [ "$sent" -gt 0 ] && [[ "$rcv" =~ ^[0-9]+$ ]] && [ "$rcv" -eq 0 ]; then
    CN_IPV6_FORCE_L2=1
  fi
}

# cn_run_probe_group <group> <family> <表名> [large]
cn_run_probe_group() {
  local group="$1" family="$2" table="$3" mode="${4:-normal}"
  local idx=0 total=0 prov isp host ip port bh bi bp
  local status _prov _isp _host _ip sent rcvd loss lat route
  local node_group="$group" probe_fn=cn_test_one label="丢包探测"

  # 大包组复用 cdn4 的节点表，只是换一套发包尺寸和结果文件前缀
  if [ "$mode" = large ]; then
    node_group=cdn4
    probe_fn=cn_test_large_one
    label="大包丢包探测"
  fi

  while IFS='|' read -r prov isp host ip port bh bi bp; do
    cn_province_selected "$prov" && total=$((total + 1))
  done < <(cn_print_nodes "$node_group")
  [ "$total" -eq 0 ] && return 0

  while IFS='|' read -r prov isp host ip port bh bi bp; do
    cn_province_selected "$prov" || continue
    idx=$((idx + 1))
    while [ "$(jobs -pr | wc -l | tr -d ' ')" -ge "$CN_PARALLEL" ]; do sleep 0.2; done
    sb_progress "$idx" "$total" "${label} ${prov}${isp}"
    "$probe_fn" "$group" "$family" "$prov" "$isp" "$host" "$idx" "$ip" "${port:-80}" "$bh" "$bi" "${bp:-80}" &
  done < <(cn_print_nodes "$node_group")
  wait
  sb_progress_done

  for idx in $(seq 1 "$total"); do
    [ -f "${CN_RESULT_DIR}/${group}_${idx}" ] || continue
    IFS='|' read -r status _prov _isp _host _ip sent rcvd loss lat < "${CN_RESULT_DIR}/${group}_${idx}"
    route=$(cn_lookup_route_label "$_prov" "$_isp")
    [ "$status" != OK ] && route="failed"
    sb_row_add "$table" "$_prov" "$_isp" "$status" "$sent" "$rcvd" "${loss}%" "$lat" "${route:-Hidden}"
  done
}

# 从已收集的线路标签文件中查省份+运营商对应的标签
CN_ROUTE_LABEL_FILE=""
cn_lookup_route_label() {
  [ -n "$CN_ROUTE_LABEL_FILE" ] && [ -f "$CN_ROUTE_LABEL_FILE" ] || return 0
  awk -F'|' -v p="$1" -v i="$2" \
    '$2 == p && $3 == i { if ($1 == "OK") print $6; else print "Hidden"; exit }' "$CN_ROUTE_LABEL_FILE"
}

# ===================== 国际互联 =====================
# 两部分，与 TcpQuality 一致：
#   1. 站点/CDN 可达性：TCP 连接 + TLS 握手计时 + HTTP 状态码
#   2. iPerf3 双向：每个国际节点分别做上传与下载，取 TCP RTT 与重传次数
CN_INTL_TARGETS=(
  'Cloudflare|dash.cloudflare.com'
  'GitHub API|api.github.com'
  'Google|www.google.com'
  'OpenAI API|api.openai.com'
  'Claude|claude.ai'
  'Steam|store.steampowered.com'
  'Telegram|telegram.org'
  'X|x.com'
  'YouTube API|youtubei.googleapis.com'
  'AWS CloudFront|d1.awsstatic.com'
  'Fastly|http-me.fastly.dev'
  'jsDelivr|cdn.jsdelivr.net'
  'Akamai|www.akamai.com'
  'Wikipedia|www.wikipedia.org'
)

# 区域|节点|主机|IPv4 起始端口|IPv6 起始端口|IPv4 备用主机|IPv4 备用端口|IPv6 备用主机|IPv6 备用端口
# Leaseweb 每个端口只允许一个连接，所以每个协议各占 5 个端口轮流重试。
CN_INTL_IPERF_TARGETS=(
  '亚洲|香港|speedtest.hkg12.hk.leaseweb.net|5201'
  '亚洲|日本|speedtest.tyo11.jp.leaseweb.net|5201'
  '亚洲|新加坡|speedtest.sin1.sg.leaseweb.net|5201'
  '美洲|美国西部-洛杉矶|speedtest.lax12.us.leaseweb.net|5201'
  '美洲|美国中部-达拉斯|speedtest.dal13.us.leaseweb.net|5201'
  '美洲|美国东部-芝加哥|speedtest.chi11.us.leaseweb.net|5201'
  '美洲|加拿大-蒙特利尔|speedtest.mtl2.ca.leaseweb.net|5201'
  '美洲|巴西-里约热内卢|speedtest.sao1.edgoo.net|9209|9208|speedtest.mia11.us.leaseweb.net|5201'
  '欧洲|德国-法兰克福|speedtest.fra1.de.leaseweb.net|5201'
  '欧洲|英国-伦敦|speedtest.lon1.uk.leaseweb.net|5201'
  '欧洲|荷兰-阿姆斯特丹|speedtest.ams1.nl.leaseweb.net|5201'
  '大洋洲|澳大利亚-悉尼|speedtest.syd12.au.leaseweb.net|5201||||syd.proof.ovh.net|5201'
)

CN_INTL_IPERF_SECONDS="${SBQUALITY_INTL_IPERF_SECONDS:-5}"
CN_INTL_IPERF_RATE="${SBQUALITY_INTL_IPERF_RATE:-1M}"
CN_INTL_IPERF_CONNECT_TIMEOUT_MS=5000
CN_INTL_IPERF_MAX_ATTEMPTS=10

cn_resolve_first_public_ipv4() {
  local host="$1" ip
  cn_is_public_ipv4 "$host" && { printf '%s' "$host"; return 0; }
  while read -r ip; do
    cn_is_public_ipv4 "$ip" && { printf '%s' "$ip"; return 0; }
  done < <(dig A +short "$host" 2>/dev/null | grep -E '^[0-9.]+$')
  return 1
}

cn_resolve_first_public_ipv6() {
  local host="$1" ip
  case "$host" in *:*) printf '%s' "$host"; return 0 ;; esac
  ip=$(dig AAAA +short "$host" 2>/dev/null | grep -m1 -E '^[0-9a-fA-F:]+$')
  [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
  return 1
}

# 下载方向 iperf3 自身报的 mean_rtt 是发送端视角，对下载没意义；
# 改为在传输过程中用 ss 读取内核对该连接的 RTT。
cn_tcp_info_rtt_ms() {
  local ip="$1" port="$2" filter
  sb_has ss || return 1
  case "$ip" in
    *:*) filter="dst [${ip}]:${port}" ;;
    *)   filter="dst ${ip}:${port}" ;;
  esac
  # shellcheck disable=SC2086
  ss -tin state established $filter 2>/dev/null |
    sed -nE 's/.*[[:space:]]rtt:([0-9]+(\.[0-9]+)?)\/.*/\1/p' | head -1
}

# cn_intl_iperf_one <family> <direction> <region> <label> <host> <v4端口> [v6端口] [备用主机] [备用端口]
# 输出：状态|RTT ms|重传次数|实际使用的 IP
cn_intl_iperf_one() {
  local family="$1" direction="$2" region="$3" label="$4" host="$5"
  local base_port="${6:-5201}" v6_base_port="${7:-}" fb_host="${8:-}" fb_port="${9:-}"
  local ip json err first_port port attempt=0 rtt_us tcp_rtt latency="-" retrans="-" status=FAIL
  local -a dir_args=()
  [ "$direction" = download ] && dir_args=(-R)
  [[ "$base_port" =~ ^[0-9]+$ ]] || base_port=5201

  if [ "$family" = 4 ]; then
    ip=$(cn_resolve_first_public_ipv4 "$host" || true)
  else
    ip=$(cn_resolve_first_public_ipv6 "$host" || true)
  fi
  if [ -z "$ip" ]; then
    if [ -n "$fb_host" ]; then
      cn_intl_iperf_one "$family" "$direction" "$region" "$label" "$fb_host" "${fb_port:-5201}"
      return
    fi
    printf 'SKIP|-|-|-'
    return
  fi

  # IPv4/IPv6 使用互不重叠的端口池，避免两族互相抢占
  if [ "$family" = 4 ]; then
    first_port="$base_port"
  elif [[ "$v6_base_port" =~ ^[0-9]+$ ]]; then
    first_port="$v6_base_port"
  else
    first_port=$((base_port + 5))
  fi

  while [ "$attempt" -lt "$CN_INTL_IPERF_MAX_ATTEMPTS" ]; do
    attempt=$((attempt + 1))
    port=$((first_port + ((attempt - 1) % 5)))
    json=$(mktemp "${CN_RESULT_DIR}/iperf3.XXXXXX.json")
    err="${json}.err"
    tcp_rtt=""

    if [ "$direction" = download ] && sb_has ss; then
      timeout 15 iperf3 "-${family}" "${dir_args[@]}" -c "$ip" -p "$port" \
        -t "$CN_INTL_IPERF_SECONDS" -b "$CN_INTL_IPERF_RATE" -J \
        --connect-timeout "$CN_INTL_IPERF_CONNECT_TIMEOUT_MS" > "$json" 2> "$err" &
      local pid=$!
      while kill -0 "$pid" 2>/dev/null; do
        tcp_rtt=$(cn_tcp_info_rtt_ms "$ip" "$port" || true)
        [[ "$tcp_rtt" =~ ^[0-9]+([.][0-9]+)?$ ]] || tcp_rtt=""
        sleep 0.2
      done
      wait "$pid" 2>/dev/null || true
    else
      timeout 15 iperf3 "-${family}" "${dir_args[@]}" -c "$ip" -p "$port" \
        -t "$CN_INTL_IPERF_SECONDS" -b "$CN_INTL_IPERF_RATE" -J \
        --connect-timeout "$CN_INTL_IPERF_CONNECT_TIMEOUT_MS" > "$json" 2> "$err" || true
    fi

    rtt_us=$(jq -r '.end.streams[0].sender.mean_rtt // .end.streams[0].receiver.mean_rtt // .intervals[-1].streams[0].rtt // empty' "$json" 2>/dev/null || true)
    local cand
    cand=$(jq -r '.end.streams[0].sender.retransmits // .end.sum_sent.retransmits // .end.streams[0].receiver.retransmits // empty' "$json" 2>/dev/null || true)

    if jq -e '(.error? // "") == "" and (((.start.connected // []) | length) > 0)' "$json" >/dev/null 2>&1; then
      if [ "$direction" = download ] && [[ "$tcp_rtt" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        latency=$(awk -v ms="$tcp_rtt" 'BEGIN { printf "%.3f", ms }')
      elif [[ "$rtt_us" =~ ^[0-9]+([.][0-9]+)?$ ]] && \
           [ "$(awk -v u="$rtt_us" 'BEGIN { print (u > 0) ? 1 : 0 }')" -eq 1 ]; then
        latency=$(awk -v u="$rtt_us" 'BEGIN { printf "%.3f", u / 1000 }')
      else
        latency="-"
      fi
      if [[ "$latency" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        [[ "$cand" =~ ^[0-9]+$ ]] && retrans="$cand"
        status=OK
        rm -f -- "$json" "$err"
        break
      fi
    fi
    rm -f -- "$json" "$err"
  done

  if [ "$status" != OK ] && [ -n "$fb_host" ]; then
    cn_intl_iperf_one "$family" "$direction" "$region" "$label" "$fb_host" "${fb_port:-5201}"
    return
  fi
  printf '%s|%s|%s|%s' "$status" "$latency" "$retrans" "$ip"
}

cn_run_international_iperf() {
  if ! sb_require iperf3 || ! sb_has jq; then
    sb_skip "cn.international.iperf" "缺少 iperf3 或 jq"
    return 0
  fi
  local entry region label host p4 p6 fb_host fb_port fb6_host fb6_port
  local family direction result status rtt retrans ip
  local i=0 total=$(( ${#CN_INTL_IPERF_TARGETS[@]} * 2 ))

  for entry in "${CN_INTL_IPERF_TARGETS[@]}"; do
    IFS='|' read -r region label host p4 p6 fb_host fb_port fb6_host fb6_port <<< "$entry"
    for family in 4 6; do
      [ "$family" = 4 ] && [ "${SB_IPV4_OK:-0}" -ne 1 ] && continue
      [ "$family" = 6 ] && [ "${SB_IPV6_OK:-0}" -ne 1 ] && continue
      for direction in upload download; do
        i=$((i + 1))
        sb_progress "$i" "$total" "iPerf3 ${label} IPv${family} ${direction}"
        if [ "$family" = 6 ]; then
          result=$(cn_intl_iperf_one 6 "$direction" "$region" "$label" "$host" "$p4" "$p6" "$fb6_host" "$fb6_port")
        else
          result=$(cn_intl_iperf_one 4 "$direction" "$region" "$label" "$host" "$p4" "" "$fb_host" "$fb_port")
        fi
        IFS='|' read -r status rtt retrans ip <<< "$result"
        sb_row_add cn.intl_iperf "$region" "$label" "IPv$family" \
          "$([ "$direction" = upload ] && echo 上传 || echo 下载)" \
          "$status" "${rtt} ms" "$retrans"
      done
    done
  done
  sb_progress_done
}

cn_run_international() {
  local entry name domain family flag i=0 total=${#CN_INTL_TARGETS[@]}
  local ip out http_code connect_ms tls_ms note

  for entry in "${CN_INTL_TARGETS[@]}"; do
    name="${entry%%|*}"
    domain="${entry#*|}"
    i=$((i + 1))
    sb_progress "$i" "$total" "国际互联 $name"

    for family in 4 6; do
      [ "$family" = 4 ] && [ "${SB_IPV4_OK:-0}" -ne 1 ] && continue
      [ "$family" = 6 ] && [ "${SB_IPV6_OK:-0}" -ne 1 ] && continue
      flag="-$family"

      ip=$(dig "$( [ "$family" = 6 ] && echo AAAA || echo A )" +short "$domain" 2>/dev/null | grep -m1 -E '^[0-9a-fA-F:.]+$')
      out=$(curl "$flag" -sS -o /dev/null --connect-timeout 5 --max-time 10 \
              -w '%{http_code}|%{time_connect}|%{time_appconnect}' \
              "https://${domain}/" 2>/dev/null)
      if [ -z "$out" ]; then
        sb_row_add cn.intl "$name" "IPv$family" "${ip:-—}" "失败" "—" "—" "连接超时或被阻断"
        continue
      fi
      IFS='|' read -r http_code connect_ms tls_ms <<< "$out"
      connect_ms=$(awk -v t="$connect_ms" 'BEGIN { printf "%.1f", t * 1000 }')
      tls_ms=$(awk -v t="$tls_ms" 'BEGIN { printf "%.1f", t * 1000 }')
      note=""
      case "$http_code" in
        000) note="握手失败" ;;
        4*)  note="可达（HTTP $http_code）" ;;
        5*)  note="服务端错误" ;;
      esac
      sb_row_add cn.intl "$name" "IPv$family" "${ip:-—}" "$http_code" \
        "${connect_ms} ms" "${tls_ms} ms" "$note"
    done
  done
  sb_progress_done
  cn_run_international_iperf
}

# ===================== 单线程测速 =====================
# 目标是「这条连接」的真实吞吐与重传率，不是全机统计，所以：
#   - 用 curl --resolve 固定到节点 IP，绕开 DNS 调度
#   - 重传优先取 LD_PRELOAD 抓的连接级 TCP_INFO；没有则退回 ss 快照
#   - 有 bpftrace 时再用 tcp_retransmit_skb 去重，得到「唯一重传段」比例
# 移植自 TcpQuality 的 speedtest_run_probe 及其配套函数。

CN_TOS_SIZE="${SBQUALITY_TOS_SIZE:-100M}"
CN_TOS_TIMEOUT="${SBQUALITY_TOS_TIMEOUT:-15}"
CN_TCPINFO_PRELOAD="/usr/local/lib/libsbquality-tcpinfo.so"
CN_RETRANS_TRACE_SEQ="/usr/local/libexec/sbquality-retrans-seq.bt"
CN_RETRANS_TRACE_SKB="/usr/local/libexec/sbquality-retrans-skb.bt"
CN_TOS_NODES=()

cn_tos_bucket_host() {
  case "$1" in
    cn-beijing)   printf 'probe-bucket-beijing.tos-cn-beijing.volces.com' ;;
    cn-shanghai)  printf 'probe-bucket-shanghai.tos-cn-shanghai.volces.com' ;;
    cn-guangzhou) printf 'probe-bucket-guangzhou.tos-cn-guangzhou.volces.com' ;;
    *) return 1 ;;
  esac
}

cn_tos_object_size_bytes() {
  local value="${CN_TOS_SIZE^^}" number unit multiplier
  [[ "$value" =~ ^([0-9]+([.][0-9]+)?)[[:space:]]*([KMGT]?I?B?)$ ]] || return 1
  number="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[3]}"
  case "$unit" in
    ""|B)        multiplier=1 ;;
    K|KB|KI|KIB) multiplier=1024 ;;
    M|MB|MI|MIB) multiplier=1048576 ;;
    G|GB|GI|GIB) multiplier=1073741824 ;;
    *) return 1 ;;
  esac
  awk -v n="$number" -v m="$multiplier" 'BEGIN { b = n * m; if (b < 1) exit 1; printf "%.0f", b }'
}

cn_tos_upload_key() {
  local uuid
  uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)
  [[ "$uuid" =~ ^[0-9a-fA-F-]{16,}$ ]] || uuid="$(date +%s%N)-$RANDOM"
  printf 'upload/%s' "$uuid"
}

# 上传用零填充流，避免先在磁盘上造一个大文件
cn_zero_stream() {
  local bytes="$1" full=$((bytes / 1048576)) rem=$((bytes % 1048576))
  [ "$full" -gt 0 ] && dd if=/dev/zero bs=1048576 count="$full" 2>/dev/null
  [ "$rem" -gt 0 ] && dd if=/dev/zero bs=1 count="$rem" 2>/dev/null
  return 0
}

cn_tos_delete_object() {
  local host="$1" ip="$2" key="$3"
  [ -n "$host" ] && [ -n "$ip" ] && [ -n "$key" ] || return 0
  curl -4 --noproxy '*' --http1.1 -sS -o /dev/null \
    --connect-timeout 5 --max-time 10 --resolve "$host:443:$ip" \
    -X DELETE "https://$host/$key" >/dev/null 2>&1 || true
}

# ---- eBPF 重传追踪 ----
CN_TRACE_PID=""
CN_TRACE_FILE=""
CN_TRACE_KEY=""

cn_retrans_trace_program() {
  if [ -r "$CN_RETRANS_TRACE_SEQ" ]; then
    CN_TRACE_KEY=seq
    printf '%s' "$CN_RETRANS_TRACE_SEQ"
  elif [ -r "$CN_RETRANS_TRACE_SKB" ]; then
    CN_TRACE_KEY=skb
    printf '%s' "$CN_RETRANS_TRACE_SKB"
  else
    return 1
  fi
}

cn_retrans_trace_start() {
  local out="$1" program
  CN_TRACE_PID=""
  CN_TRACE_FILE=""
  sb_has bpftrace || return 1
  [ "$SB_PRIV" = root ] || return 1
  program=$(cn_retrans_trace_program) || return 1
  CN_TRACE_FILE="${out}.trace"
  : > "$CN_TRACE_FILE"
  bpftrace "$program" > "$CN_TRACE_FILE" 2>"${CN_TRACE_FILE}.err" &
  CN_TRACE_PID=$!
  # 等 bpftrace 真正 attach 上，否则前几秒的重传会漏掉
  local waited=0
  while [ "$waited" -lt 30 ]; do
    grep -q . "$CN_TRACE_FILE" 2>/dev/null && break
    kill -0 "$CN_TRACE_PID" 2>/dev/null || { CN_TRACE_PID=""; return 1; }
    sleep 0.1
    waited=$((waited + 1))
  done
  return 0
}

cn_retrans_trace_stop() {
  [ -n "$CN_TRACE_PID" ] || return 0
  kill -INT "$CN_TRACE_PID" 2>/dev/null || true
  wait "$CN_TRACE_PID" 2>/dev/null || true
  CN_TRACE_PID=""
}

# 按 skaddr+seq+end_seq 去重，得到「唯一被重传的段数」
cn_retrans_trace_unique() {
  local file="$1" ip="$2"
  [ -s "$file" ] || return 1
  awk -F'|' -v target="$ip" -v key="$CN_TRACE_KEY" '
    {
      if (NF < 19) next
      # daddr 以 4 个字节字段给出（IPv4）
      addr = $2 "." $3 "." $4 "." $5
      if (addr != target) next
      if (key == "seq") id = $18 "|" $19 "|" $20
      else              id = $18 "|" $19
      if (!(id in seen)) { seen[id] = 1; n++ }
    }
    END { print n + 0 }
  ' "$file"
}

# ---- 连接级 TCP_INFO ----
# 优先 LD_PRELOAD（精确到这条连接）；没有 preload 库时退回轮询 ss。
CN_TCPINFO_MODE=none
CN_SS_MONITOR_PID=""

cn_tcp_info_ss_monitor_start() {
  local ip="$1" out="$2"
  sb_has ss || return 1
  (
    while :; do
      ss -tin state established "dst ${ip}" 2>/dev/null | awk '
        /retrans:/ {
          r = $0; sub(/.*retrans:[0-9]+\//, "", r); sub(/[^0-9].*/, "", r); total = r
        }
        /data_segs_out:/ {
          d = $0; sub(/.*data_segs_out:/, "", d); sub(/[^0-9].*/, "", d); segs = d
        }
        END { if (total != "" && segs != "") printf "%s|%s|%s|0\n", total, segs, segs }
      ' > "$out".tmp 2>/dev/null
      [ -s "$out".tmp ] && mv -f "$out".tmp "$out"
      sleep 0.3
    done
  ) &
  CN_SS_MONITOR_PID=$!
  return 0
}

cn_tcp_info_monitor_stop() {
  [ -n "$CN_SS_MONITOR_PID" ] || return 0
  kill "$CN_SS_MONITOR_PID" 2>/dev/null || true
  wait "$CN_SS_MONITOR_PID" 2>/dev/null || true
  CN_SS_MONITOR_PID=""
}

# cn_speedtest_probe <download|upload> <节点 IP> <region> <输出前缀>
# 输出：速率Mbps|连接ms|TLS ms|重传率|重传来源
cn_speedtest_probe() {
  local probe_type="$1" server_ip="$2" region="$3" out="$4"
  local host size key="" raw="${out}.curl" tcpinfo="${out}.tcpinfo"
  local -a curl_args
  local trace_ok=0 rc

  host=$(cn_tos_bucket_host "$region") || { printf 'failed|-|-|-|no_bucket'; return 0; }
  size=$(cn_tos_object_size_bytes) || { printf 'failed|-|-|-|bad_size'; return 0; }
  [[ "$server_ip" =~ ^([0-9]{1,3}[.]){3}[0-9]{1,3}$ ]] || { printf 'failed|-|-|-|bad_ip'; return 0; }

  curl_args=(
    curl -4 --noproxy '*' --http1.1 -sS --fail
    --connect-timeout 5 --max-time "$CN_TOS_TIMEOUT"
    --resolve "$host:443:$server_ip"
    -A 'SBQuailty fixed TOS probe'
    -w '%{http_code}|%{size_download}|%{speed_download}|%{size_upload}|%{speed_upload}|%{time_connect}|%{time_appconnect}|%{time_total}'
    -o /dev/null
  )
  if [ "$probe_type" = upload ]; then
    key=$(cn_tos_upload_key)
    curl_args+=(-X PUT -H "Content-Length: $size" --upload-file - "https://$host/$key")
  else
    curl_args+=(--range "0-$((size - 1))" "https://$host/download/test")
  fi

  # 连接级 TCP_INFO：优先 preload，否则 ss 轮询
  : > "$tcpinfo"
  CN_TCPINFO_MODE=none
  if [ -r "$CN_TCPINFO_PRELOAD" ]; then
    CN_TCPINFO_MODE=getsockopt
    curl_args=(env "LD_PRELOAD=${CN_TCPINFO_PRELOAD}${LD_PRELOAD:+:$LD_PRELOAD}"
               "SBQUALITY_TCP_INFO_FILE=$tcpinfo" "SBQUALITY_TCP_INFO_TARGET=$server_ip"
               "${curl_args[@]}")
  elif cn_tcp_info_ss_monitor_start "$server_ip" "$tcpinfo"; then
    CN_TCPINFO_MODE=ss
  fi
  cn_retrans_trace_start "$out" && trace_ok=1

  if [ "$probe_type" = upload ]; then
    cn_zero_stream "$size" | "${curl_args[@]}" > "$raw" 2>"${out}.err"
    rc=${PIPESTATUS[1]}
  else
    "${curl_args[@]}" > "$raw" 2>"${out}.err"
    rc=$?
  fi
  cn_tcp_info_monitor_stop
  [ "$trace_ok" -eq 1 ] && cn_retrans_trace_stop
  [ "$probe_type" = upload ] && cn_tos_delete_object "$host" "$server_ip" "$key"

  local http bytes_dl speed_dl bytes_ul speed_ul t_connect t_tls t_total
  IFS='|' read -r http bytes_dl speed_dl bytes_ul speed_ul t_connect t_tls t_total < "$raw" 2>/dev/null || true

  local rate_bps
  if [ "$probe_type" = upload ]; then rate_bps="${speed_ul:-0}"; else rate_bps="${speed_dl:-0}"; fi
  local mbps
  mbps=$(awk -v b="$rate_bps" 'BEGIN {
    if (b !~ /^[0-9]+([.][0-9]+)?$/ || b <= 0) print "failed"; else printf "%.2f", b * 8 / 1000000 }')

  local connect_ms tls_ms
  connect_ms=$(awk -v t="${t_connect:-}" 'BEGIN { if (t ~ /^[0-9.]+$/) printf "%.1f", t * 1000; else print "-" }')
  tls_ms=$(awk -v a="${t_connect:-}" -v b="${t_tls:-}" 'BEGIN {
    if (a ~ /^[0-9.]+$/ && b ~ /^[0-9.]+$/) { d = (b - a) * 1000; if (d < 0) d = 0; printf "%.1f", d }
    else print "-" }')

  # 重传率：TCP_INFO 是分母来源；eBPF 唯一段数可用时优先展示
  local ti_retrans ti_data ti_segs ti_bytes ratio="-" source="tcp_info_unavailable" denom=0
  if [ -s "$tcpinfo" ]; then
    IFS='|' read -r ti_retrans ti_data ti_segs ti_bytes < "$tcpinfo" || true
    if [[ "$ti_retrans" =~ ^[0-9]+$ ]] && [[ "$ti_data" =~ ^[0-9]+$ ]]; then
      [ "$ti_data" -gt 0 ] && denom="$ti_data" || denom="${ti_segs:-0}"
      ratio=$(awk -v r="$ti_retrans" -v p="$denom" 'BEGIN {
        if (p <= 0) { print "-"; exit }
        v = r / p * 100; if (v < 0) v = 0; if (v > 100) v = 100; printf "%.2f%%", v }')
      source="tcp_info_${CN_TCPINFO_MODE}"

      if [ "$trace_ok" -eq 1 ]; then
        local uniq
        uniq=$(cn_retrans_trace_unique "$CN_TRACE_FILE" "$server_ip" 2>/dev/null || true)
        # 内核/BTF 布局不匹配时 seq 会读成 0，绝不能让这个假零盖掉 TCP_INFO
        if [[ "$uniq" =~ ^[0-9]+$ ]] && [ "$uniq" -gt 0 ] && [ "$uniq" -le "$ti_retrans" ]; then
          ratio=$(awk -v u="$uniq" -v p="$denom" 'BEGIN {
            if (p <= 0) { print "-"; exit }
            v = u / p * 100; if (v < 0) v = 0; if (v > 100) v = 100; printf "%.2f%%", v }')
          source="ebpf_${CN_TRACE_KEY}"
        fi
      fi
    fi
  fi

  rm -f -- "$raw" "$tcpinfo" "${tcpinfo}.tmp" "${out}.err" 2>/dev/null
  # 单独判空：CN_TRACE_FILE 为空时拼出来的 ".err" 会指向当前目录里的文件
  if [ -n "${CN_TRACE_FILE:-}" ]; then
    rm -f -- "$CN_TRACE_FILE" "${CN_TRACE_FILE}.err" 2>/dev/null
  fi
  printf '%s|%s|%s|%s|%s' "$mbps" "$connect_ms" "$tls_ms" "$ratio" "$source"
}

cn_load_tos_nodes() {
  local tmp url sep line type family prov isp host ip port target rest region
  sb_has curl || return 1
  tmp=$(mktemp)
  sep="?"
  [[ "$CN_GET_NODES_URL" == *"?"* ]] && sep="&"
  url="${CN_GET_NODES_URL}${sep}format=tsv&scope=tos"
  if ! curl -fsSL --connect-timeout 5 --max-time 30 "$url" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; return 1
  fi
  CN_TOS_NODES=()
  while IFS= read -r line; do
    line=${line//$'\t'/'|'}
    IFS='|' read -r type family prov isp host ip port target rest <<< "$line"
    [ "$type" = type ] && continue
    [ "$family" = 4 ] || continue
    [ -n "$ip" ] || continue
    case "$type" in tos|tosutil|speedtest) ;; *) continue ;; esac
    region="cn-beijing"
    case "$target" in
      *cn-shanghai*)  region="cn-shanghai" ;;
      *cn-guangzhou*) region="cn-guangzhou" ;;
    esac
    CN_TOS_NODES+=("${prov:-北京}|${isp:-未知}|$ip|$region")
  done < "$tmp"
  rm -f "$tmp"
  [ "${#CN_TOS_NODES[@]}" -gt 0 ]
}

cn_run_speedtest() {
  if ! cn_load_tos_nodes; then
    sb_skip "cn.speedtest" "无法获取三网 TOS 测速节点"
    return 0
  fi
  if [ ! -r "$CN_TCPINFO_PRELOAD" ] && ! sb_has ss; then
    sb_warn "缺少 TCP_INFO preload 库与 ss，测速将不带重传率"
  fi

  local entry prov isp ip region i=0 total=$(( ${#CN_TOS_NODES[@]} * 2 ))
  local dl ul dl_mbps dl_conn dl_tls dl_ratio dl_src ul_mbps _c _t ul_ratio ul_src

  for entry in "${CN_TOS_NODES[@]}"; do
    IFS='|' read -r prov isp ip region <<< "$entry"

    i=$((i + 1))
    sb_progress "$i" "$total" "单线程测速 ${prov}${isp} 下载"
    dl=$(cn_speedtest_probe download "$ip" "$region" "${CN_RESULT_DIR}/st_dl_${i}")
    IFS='|' read -r dl_mbps dl_conn dl_tls dl_ratio dl_src <<< "$dl"

    i=$((i + 1))
    sb_progress "$i" "$total" "单线程测速 ${prov}${isp} 上传"
    ul=$(cn_speedtest_probe upload "$ip" "$region" "${CN_RESULT_DIR}/st_ul_${i}")
    IFS='|' read -r ul_mbps _c _t ul_ratio ul_src <<< "$ul"

    sb_row_add cn.speedtest "$prov" "$isp" \
      "$([ "$dl_mbps" = failed ] && echo 失败 || echo "$dl_mbps Mbps")" \
      "$([ "$ul_mbps" = failed ] && echo 失败 || echo "$ul_mbps Mbps")" \
      "${dl_conn} ms" "$dl_ratio" "$ul_ratio" "$dl_src"
  done
  sb_progress_done

  # Apple CDN 作为国际对照，无需凭据
  local result
  sb_spin_msg "单线程测速 Apple CDN"
  result=$(curl -4 -sS -o /dev/null --connect-timeout 5 --max-time 12 \
    -w '%{speed_download}|%{time_connect}' "$CN_APPLE_DOWNLOAD_URL" 2>/dev/null) || result=""
  sb_progress_done
  if [ -n "$result" ]; then
    local sp tc
    IFS='|' read -r sp tc <<< "$result"
    sb_row_add cn.speedtest "Apple CDN" "国际" \
      "$(awk -v b="$sp" 'BEGIN { printf "%.2f Mbps", b * 8 / 1000000 }')" \
      "未测" "$(awk -v t="$tc" 'BEGIN { printf "%.1f ms", t * 1000 }')" "-" "-" "-"
  fi
}

# 消化入口透传过来的参数（--province X / -bj 式简写 / --debug）
cn_apply_args() {
  local -a args=("$@")
  local i=0 arg
  while [ "$i" -lt "${#args[@]}" ]; do
    arg="${args[i]}"
    case "$arg" in
      --province)
        i=$((i + 1))
        cn_add_province_filter "${args[i]:-}" || sb_warn "不支持的省份代码：${args[i]:-}"
        ;;
      --debug) ;;   # 已由 SB_DEBUG 处理
      --route-protocol)
        i=$((i + 1))
        case "${args[i]:-}" in
          tcp|udp|both) CN_ROUTE_PROTOCOL="${args[i]}" ;;
          *) sb_warn "--route-protocol 只支持 tcp / udp / both，已忽略" ;;
        esac
        ;;
      -*)
        cn_add_province_filter "$arg" || sb_warn "不支持的参数：$arg"
        ;;
    esac
    i=$((i + 1))
  done
  [ -n "$CN_SELECTED_PROVINCES" ] && sb_info "省份筛选：${CN_SELECTED_PROVINCES//|/、}"
  return 0
}

# ===================== 入口 =====================
cn_run() {
  local can_probe=0 route_file4="" route_file6="" edu_file4="" edu_file6="" large_route_file=""
  # 循环变量在函数顶层声明：下面有多处 while read 用到它们，而 bash 的 local
  # 是函数作用域，若只在某个分支里声明，分支未执行时就会写到全局变量上
  local fam file status prov isp protocol host label

  if ! sb_has curl; then
    sb_skip "cn" "缺少 curl"
    return 0
  fi
  if [ "${SB_IPV4_OK:-0}" -eq 0 ] && [ "${SB_IPV6_OK:-0}" -eq 0 ]; then
    sb_skip "cn" "无网络连接"
    return 0
  fi

  cn_init
  [ "${#SB_CN_EXTRA_ARGS[@]}" -gt 0 ] && cn_apply_args "${SB_CN_EXTRA_ARGS[@]}"

  # 节点列表拉取失败只跳过本模块，不能终止整个评测
  if ! cn_load_nodes all; then
    sb_skip "cn" "${CN_NODES_ERROR:-无法获取三网节点列表}"
    return 0
  fi

  if ! sb_require traceroute; then
    sb_skip "cn.route" "缺少 traceroute，无法做回程线路识别"
  else
    # IPv4/IPv6 的线路标签必须分文件存：同一个省份+运营商在两个协议下线路可能不同，
    # 合在一起查会让 IPv6 的行拿到 IPv4 的标签。
    if [ "${SB_IPV4_OK:-0}" -eq 1 ]; then
      route_file4=$(mktemp)
      sb_info "正在识别 IPv4 三网回程线路（$(cn_node_count cdn4) 个节点）"
      cn_collect_routes 4 cdn4 "$route_file4" route4
    fi
    if [ "${SB_IPV6_OK:-0}" -eq 1 ]; then
      route_file6=$(mktemp)
      sb_info "正在识别 IPv6 三网回程线路（$(cn_node_count cdn6) 个节点）"
      cn_collect_routes 6 cdn6 "$route_file6" route6
    fi
    for fam in 4 6; do
      [ "$fam" = 4 ] && file="$route_file4" || file="$route_file6"
      [ -n "$file" ] && [ -f "$file" ] || continue
      while IFS='|' read -r status prov isp protocol host label; do
        [ -n "$prov" ] || continue
        [ "$status" != OK ] && label="failed"
        sb_row_add cn.route "IPv${fam}/$(printf '%s' "$protocol" | tr '[:lower:]' '[:upper:]')" \
          "$prov" "$isp" "${label:-Hidden}" "$host"
      done < "$file"
    done

    # 教育网出国路径与三网不同，用专用判定单独跑一遍
    if [ "${SB_PROFILE:-quick}" = all ]; then
      if [ "${SB_IPV4_OK:-0}" -eq 1 ] && [ "$(cn_node_count cernet)" -gt 0 ]; then
        edu_file4=$(mktemp)
        sb_info "正在识别 CERNET 回程线路（$(cn_node_count cernet) 个节点）"
        cn_collect_routes 4 cernet "$edu_file4" edu4 education
      fi
      if [ "${SB_IPV6_OK:-0}" -eq 1 ] && [ "$(cn_node_count cernet2)" -gt 0 ]; then
        edu_file6=$(mktemp)
        sb_info "正在识别 CERNET2 回程线路（$(cn_node_count cernet2) 个节点）"
        cn_collect_routes 6 cernet2 "$edu_file6" edu6 education
      fi
      for fam in 4 6; do
        [ "$fam" = 4 ] && file="$edu_file4" || file="$edu_file6"
        [ -n "$file" ] && [ -f "$file" ] || continue
        while IFS='|' read -r status prov isp protocol host label; do
          [ -n "$prov" ] || continue
          [ "$status" != OK ] && label="failed"
          sb_row_add cn.route "CERNET$([ "$fam" = 6 ] && echo 2)/IPv${fam}" \
            "$prov" "$isp" "${label:-Hidden}" "$host"
        done < "$file"
      done
    fi
    sb_status_set cn.route ok ""
  fi

  # ---- 丢包探测：需要裸 socket ----
  if sb_has_raw_socket; then
    if sb_require nping; then
      can_probe=1
    else
      sb_skip "cn.probe" "缺少 nping（随 nmap 安装）"
    fi
  elif [ "${SB_PROFILE:-quick}" = all ]; then
    sb_skip "cn.probe" "需要 root 权限发送裸 TCP SYN 包；回程线路识别已降级为 traceroute 模式"
  fi

  if [ "$can_probe" -eq 1 ] && [ "${SB_PROFILE:-quick}" = all ]; then
    # 预检放在路由识别之后：预检本身会产生探测流量，先跑会干扰 traceroute 的响应
    if [ "${SB_IPV6_OK:-0}" -eq 1 ]; then
      cn_ipv6_nping_precheck
      [ "$CN_IPV6_FORCE_L2" -eq 1 ] && sb_info "IPv6 三层发包无响应，已切换到二层发包"
    fi

    if [ "${SB_IPV4_OK:-0}" -eq 1 ]; then
      CN_ROUTE_LABEL_FILE="$route_file4"
      cn_run_probe_group cdn4 4 cn.cdn4

      # IPv4 大包回程：先用 Cloudflare 预检出口是否拦大包
      if cn_large_packet_precheck; then
        # 大包可能走和小包不同的路径（这正是本项测试的意义），
        # 所以必须用 1200B 单独跑一遍 traceroute，不能复用小包的线路标签。
        if sb_has traceroute; then
          large_route_file=$(mktemp)
          sb_info "正在识别 IPv4 大包回程线路（1200B）"
          cn_collect_routes 4 cdn4 "$large_route_file" large_route normal 1200
          CN_ROUTE_LABEL_FILE="$large_route_file"
        else
          CN_ROUTE_LABEL_FILE=""
        fi
        cn_run_probe_group large4 4 cn.large4 large
        if [ -n "$large_route_file" ] && [ -f "$large_route_file" ]; then
          while IFS='|' read -r status prov isp protocol host label; do
            [ -n "$prov" ] || continue
            [ "$status" != OK ] && label="failed"
            sb_row_add cn.route "IPv4大包/$(printf '%s' "$protocol" | tr '[:lower:]' '[:upper:]')" \
              "$prov" "$isp" "${label:-Hidden}" "$host"
          done < "$large_route_file"
        fi
      else
        sb_skip "cn.large4" "出口对 1200B 大包有拦截或限速（预检丢包 ${CN_LARGE_PRECHECK_LOSS}%），大包回程无意义"
      fi

      CN_ROUTE_LABEL_FILE="$edu_file4"
      cn_run_probe_group cernet 4 cn.cernet
    fi
    if [ "${SB_IPV6_OK:-0}" -eq 1 ]; then
      CN_ROUTE_LABEL_FILE="$route_file6"
      cn_run_probe_group cdn6 6 cn.cdn6
      CN_ROUTE_LABEL_FILE="$edu_file6"
      cn_run_probe_group cernet2 6 cn.cernet2
    fi
    sb_status_set cn.probe ok ""
  elif [ "$can_probe" -eq 1 ]; then
    sb_skip "cn.probe" "快速档不运行丢包探测（使用 -a 开启）"
  fi

  # ---- 国际互联与单线程测速：仅全量档 ----
  if [ "${SB_PROFILE:-quick}" = all ]; then
    sb_info "正在检测国际互联"
    cn_run_international
    sb_info "正在进行单线程测速"
    cn_run_speedtest
  else
    sb_skip "cn.international" "快速档不运行国际互联（使用 -a 开启）"
    sb_skip "cn.speedtest" "快速档不运行单线程测速（使用 -a 开启）"
  fi

  [ -n "$route_file4" ] && rm -f "$route_file4"
  [ -n "$route_file6" ] && rm -f "$route_file6"
  [ -n "$edu_file4" ] && rm -f "$edu_file4"
  [ -n "$edu_file6" ] && rm -f "$edu_file6"
  [ -n "$large_route_file" ] && rm -f "$large_route_file"
  sb_status_set cn ok ""
  sb_ok "中国三网检测完成"
}
