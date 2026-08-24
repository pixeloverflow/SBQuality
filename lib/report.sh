#!/usr/bin/env bash
#
# SBQuailty - lib/report.sh
# 从 $SB_RUN_DIR 读取全部结果，渲染 TUI / 纯文本 / JSON / HTML / Markdown。
#
# 各模块只负责写入结果存储，不打印最终报告；本文件是唯一的呈现层，
# 以保证四种输出的数据严格一致。

# ===================== 表结构约定 =====================
# rows/disk.fio.tsv        bs  read_speed  read_iops  write_speed  write_iops  total_speed  total_iops \
#                          raw_r  raw_riops  raw_w  raw_wiops  raw_rw  raw_rwiops
# rows/disk.dd.tsv         direction  t1  t2  t3  avg  unit
# rows/cpu.geekbench.tsv   version  single  multi  url
# rows/bandwidth.iperf.tsv mode  provider  loc  send  recv  latency
# rows/ip.<v>.info.tsv     label  value
# rows/ip.<v>.type.tsv     source  usage  company
# rows/ip.<v>.score.tsv    source  score  risk
# rows/ip.<v>.factor.tsv   label  v1 v2 v3 v4 v5 ...        （各库的判定值）
# rows/ip.<v>.media.tsv    platform  result  region
# rows/ip.<v>.mail.tsv     item  result
# rows/cn.<group>.tsv      prov  isp  status  sent  received  loss  latency  route
# rows/cn.intl.tsv         target  proto  ip  status  connect_ms  tls_ms  note
# rows/cn.intl_iperf.tsv   region  node  proto  direction  status  rtt  retrans
# rows/cn.speedtest.tsv    region  isp  down  up  latency  dl_retrans  ul_retrans  source
# rows/cn.route.tsv        proto  prov  isp  label  host

SB_REPORT_WIDTH=76

# ===================== 通用绘制 =====================
report_hr() {
  printf '  %s%s%s\n' "$SB_DIM" "$(printf '%*s' "$SB_REPORT_WIDTH" '' | tr ' ' '-')" "$SB_NC"
}

report_section() {
  echo
  printf '  %s%s%s\n' "$SB_CYAN$SB_BOLD" "$1" "$SB_NC"
  report_hr
}

# report_kv_line <标签> <值> [标签宽度]
report_kv_line() {
  local label="$1" value="$2" w="${3:-12}"
  printf '  %s%s%s: %s\n' "$SB_WHITE" "$(sb_pad_right "$label" "$w")" "$SB_NC" "$value"
}

# report_table <表名> <表头1|表头2|...> <宽度1|宽度2|...> [对齐1|对齐2|...]
# 对齐: l(左) r(右) c(中)，默认全左对齐
report_table() {
  local table="$1" headers="$2" widths="$3" aligns="${4:-}"
  sb_table_exists "$table" || return 0

  local -a H W A
  IFS='|' read -r -a H <<< "$headers"
  IFS='|' read -r -a W <<< "$widths"
  if [ -n "$aligns" ]; then IFS='|' read -r -a A <<< "$aligns"; fi

  local i line=""
  for i in "${!H[@]}"; do
    line+="$(sb_pad_right "${H[i]}" "${W[i]}")  "
  done
  printf '  %s%s%s\n' "$SB_DIM" "${line%  }" "$SB_NC"

  line=""
  for i in "${!H[@]}"; do
    line+="$(printf '%*s' "${W[i]}" '' | tr ' ' '-')  "
  done
  printf '  %s%s%s\n' "$SB_DIM" "${line%  }" "$SB_NC"

  local row cell a
  while IFS= read -r row; do
    sb_split_tsv "$row"
    line=""
    for i in "${!H[@]}"; do
      cell="${SB_FIELDS[i]:-}"
      a="${A[i]:-l}"
      case "$a" in
        r) line+="$(sb_pad_left "$cell" "${W[i]}")  " ;;
        c) line+="$(sb_pad_center "$cell" "${W[i]}")  " ;;
        *) line+="$(sb_pad_right "$cell" "${W[i]}")  " ;;
      esac
    done
    printf '  %s\n' "${line%  }"
  done < <(sb_table_read "$table")
}

# ===================== TUI 各分区 =====================
report_tui_system() {
  sb_kv_has system.cpu.model || sb_kv_has system.distro || return 0
  report_section "系统信息"
  report_kv_line "处理器"   "$(sb_kv_get system.cpu.model)"
  report_kv_line "核心/频率" "$(sb_kv_get system.cpu.cores) 核 @ $(sb_kv_get system.cpu.freq)"
  report_kv_line "AES-NI"   "$(sb_kv_get system.cpu.aes)"
  report_kv_line "虚拟化"   "$(sb_kv_get system.cpu.virt)"
  report_kv_line "内存"     "$(sb_kv_get system.mem.ram)"
  report_kv_line "交换分区" "$(sb_kv_get system.mem.swap)"
  report_kv_line "磁盘容量" "$(sb_kv_get system.mem.disk)"
  report_kv_line "发行版"   "$(sb_kv_get system.distro)"
  report_kv_line "内核"     "$(sb_kv_get system.kernel)"
  report_kv_line "架构"     "$(sb_kv_get system.arch)"
  report_kv_line "虚拟化类型" "$(sb_kv_get system.vm_type)"
  report_kv_line "运行时间" "$(sb_kv_get system.uptime)"
}

report_tui_disk() {
  local method
  method=$(sb_kv_get disk.method)
  [ -z "$method" ] && return 0
  if [ "$method" = fio ]; then
    report_section "磁盘性能 — fio 随机读写 50/50（分区 $(sb_kv_get disk.partition)）"
    report_table disk.fio \
      "块大小|读取|读 IOPS|写入|写 IOPS|合计|合计 IOPS" \
      "8|12|10|12|10|12|10" \
      "l|r|r|r|r|r|r"
  else
    report_section "磁盘性能 — dd 顺序读写（fio 不可用，回退）"
    # 单位必须一起显示：平均值可能是 MB/s 也可能是 GB/s，只给数字没有意义
    report_table disk.dd \
      "方向|测试 1|测试 2|测试 3|平均|单位" \
      "6|12|12|12|10|6" \
      "l|r|r|r|r|l"
  fi
}

report_tui_cpu() {
  sb_table_exists cpu.geekbench || return 0
  report_section "CPU 跑分 — Geekbench"
  report_table cpu.geekbench \
    "版本|单核|多核|详细结果" \
    "6|8|8|44" \
    "l|r|r|l"
}

report_tui_bandwidth() {
  sb_table_exists bandwidth.iperf || return 0
  report_section "国际带宽 — iperf3"
  report_table bandwidth.iperf \
    "协议|提供商|位置（链路）|上传|下载|延迟" \
    "6|10|26|12|12|10" \
    "l|l|l|r|r|r"
}

report_tui_ip_one() {
  local v="$1" title="$2"
  sb_table_exists "ip.${v}.info" || return 0
  report_section "$title"
  local row
  while IFS= read -r row; do
    sb_split_tsv "$row"
    report_kv_line "${SB_FIELDS[0]}" "${SB_FIELDS[1]:-}" 14
  done < <(sb_table_read "ip.${v}.info")

  if sb_table_exists "ip.${v}.type"; then
    echo
    printf '  %s%s%s\n' "$SB_WHITE" "IP 类型" "$SB_NC"
    report_table "ip.${v}.type" "数据库|使用类型|公司类型" "14|22|22" "l|l|l"
  fi
  if sb_table_exists "ip.${v}.score"; then
    echo
    printf '  %s%s%s\n' "$SB_WHITE" "风险评分" "$SB_NC"
    report_table "ip.${v}.score" "数据库|分值|风险等级" "14|10|20" "l|r|l"
  fi
  if sb_table_exists "ip.${v}.factor"; then
    echo
    printf '  %s%s%s\n' "$SB_WHITE" "风险因子" "$SB_NC"
    report_table "ip.${v}.factor" "因子|判定" "18|48" "l|l"
  fi
  if sb_table_exists "ip.${v}.media"; then
    echo
    printf '  %s%s%s\n' "$SB_WHITE" "流媒体与 AI 解锁" "$SB_NC"
    report_table "ip.${v}.media" "平台|结果|区域" "16|24|14" "l|l|l"
  fi
  if sb_table_exists "ip.${v}.mail"; then
    echo
    printf '  %s%s%s\n' "$SB_WHITE" "邮局与黑名单" "$SB_NC"
    report_table "ip.${v}.mail" "检测项|结果" "22|44" "l|l"
  fi
}

report_tui_ip() {
  report_tui_ip_one v4 "IP 质量 — IPv4 $(sb_kv_get ip.v4.display)"
  report_tui_ip_one v6 "IP 质量 — IPv6 $(sb_kv_get ip.v6.display)"
}

report_tui_cn() {
  local g title
  for g in cdn4:"三网回程 — IPv4" large4:"三网回程 — IPv4 大包" cdn6:"三网回程 — IPv6" \
           cernet:"教育网 CERNET — IPv4" cernet2:"教育网 CERNET2 — IPv6"; do
    local key="${g%%:*}"
    title="${g#*:}"
    sb_table_exists "cn.${key}" || continue
    report_section "$title"
    report_table "cn.${key}" \
      "省份|运营商|状态|发送|接收|丢包率|平均延迟|回程线路" \
      "8|8|6|6|6|8|10|18" \
      "l|l|l|r|r|r|r|l"
  done

  if sb_table_exists cn.route; then
    report_section "回程线路识别"
    report_table cn.route "协议|省份|运营商|线路|节点域名" "10|8|8|22|22" "l|l|l|l|l"
  fi
  if sb_table_exists cn.intl; then
    report_section "国际互联"
    report_table cn.intl "目标|协议|IP|状态|连接耗时|TLS 握手|备注" \
      "18|6|20|8|10|10|18" "l|l|l|l|r|r|l"
  fi
  if sb_table_exists cn.intl_iperf; then
    report_section "国际互联 — iPerf3 双向"
    report_table cn.intl_iperf "区域|节点|协议|方向|状态|TCP RTT|重传" \
      "8|22|6|6|6|12|8" "l|l|l|l|l|r|r"
  fi
  if sb_table_exists cn.speedtest; then
    report_section "单线程测速"
    report_table cn.speedtest "地区|运营商|下载|上传|连接延迟|下载重传|上传重传|重传来源" \
      "10|8|14|14|10|10|10|16" "l|l|r|r|r|r|r|l"
  fi
}

report_tui_skipped() {
  local has=0 line
  while IFS=$'\t' read -r module state reason; do
    [ "$state" = ok ] && continue
    if [ "$has" -eq 0 ]; then
      report_section "已跳过 / 失败的测试项"
      has=1
    fi
    local mark="${SB_YELLOW}跳过${SB_NC}"
    [ "$state" = fail ] && mark="${SB_RED}失败${SB_NC}"
    printf '  %s  %s  %s%s%s\n' "$(sb_pad_right "$module" 22)" "$mark" "$SB_DIM" "$reason" "$SB_NC"
  done < <(sb_status_read)
  return 0
}

report_render_tui() {
  echo
  report_hr
  printf '  %s%s%s\n' "$SB_BOLD" "SBQuailty 评测报告  $(sb_kv_get meta.time)" "$SB_NC"
  report_hr

  report_tui_system
  report_tui_disk
  report_tui_cpu
  report_tui_ip
  report_tui_bandwidth
  report_tui_cn
  report_tui_skipped
  echo
}

report_write_text() {
  local out="$1"
  report_render_tui | sed $'s/\033\\[[0-9;]*[a-zA-Z]//g' > "$out" 2>/dev/null && \
    sb_ok "纯文本报告已写入 $out" || sb_warn "写入 $out 失败"
}

# ===================== JSON =====================
# 把 kv 中某前缀下的键渲染为一个 JSON 对象；键名去掉前缀，点号保持为扁平字符串键。
report_json_obj_from_prefix() {
  local prefix="$1" first=1 key value short
  printf '{'
  while IFS=$'\t' read -r key value; do
    short="${key#"$prefix"}"
    [ -z "$short" ] && continue
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '"%s":%s' "$(sb_json_escape "$short")" "$(sb_json_value "$value")"
  done < <(sb_kv_prefix "$prefix")
  printf '}'
}

# report_json_rows <表名> <字段名1,字段名2,...>
report_json_rows() {
  local table="$1" fields="$2"
  local -a NAMES
  IFS=',' read -r -a NAMES <<< "$fields"
  printf '['
  local first=1 i row
  while IFS= read -r row; do
    sb_split_tsv "$row"
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{'
    for i in "${!NAMES[@]}"; do
      [ "$i" -eq 0 ] || printf ','
      printf '"%s":%s' "${NAMES[i]}" "$(sb_json_value "${SB_FIELDS[i]:-}")"
    done
    printf '}'
  done < <(sb_table_read "$table")
  printf ']'
}

report_json_status() {
  local first=1
  printf '['
  while IFS=$'\t' read -r module state reason; do
    [ "$state" = ok ] && continue
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"module":%s,"state":%s,"reason":%s}' \
      "$(sb_json_value "$module")" "$(sb_json_value "$state")" "$(sb_json_value "$reason")"
  done < <(sb_status_read)
  printf ']'
}

report_json_ip_one() {
  local v="$1"
  printf '{'
  printf '"address":%s,' "$(sb_json_value "$(sb_kv_get "ip.${v}.display")")"
  printf '"info":%s,'    "$(report_json_rows "ip.${v}.info" 'label,value')"
  printf '"type":%s,'    "$(report_json_rows "ip.${v}.type" 'source,usage,company')"
  printf '"score":%s,'   "$(report_json_rows "ip.${v}.score" 'source,score,risk')"
  printf '"factor":%s,'  "$(report_json_rows "ip.${v}.factor" 'label,verdict')"
  printf '"media":%s,'   "$(report_json_rows "ip.${v}.media" 'platform,result,region')"
  printf '"mail":%s'     "$(report_json_rows "ip.${v}.mail" 'item,result')"
  printf '}'
}

report_build_json() {
  printf '{'
  printf '"version":%s,'  "$(sb_json_value "$(sb_kv_get meta.version)")"
  printf '"time":%s,'     "$(sb_json_value "$(sb_kv_get meta.time_iso)")"
  printf '"profile":%s,'  "$(sb_json_value "$(sb_kv_get meta.profile)")"
  printf '"privilege":%s,' "$(sb_json_value "$(sb_kv_get meta.privilege)")"
  printf '"elapsed":%s,'  "$(sb_json_value "$(sb_kv_get meta.elapsed 0)")"

  # 协议栈可用性单独给出：消费方要能区分「这台机器没有 IPv6」和「IPv6 测了但失败」
  printf '"net":{"ipv4":%s,"ipv6":%s},' \
    "$([ "$(sb_kv_get meta.ipv4_online 0)" = 1 ] && echo true || echo false)" \
    "$([ "$(sb_kv_get meta.ipv6_online 0)" = 1 ] && echo true || echo false)"

  printf '"system":%s,' "$(report_json_obj_from_prefix 'system.')"

  printf '"disk":{'
  printf '"method":%s,'    "$(sb_json_value "$(sb_kv_get disk.method)")"
  printf '"partition":%s,' "$(sb_json_value "$(sb_kv_get disk.partition)")"
  printf '"fio":%s,' "$(report_json_rows disk.fio \
    'bs,read_speed,read_iops,write_speed,write_iops,total_speed,total_iops,raw_read_kibps,raw_read_iops,raw_write_kibps,raw_write_iops,raw_total_kibps,raw_total_iops')"
  printf '"dd":%s'   "$(report_json_rows disk.dd 'direction,test1,test2,test3,avg,unit')"
  printf '},'

  printf '"cpu_bench":{"geekbench":%s},' "$(report_json_rows cpu.geekbench 'version,single,multi,url')"

  printf '"bandwidth":{"iperf":%s},' "$(report_json_rows bandwidth.iperf 'mode,provider,location,send,recv,latency')"

  printf '"ip":{"v4":%s,"v6":%s},' "$(report_json_ip_one v4)" "$(report_json_ip_one v6)"

  local cn_row_fields='province,isp,status,sent,received,loss,latency,route'
  printf '"cn_network":{'
  printf '"cdn4":%s,'    "$(report_json_rows cn.cdn4 "$cn_row_fields")"
  printf '"cdn6":%s,'    "$(report_json_rows cn.cdn6 "$cn_row_fields")"
  printf '"large4":%s,'  "$(report_json_rows cn.large4 "$cn_row_fields")"
  printf '"cernet":%s,'  "$(report_json_rows cn.cernet "$cn_row_fields")"
  printf '"cernet2":%s,' "$(report_json_rows cn.cernet2 "$cn_row_fields")"
  printf '"routes":%s,'  "$(report_json_rows cn.route 'proto,province,isp,label,host')"
  printf '"international":%s,' "$(report_json_rows cn.intl 'target,proto,ip,status,connect_ms,tls_ms,note')"
  printf '"international_iperf":%s,' "$(report_json_rows cn.intl_iperf 'region,node,proto,direction,status,rtt,retransmits')"
  printf '"speedtest":%s'      "$(report_json_rows cn.speedtest 'region,isp,download,upload,connect_latency,download_retrans,upload_retrans,retrans_source')"
  printf '},'

  printf '"skipped":%s' "$(report_json_status)"
  printf '}\n'
}

report_write_json() {
  local out="$1"
  if report_build_json > "$out" 2>/dev/null; then
    if sb_has jq && ! jq empty "$out" >/dev/null 2>&1; then
      sb_warn "生成的 JSON 未通过 jq 校验：$out"
    fi
    sb_ok "JSON 报告已写入 $out"
  else
    sb_warn "写入 $out 失败"
  fi
}

# ===================== Markdown =====================
report_md_table() {
  local table="$1" headers="$2"
  sb_table_exists "$table" || return 0
  local -a H
  IFS='|' read -r -a H <<< "$headers"
  local i line="|" row cell
  for i in "${!H[@]}"; do line+=" ${H[i]} |"; done
  echo "$line"
  line="|"
  for i in "${!H[@]}"; do line+="---|"; done
  echo "$line"
  while IFS= read -r row; do
    sb_split_tsv "$row"
    line="|"
    for i in "${!H[@]}"; do
      cell=$(sb_strip_ansi "${SB_FIELDS[i]:-}")
      cell=${cell//|/\\|}
      line+=" ${cell} |"
    done
    echo "$line"
  done < <(sb_table_read "$table")
  echo
}

report_md_kv() {
  local prefix="$1" key value
  echo "| 项目 | 值 |"
  echo "|---|---|"
  while IFS=$'\t' read -r key value; do
    echo "| ${key#"$prefix"} | $(sb_strip_ansi "$value") |"
  done < <(sb_kv_prefix "$prefix")
  echo
}

report_build_md() {
  echo "# SBQuailty 评测报告"
  echo
  echo "- 生成时间：$(sb_kv_get meta.time)"
  echo "- 运行档位：$(sb_kv_get meta.profile)"
  echo "- 总耗时：$(sb_elapsed_text "$(sb_kv_get meta.elapsed 0)")"
  echo

  if sb_kv_has system.cpu.model; then
    echo "## 系统信息"; echo
    report_md_kv 'system.'
  fi
  if sb_table_exists disk.fio; then
    echo "## 磁盘性能（fio 随机读写 50/50）"; echo
    report_md_table disk.fio "块大小|读取|读 IOPS|写入|写 IOPS|合计|合计 IOPS"
  elif sb_table_exists disk.dd; then
    echo "## 磁盘性能（dd 顺序读写）"; echo
    report_md_table disk.dd "方向|测试 1|测试 2|测试 3|平均|单位"
  fi
  if sb_table_exists cpu.geekbench; then
    echo "## CPU 跑分"; echo
    report_md_table cpu.geekbench "版本|单核|多核|详细结果"
  fi
  local v
  for v in v4 v6; do
    sb_table_exists "ip.${v}.info" || continue
    echo "## IP 质量 — ${v^^}"; echo
    report_md_table "ip.${v}.info"   "项目|值"
    report_md_table "ip.${v}.type"   "数据库|使用类型|公司类型"
    report_md_table "ip.${v}.score"  "数据库|分值|风险等级"
    report_md_table "ip.${v}.factor" "因子|判定"
    report_md_table "ip.${v}.media"  "平台|结果|区域"
    report_md_table "ip.${v}.mail"   "检测项|结果"
  done
  if sb_table_exists bandwidth.iperf; then
    echo "## 国际带宽（iperf3）"; echo
    report_md_table bandwidth.iperf "协议|提供商|位置|上传|下载|延迟"
  fi
  local g key title
  for g in cdn4:"三网回程 IPv4" large4:"三网回程 IPv4 大包" cdn6:"三网回程 IPv6" \
           cernet:"教育网 CERNET" cernet2:"教育网 CERNET2"; do
    key="${g%%:*}"; title="${g#*:}"
    sb_table_exists "cn.${key}" || continue
    echo "## $title"; echo
    report_md_table "cn.${key}" "省份|运营商|状态|发送|接收|丢包率|平均延迟|回程线路"
  done
  if sb_table_exists cn.route; then
    echo "## 回程线路识别"; echo
    report_md_table cn.route "协议|省份|运营商|线路|节点域名"
  fi
  if sb_table_exists cn.intl; then
    echo "## 国际互联"; echo
    report_md_table cn.intl "目标|协议|IP|状态|连接耗时|TLS 握手|备注"
  fi
  if sb_table_exists cn.intl_iperf; then
    echo "## 国际互联 — iPerf3 双向"; echo
    report_md_table cn.intl_iperf "区域|节点|协议|方向|状态|TCP RTT|重传"
  fi
  if sb_table_exists cn.speedtest; then
    echo "## 单线程测速"; echo
    report_md_table cn.speedtest "地区|运营商|下载|上传|连接延迟|下载重传|上传重传|重传来源"
  fi

  local has_skip=0
  while IFS=$'\t' read -r module state reason; do
    [ "$state" = ok ] && continue
    if [ "$has_skip" -eq 0 ]; then
      echo "## 已跳过 / 失败"; echo
      echo "| 模块 | 状态 | 原因 |"; echo "|---|---|---|"
      has_skip=1
    fi
    echo "| $module | $state | $reason |"
  done < <(sb_status_read)
  [ "$has_skip" -eq 1 ] && echo
  return 0
}

report_write_md() {
  local out="$1"
  if report_build_md > "$out" 2>/dev/null; then
    sb_ok "Markdown 报告已写入 $out"
  else
    sb_warn "写入 $out 失败"
  fi
}

# ===================== HTML =====================
report_html_table() {
  local table="$1" headers="$2" caption="${3:-}"
  sb_table_exists "$table" || return 0
  local -a H
  IFS='|' read -r -a H <<< "$headers"
  [ -n "$caption" ] && echo "<h3>$(sb_html_escape "$caption")</h3>"
  echo '<table><thead><tr>'
  local i row
  for i in "${!H[@]}"; do printf '<th>%s</th>' "$(sb_html_escape "${H[i]}")"; done
  echo '</tr></thead><tbody>'
  while IFS= read -r row; do
    sb_split_tsv "$row"
    printf '<tr>'
    for i in "${!H[@]}"; do printf '<td>%s</td>' "$(sb_html_escape "${SB_FIELDS[i]:-}")"; done
    printf '</tr>\n'
  done < <(sb_table_read "$table")
  echo '</tbody></table>'
}

report_html_kv() {
  local prefix="$1" key value
  echo '<table class="kv"><tbody>'
  while IFS=$'\t' read -r key value; do
    printf '<tr><th>%s</th><td>%s</td></tr>\n' \
      "$(sb_html_escape "${key#"$prefix"}")" "$(sb_html_escape "$value")"
  done < <(sb_kv_prefix "$prefix")
  echo '</tbody></table>'
}

report_build_html() {
  cat <<'HTMLHEAD'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SBQuailty 评测报告</title>
<style>
:root { color-scheme: light dark; }
body { margin:0; padding:2rem 1rem; font:14px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif; background:#f6f7f9; color:#1f2328; }
@media (prefers-color-scheme: dark) { body { background:#0d1117; color:#e6edf3; } }
.wrap { max-width:1080px; margin:0 auto; }
h1 { font-size:1.6rem; margin:0 0 .25rem; }
h2 { font-size:1.15rem; margin:2rem 0 .75rem; padding-bottom:.4rem; border-bottom:2px solid currentColor; opacity:.9; }
h3 { font-size:1rem; margin:1.25rem 0 .5rem; opacity:.8; }
.meta { opacity:.65; font-size:.9rem; margin-bottom:1rem; }
table { width:100%; border-collapse:collapse; margin:.5rem 0 1rem; font-size:.9rem; background:rgba(127,127,127,.04); }
th,td { padding:.4rem .6rem; text-align:left; border-bottom:1px solid rgba(127,127,127,.22); white-space:nowrap; }
th { font-weight:600; opacity:.75; }
table.kv th { width:14rem; }
tbody tr:hover { background:rgba(127,127,127,.08); }
.skip { color:#b8860b; } .fail { color:#c33; }
footer { margin-top:2.5rem; opacity:.5; font-size:.8rem; }
</style>
</head>
<body><div class="wrap">
HTMLHEAD

  printf '<h1>SBQuailty 评测报告</h1>\n'
  printf '<div class="meta">生成时间 %s &nbsp;·&nbsp; 档位 %s &nbsp;·&nbsp; 耗时 %s &nbsp;·&nbsp; %s</div>\n' \
    "$(sb_html_escape "$(sb_kv_get meta.time)")" \
    "$(sb_html_escape "$(sb_kv_get meta.profile)")" \
    "$(sb_html_escape "$(sb_elapsed_text "$(sb_kv_get meta.elapsed 0)")")" \
    "$(sb_html_escape "$(sb_kv_get meta.version)")"

  if sb_kv_has system.cpu.model; then
    echo '<h2>系统信息</h2>'
    report_html_kv 'system.'
  fi
  if sb_table_exists disk.fio; then
    echo '<h2>磁盘性能</h2>'
    report_html_table disk.fio "块大小|读取|读 IOPS|写入|写 IOPS|合计|合计 IOPS" \
      "fio 随机读写 50/50（分区 $(sb_kv_get disk.partition)）"
  elif sb_table_exists disk.dd; then
    echo '<h2>磁盘性能</h2>'
    report_html_table disk.dd "方向|测试 1|测试 2|测试 3|平均|单位" "dd 顺序读写"
  fi
  if sb_table_exists cpu.geekbench; then
    echo '<h2>CPU 跑分</h2>'
    report_html_table cpu.geekbench "版本|单核|多核|详细结果"
  fi
  local v
  for v in v4 v6; do
    sb_table_exists "ip.${v}.info" || continue
    printf '<h2>IP 质量 — %s %s</h2>\n' "${v^^}" "$(sb_html_escape "$(sb_kv_get "ip.${v}.display")")"
    report_html_table "ip.${v}.info"   "项目|值"
    report_html_table "ip.${v}.type"   "数据库|使用类型|公司类型" "IP 类型"
    report_html_table "ip.${v}.score"  "数据库|分值|风险等级" "风险评分"
    report_html_table "ip.${v}.factor" "因子|判定" "风险因子"
    report_html_table "ip.${v}.media"  "平台|结果|区域" "流媒体与 AI 解锁"
    report_html_table "ip.${v}.mail"   "检测项|结果" "邮局与黑名单"
  done
  if sb_table_exists bandwidth.iperf; then
    echo '<h2>国际带宽</h2>'
    report_html_table bandwidth.iperf "协议|提供商|位置|上传|下载|延迟" "iperf3"
  fi
  if sb_table_exists cn.cdn4 || sb_table_exists cn.cdn6 || sb_table_exists cn.route; then
    echo '<h2>中国三网</h2>'
  fi
  local g key title
  for g in cdn4:"三网回程 IPv4" large4:"三网回程 IPv4 大包" cdn6:"三网回程 IPv6" \
           cernet:"教育网 CERNET" cernet2:"教育网 CERNET2"; do
    key="${g%%:*}"; title="${g#*:}"
    report_html_table "cn.${key}" "省份|运营商|状态|发送|接收|丢包率|平均延迟|回程线路" "$title"
  done
  report_html_table cn.route     "协议|省份|运营商|线路|节点域名" "回程线路识别"
  report_html_table cn.intl       "目标|协议|IP|状态|连接耗时|TLS 握手|备注" "国际互联"
  report_html_table cn.intl_iperf "区域|节点|协议|方向|状态|TCP RTT|重传" "国际互联 — iPerf3 双向"
  report_html_table cn.speedtest  "地区|运营商|下载|上传|连接延迟|下载重传|上传重传|重传来源" "单线程测速"

  local has_skip=0
  while IFS=$'\t' read -r module state reason; do
    [ "$state" = ok ] && continue
    if [ "$has_skip" -eq 0 ]; then
      echo '<h2>已跳过 / 失败</h2><table><thead><tr><th>模块</th><th>状态</th><th>原因</th></tr></thead><tbody>'
      has_skip=1
    fi
    printf '<tr><td>%s</td><td class="%s">%s</td><td>%s</td></tr>\n' \
      "$(sb_html_escape "$module")" "$state" "$(sb_html_escape "$state")" "$(sb_html_escape "$reason")"
  done < <(sb_status_read)
  [ "$has_skip" -eq 1 ] && echo '</tbody></table>'

  printf '<footer>由 SBQuailty %s 生成 · 融合 YABS / IPQuality / TcpQuality</footer>\n' \
    "$(sb_html_escape "$(sb_kv_get meta.version)")"
  echo '</div></body></html>'
}

report_write_html() {
  local out="$1"
  if report_build_html > "$out" 2>/dev/null; then
    sb_ok "HTML 报告已写入 $out"
  else
    sb_warn "写入 $out 失败"
  fi
}

# ===================== dry-run 假数据 =====================
# 用于在没有真实探测的情况下验证四种渲染路径。
report_fill_dry_run() {
  sb_kv_set system.uptime      "3 天 4 小时 12 分钟"
  sb_kv_set system.cpu.model   "AMD EPYC 7763 64-Core Processor"
  sb_kv_set system.cpu.cores   "4"
  sb_kv_set system.cpu.freq    "2445.406 MHz"
  sb_kv_set system.cpu.aes     "已启用"
  sb_kv_set system.cpu.virt    "已启用"
  sb_kv_set system.mem.ram     "7.8 GiB"
  sb_kv_set system.mem.swap    "0.0 KiB"
  sb_kv_set system.mem.disk    "155.7 GiB"
  sb_kv_set system.distro      "Debian GNU/Linux 12 (bookworm)"
  sb_kv_set system.kernel      "6.1.0-18-amd64"
  sb_kv_set system.arch        "x64"
  sb_kv_set system.vm_type     "KVM"

  sb_kv_set meta.ipv4_online 1
  sb_kv_set meta.ipv6_online 1
  sb_kv_set disk.method fio
  sb_kv_set disk.partition "/dev/vda1"
  sb_row_add disk.fio "4k"   "182.4 MB/s" "44.5k" "183.1 MB/s" "44.7k" "365.5 MB/s" "89.2k" 178125 44531 178808 44702 356933 89233
  sb_row_add disk.fio "64k"  "1.21 GB/s"  "18.5k" "1.22 GB/s"  "18.6k" "2.43 GB/s"  "37.1k" 1181640 18463 1191406 18615 2373046 37078
  sb_row_add disk.fio "512k" "1.55 GB/s"  "3.0k"  "1.56 GB/s"  "3.0k"  "3.11 GB/s"  "6.0k"  1513671 2956 1523437 2975 3037109 5931
  sb_row_add disk.fio "1m"   "1.61 GB/s"  "1.5k"  "1.62 GB/s"  "1.5k"  "3.23 GB/s"  "3.0k"  1572265 1535 1582031 1544 3154296 3079

  sb_row_add cpu.geekbench "6" "1682" "5931" "https://browser.geekbench.com/v6/cpu/0000000"

  sb_row_add bandwidth.iperf "IPv4" "Clouvider" "London, UK (10G)"    "3.12 Gbits/sec" "4.05 Gbits/sec" "142 ms"
  sb_row_add bandwidth.iperf "IPv4" "Leaseweb"  "Singapore, SG (10G)" "1.84 Gbits/sec" "2.21 Gbits/sec" "68.4 ms"
  sb_row_add bandwidth.iperf "IPv6" "Clouvider" "London, UK (10G)"    "2.98 Gbits/sec" "3.87 Gbits/sec" "141 ms"

  sb_kv_set ip.v4.display "203.0.113.xx"
  sb_row_add ip.v4.info "ASN"      "AS64496"
  sb_row_add ip.v4.info "组织"      "Example Cloud LLC"
  sb_row_add ip.v4.info "国家/地区" "美国 US"
  sb_row_add ip.v4.info "城市"      "Los Angeles"
  sb_row_add ip.v4.info "时区"      "America/Los_Angeles"
  sb_row_add ip.v4.type  "IPinfo"     "数据中心"   "托管"
  sb_row_add ip.v4.type  "ipregistry" "数据中心"   "托管"
  sb_row_add ip.v4.score "Scamalytics" "18" "低风险"
  sb_row_add ip.v4.score "AbuseIPDB"   "0"  "无记录"
  sb_row_add ip.v4.score "IPQS"        "12" "低风险"
  sb_row_add ip.v4.factor "代理"   "否"
  sb_row_add ip.v4.factor "VPN"    "是（IPQS 判定）"
  sb_row_add ip.v4.factor "Tor"    "否"
  sb_row_add ip.v4.factor "机器人" "否"
  sb_row_add ip.v4.media "Netflix"   "仅自制剧" "US"
  sb_row_add ip.v4.media "Disney+"   "解锁"     "US"
  sb_row_add ip.v4.media "YouTube"   "解锁"     "US"
  sb_row_add ip.v4.media "TikTok"    "解锁"     "US"
  sb_row_add ip.v4.media "ChatGPT"   "解锁"     "US"
  sb_row_add ip.v4.mail "25 端口"  "开放"
  sb_row_add ip.v4.mail "DNSBL"    "50 个黑名单中 0 个命中"

  sb_kv_set ip.v6.display "2001:db8::xxxx"
  sb_row_add ip.v6.info "ASN"      "AS64496"
  sb_row_add ip.v6.info "组织"      "Example Cloud LLC"
  sb_row_add ip.v6.info "国家/地区" "美国 US"

  sb_row_add cn.cdn4 "北京" "电信" "OK" "100" "100" "0.00%"  "182.4" "CN2 GIA"
  sb_row_add cn.cdn4 "上海" "联通" "OK" "100" "98"  "2.00%"  "176.1" "AS4837"
  sb_row_add cn.cdn4 "广东" "移动" "OK" "100" "100" "0.00%"  "168.9" "CMI"
  sb_row_add cn.cdn6 "北京" "电信" "OK" "100" "100" "0.00%"  "184.2" "CN2 GIA"
  sb_row_add cn.route "IPv4/TCP" "北京" "电信" "CN2GIA"  "bj-ct.example.net"
  sb_row_add cn.route "IPv4/TCP" "上海" "联通" "4837"    "sh-cu.example.net"
  sb_row_add cn.route "IPv6/TCP" "北京" "电信" "CN2GIA"  "bj-ct6.example.net"
  sb_row_add cn.intl "Cloudflare" "IPv4" "104.16.x.x" "200" "12.4 ms" "28.1 ms" ""
  sb_row_add cn.intl "OpenAI API" "IPv4" "162.159.x.x" "403" "14.9 ms" "31.7 ms" "可达（HTTP 403）"
  sb_row_add cn.intl_iperf "亚洲" "香港" "IPv4" "上传" "OK" "38.2 ms" "0"
  sb_row_add cn.intl_iperf "亚洲" "香港" "IPv4" "下载" "OK" "37.9 ms" "12"
  sb_row_add cn.speedtest "北京" "电信" "268.1 Mbps" "104.2 Mbps" "34.0 ms" "0.12%" "0.31%" "ebpf_seq"
  sb_row_add cn.speedtest "Apple CDN" "国际" "312.4 Mbps" "未测" "182.0 ms" "-" "-" "-"

  sb_status_set "cpu.geekbench" skip "快速档默认不运行 Geekbench"
  sb_status_set "cn.probe" skip "需要 root（裸 TCP SYN）"
}
