#!/usr/bin/env bash
#
# SBQuailty - lib/bench.sh
# 系统信息 / 磁盘 (fio, 回退 dd) / CPU 跑分 (Geekbench) / 国际带宽 (iperf3)
#
# 移植自 Yet-Another-Bench-Script (Mason Rowe, GPL-3.0)：
#   format_size/format_speed/format_iops -> lib/common.sh 的 sb_format_*
#   disk_test / dd_test / iperf_test / launch_iperf / launch_geekbench -> bench_*
# 与原版的差别：不打印最终结果（改为写入结果存储），不上传 JSON。
#
# 全局变量前缀 BENCH_，函数前缀 bench_。

BENCH_YABS_BIN_BASE="https://raw.githubusercontent.com/masonr/yet-another-bench-script/master/bin"

# ===================== 架构探测 =====================
# 设置 BENCH_ARCH: x64 | x86 | aarch64 | arm；不支持时返回 1
bench_detect_arch() {
  local arch bits
  arch=$(uname -m)
  case "$arch" in
    *x86_64*)      BENCH_ARCH="x64" ;;
    i?86|*i386*|*i686*) BENCH_ARCH="x86" ;;
    *aarch*|*arm*)
      bits=$(getconf LONG_BIT 2>/dev/null)
      [ "$bits" = 64 ] && BENCH_ARCH="aarch64" || BENCH_ARCH="arm"
      ;;
    *) BENCH_ARCH=""; return 1 ;;
  esac
  return 0
}

# 本地二进制优先级：仓库自带 bin/ > 系统已安装 > 联网下载
# bench_resolve_binary <fio|iperf3>  -> 打印可执行路径，失败返回 1
bench_resolve_binary() {
  local name="$1" subdir bin_name local_path dest
  case "$name" in
    fio)    subdir="fio";   bin_name="fio_${BENCH_ARCH}" ;;
    iperf3) subdir="iperf"; bin_name="iperf3_${BENCH_ARCH}" ;;
    *) return 1 ;;
  esac

  # 1. 仓库自带
  local_path="$SB_BIN_DIR/$subdir/$bin_name"
  if [ -f "$local_path" ]; then
    chmod +x "$local_path" 2>/dev/null
    if bench_binary_works "$local_path"; then
      printf '%s' "$local_path"
      return 0
    fi
  fi

  # 2. 系统已安装
  if sb_has "$name"; then
    command -v "$name"
    return 0
  fi

  # 3. 联网下载
  # 显式覆盖超时（二进制有几 MB，sb_curl 默认 20s 在慢线路上会截断）。sb_curl 把
  # "$@" 拼在自己的 --max-time 之后，curl 取最后一个同名选项，所以这里能盖掉默认值。
  # 下载完还要真的跑一下：某些网络会对 404 返回 200 的 HTML 错误页，光判文件非空会当成成功。
  dest="$SB_TMP_DIR/$name"
  if sb_curl --max-time 180 -o "$dest" "$BENCH_YABS_BIN_BASE/$subdir/$bin_name" 2>/dev/null &&
     [ -s "$dest" ]; then
    chmod +x "$dest"
    if bench_binary_works "$dest"; then
      printf '%s' "$dest"
      return 0
    fi
    rm -f "$dest"
  fi
  return 1
}

# 二进制能否在本机跑起来（架构不符、下到错误页、缺动态库都会在这里被挡下）
bench_binary_works() {
  "$1" --version >/dev/null 2>&1 || "$1" -v >/dev/null 2>&1
}

# ===================== 系统信息 =====================
bench_run_system() {
  sb_spin_msg "正在收集系统信息..."
  if [ ! -r /proc/cpuinfo ]; then
    sb_progress_done
    sb_skip "system" "非 Linux 系统（缺少 /proc），无法收集硬件信息"
    return 0
  fi
  bench_detect_arch || {
    sb_progress_done
    sb_skip "system" "不支持的 CPU 架构：$(uname -m)"
    return 0
  }

  local uptime_text cpu_model cpu_cores cpu_freq
  uptime_text=$(awk '{d=int($1/86400); h=int(($1%86400)/3600); m=int(($1%3600)/60);
                      printf "%d 天 %d 小时 %d 分钟", d, h, m}' /proc/uptime 2>/dev/null)

  if [[ "$BENCH_ARCH" = aarch64 || "$BENCH_ARCH" = arm ]] && sb_has lscpu; then
    cpu_model=$(lscpu | grep "Model name" | sed 's/Model name: *//g')
    cpu_cores=$(lscpu | grep "^[[:blank:]]*CPU(s):" | sed 's/CPU(s): *//g' | tr -d ' ')
    cpu_freq=$(lscpu | grep "CPU max MHz" | sed 's/CPU max MHz: *//g' | tr -d ' ')
    [ -z "$cpu_freq" ] && cpu_freq="???"
    cpu_freq="${cpu_freq} MHz"
  else
    cpu_model=$(awk -F: '/model name/ {name=$2} END {print name}' /proc/cpuinfo | sed 's/^[ \t]*//;s/[ \t]*$//')
    cpu_cores=$(awk -F: '/model name/ {core++} END {print core+0}' /proc/cpuinfo)
    cpu_freq=$(awk -F: '/cpu MHz/ {freq=$2} END {print freq " MHz"}' /proc/cpuinfo | sed 's/^[ \t]*//;s/[ \t]*$//')
  fi
  # ARM 上 /proc/cpuinfo 常无 model name，回退到 Hardware/Processor 字段
  [ -z "$cpu_model" ] && cpu_model=$(awk -F: '/^(Hardware|Processor)/ {print $2; exit}' /proc/cpuinfo | sed 's/^[ \t]*//')
  [ -z "$cpu_model" ] && cpu_model="未知"
  [ -z "$cpu_cores" ] || [ "$cpu_cores" = 0 ] && cpu_cores=$(nproc 2>/dev/null || echo 1)

  local aes virt
  grep -q aes /proc/cpuinfo && aes="已启用" || aes="未启用"
  grep -qE 'vmx|svm' /proc/cpuinfo && virt="已启用" || virt="未启用"

  local ram_raw swap_raw disk_raw
  ram_raw=$(free 2>/dev/null | awk 'NR==2 {print $2}')
  swap_raw=$(free 2>/dev/null | awk '/Swap/ {print $2}')
  disk_raw=$(df -t simfs -t ext2 -t ext3 -t ext4 -t btrfs -t xfs -t vfat -t exfat -t ntfs -t swap \
               --total 2>/dev/null | awk '/total/ {print $2}')

  local distro kernel vm_type
  distro=$(grep 'PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d '"' -f 2)
  [ -z "$distro" ] && distro="未知"
  kernel=$(uname -r)
  vm_type=$(systemd-detect-virt 2>/dev/null)
  [ -z "$vm_type" ] && vm_type="未知" || vm_type="${vm_type^^}"

  sb_kv_set system.uptime      "$uptime_text"
  sb_kv_set system.cpu.model   "$cpu_model"
  sb_kv_set system.cpu.cores   "$cpu_cores"
  sb_kv_set system.cpu.freq    "$cpu_freq"
  sb_kv_set system.cpu.aes     "$aes"
  sb_kv_set system.cpu.virt    "$virt"
  sb_kv_set system.mem.ram     "$(sb_format_size "$ram_raw")"
  sb_kv_set system.mem.swap    "$(sb_format_size "$swap_raw")"
  sb_kv_set system.mem.disk    "$(sb_format_size "$disk_raw")"
  sb_kv_set system.distro      "$distro"
  sb_kv_set system.kernel      "$kernel"
  sb_kv_set system.arch        "$BENCH_ARCH"
  sb_kv_set system.vm_type     "$vm_type"

  # 原始值供 JSON 消费方使用
  BENCH_TOTAL_RAM_RAW="$ram_raw"

  sb_status_set system ok ""
  sb_progress_done
  sb_ok "系统信息收集完成"
}

# ===================== 磁盘 =====================
# ZFS 上 fio 需要 spa_asize_inflation × 2 倍的可用空间，否则结果失真。
# 移植自 yabs.sh:546-638，简化为「返回提示文本或空」。
bench_zfs_space_warning() {
  local zfscheck="/sys/module/zfs/parameters/spa_asize_inflation"
  [ -f "$zfscheck" ] || return 0
  local mul_spa pathls longest="" maxlen=-1 avail free_gb
  mul_spa=$(( $(cat "$zfscheck" 2>/dev/null || echo 0) * 2 ))
  [ "$mul_spa" -le 0 ] && return 0
  while read -r pathls; do
    [ -z "$pathls" ] && continue
    case "$PWD" in
      "$pathls"*) if [ "${#pathls}" -gt "$maxlen" ]; then maxlen=${#pathls}; longest="$pathls"; fi ;;
    esac
  done < <(df -Th 2>/dev/null | awk 'NR>1 {print $7}')
  [ -z "$longest" ] && return 0
  avail=$(df -Th 2>/dev/null | grep -w "$longest" | awk '$2 == "zfs" {print $5; exit}')
  [ -z "$avail" ] && return 0
  # 只用 sed+awk 解析，不依赖 gawk 的三参数 match()
  free_gb=$(printf '%s' "$avail" | sed 's/[^0-9.]//g' | awk '{printf "%.0f", $1 + 0}')
  case "$avail" in
    *T|*t) free_gb=$((free_gb * 1024)) ;;
    *M|*m) free_gb=0 ;;
    *K|*k) free_gb=0 ;;
  esac
  [[ "$free_gb" =~ ^[0-9]+$ ]] || return 0
  if [ "$free_gb" -lt "$mul_spa" ]; then
    printf 'ZFS 文件系统可用空间不足（需 %s GB，当前 %s GB），fio 结果会失真' "$mul_spa" "$free_gb"
  fi
}

# bench_disk_fio <块大小...>  —— 写入 rows/disk.fio.tsv
bench_disk_fio() {
  local -a block_sizes=("$@")
  local fio_size bs test_out
  if [[ "$BENCH_ARCH" = aarch64 || "$BENCH_ARCH" = arm ]]; then fio_size=512M; else fio_size=2G; fi

  sb_spin_msg "正在生成 fio 测试文件..."
  "$BENCH_FIO_CMD" --name=setup --ioengine=libaio --rw=read --bs=64k --iodepth=64 --numjobs=2 \
    --size="$fio_size" --runtime=1 --gtod_reduce=1 --filename="$BENCH_DISK_PATH/test.fio" \
    --direct=1 --minimal &>/dev/null

  local total=${#block_sizes[@]} i=0 ok=0
  for bs in "${block_sizes[@]}"; do
    i=$((i + 1))
    sb_progress "$i" "$total" "fio 随机混合读写 ${bs}"
    test_out=$(timeout 35 "$BENCH_FIO_CMD" --name="rand_rw_$bs" --ioengine=libaio --rw=randrw \
      --rwmixread=50 --bs="$bs" --iodepth=64 --numjobs=2 --size="$fio_size" --runtime=30 \
      --gtod_reduce=1 --direct=1 --filename="$BENCH_DISK_PATH/test.fio" --group_reporting \
      --minimal 2>/dev/null | grep "rand_rw_$bs")
    [ -z "$test_out" ] && continue

    # fio terse v3：$7=读带宽 KiB/s  $8=读 IOPS  $48=写带宽 KiB/s  $49=写 IOPS
    local r_kb w_kb r_iops w_iops rw_kb rw_iops
    r_kb=$(echo "$test_out" | awk -F';' '{print $7}')
    r_iops=$(echo "$test_out" | awk -F';' '{print $8}')
    w_kb=$(echo "$test_out" | awk -F';' '{print $48}')
    w_iops=$(echo "$test_out" | awk -F';' '{print $49}')
    [[ "$r_kb" =~ ^[0-9]+$ ]] || continue
    rw_kb=$(awk -v a="$r_kb" -v b="$w_kb" 'BEGIN { print a + b }')
    rw_iops=$(awk -v a="$r_iops" -v b="$w_iops" 'BEGIN { print a + b }')

    sb_row_add disk.fio "$bs" \
      "$(sb_format_speed "$r_kb")"  "$(sb_format_iops "$r_iops")" \
      "$(sb_format_speed "$w_kb")"  "$(sb_format_iops "$w_iops")" \
      "$(sb_format_speed "$rw_kb")" "$(sb_format_iops "$rw_iops")" \
      "$r_kb" "$r_iops" "$w_kb" "$w_iops" "$rw_kb" "$rw_iops"
    ok=$((ok + 1))
  done
  sb_progress_done
  rm -f "$BENCH_DISK_PATH/test.fio"
  [ "$ok" -gt 0 ]
}

# dd 顺序读写回退（fio 下载失败或执行出错时）
bench_disk_dd() {
  local i w_res=() r_res=() w_sum=0 r_sum=0 out val unit
  for i in 1 2 3; do
    sb_progress "$((i * 2 - 1))" 6 "dd 顺序写入测试 $i/3"
    out=$(dd if=/dev/zero of="$BENCH_DISK_PATH/dd.test" bs=64k count=16k oflag=direct 2>&1 |
          grep -i copied | awk '{print $(NF-1) " " $NF}')
    val=$(echo "$out" | cut -d' ' -f1)
    [[ "$out" == *GB* ]] && val=$(awk -v a="$val" 'BEGIN {print a * 1000}')
    w_res+=("$out")
    w_sum=$(awk -v a="$w_sum" -v b="${val:-0}" 'BEGIN {print a + b}')

    sb_progress "$((i * 2))" 6 "dd 顺序读取测试 $i/3"
    out=$(dd if="$BENCH_DISK_PATH/dd.test" of=/dev/null bs=8k 2>&1 |
          grep -i copied | awk '{print $(NF-1) " " $NF}')
    val=$(echo "$out" | cut -d' ' -f1)
    [[ "$out" == *GB* ]] && val=$(awk -v a="$val" 'BEGIN {print a * 1000}')
    r_res+=("$out")
    r_sum=$(awk -v a="$r_sum" -v b="${val:-0}" 'BEGIN {print a + b}')
  done
  sb_progress_done
  rm -f "$BENCH_DISK_PATH/dd.test"

  local w_avg r_avg w_unit="MB/s" r_unit="MB/s"
  w_avg=$(awk -v a="$w_sum" 'BEGIN {print a / 3}')
  r_avg=$(awk -v a="$r_sum" 'BEGIN {print a / 3}')
  if [ "$(echo "$w_avg" | cut -d. -f1)" -ge 1000 ] 2>/dev/null; then
    w_avg=$(awk -v a="$w_avg" 'BEGIN {print a / 1000}'); w_unit="GB/s"
  fi
  if [ "$(echo "$r_avg" | cut -d. -f1)" -ge 1000 ] 2>/dev/null; then
    r_avg=$(awk -v a="$r_avg" 'BEGIN {print a / 1000}'); r_unit="GB/s"
  fi

  sb_row_add disk.dd "写入" "${w_res[0]}" "${w_res[1]}" "${w_res[2]}" \
    "$(awk -v a="$w_avg" 'BEGIN {printf "%.2f", a}')" "$w_unit"
  sb_row_add disk.dd "读取" "${r_res[0]}" "${r_res[1]}" "${r_res[2]}" \
    "$(awk -v a="$r_avg" 'BEGIN {printf "%.2f", a}')" "$r_unit"
}

bench_run_disk() {
  [ -n "${BENCH_ARCH:-}" ] || bench_detect_arch || {
    sb_skip "disk" "不支持的 CPU 架构"
    return 0
  }

  local avail need
  avail=$(df -k . 2>/dev/null | awk 'NR==2 {print $4}')
  if [[ "$BENCH_ARCH" = aarch64 || "$BENCH_ARCH" = arm ]]; then need=524288; else need=2097152; fi
  if [[ "$avail" =~ ^[0-9]+$ ]] && [ "$avail" -lt "$need" ]; then
    sb_skip "disk" "可用空间不足（需要 $((need / 1048576)) GB）"
    return 0
  fi

  local zfs_warn
  zfs_warn=$(bench_zfs_space_warning)
  [ -n "$zfs_warn" ] && sb_warn "$zfs_warn"

  BENCH_DISK_PATH="$SB_TMP_DIR/disk"
  mkdir -p "$BENCH_DISK_PATH"

  BENCH_FIO_CMD=$(bench_resolve_binary fio)
  if [ -n "$BENCH_FIO_CMD" ] && bench_disk_fio 4k 64k 512k 1m; then
    sb_kv_set disk.method fio
    sb_kv_set disk.partition "$(df -P . 2>/dev/null | tail -1 | cut -d' ' -f1)"
    sb_status_set disk ok ""
    sb_ok "磁盘性能测试完成（fio）"
  else
    sb_warn "fio 不可用或执行失败，回退到 dd 顺序读写测试"
    bench_disk_dd
    sb_kv_set disk.method dd
    sb_status_set disk ok "fio 不可用，已回退 dd"
    sb_ok "磁盘性能测试完成（dd 回退）"
  fi
  rm -rf "$BENCH_DISK_PATH"
}

# ===================== CPU 跑分 =====================
# bench_geekbench <版本 4|5|6|7>
bench_geekbench() {
  local version="$1" gb_url="" gb_cmd="" gb_path

  if [ "$version" = 4 ]; then
    if [[ "$BENCH_ARCH" = aarch64 || "$BENCH_ARCH" = arm ]]; then
      sb_skip "cpu.geekbench4" "Geekbench 4 不支持 ARM 架构"
      return 1
    fi
    gb_url="https://cdn.geekbench.com/Geekbench-4.4.4-Linux.tar.gz"
    [[ "$BENCH_ARCH" = x86 ]] && gb_cmd="geekbench_x86_32" || gb_cmd="geekbench4"
  else
    if [[ "$BENCH_ARCH" = x86 ]]; then
      sb_skip "cpu.geekbench${version}" "Geekbench ${version} 不支持 32 位架构，可改用 Geekbench 4"
      return 1
    fi
    local is_arm=0
    [[ "$BENCH_ARCH" = aarch64 || "$BENCH_ARCH" = arm ]] && is_arm=1
    case "$version" in
      5) gb_cmd="geekbench5"
         [ "$is_arm" -eq 1 ] && gb_url="https://cdn.geekbench.com/Geekbench-5.5.1-LinuxARMPreview.tar.gz" \
                             || gb_url="https://cdn.geekbench.com/Geekbench-5.5.1-Linux.tar.gz" ;;
      6) gb_cmd="geekbench6"
         [ "$is_arm" -eq 1 ] && gb_url="https://cdn.geekbench.com/Geekbench-6.7.1-LinuxARMPreview.tar.gz" \
                             || gb_url="https://cdn.geekbench.com/Geekbench-6.7.1-Linux.tar.gz" ;;
      7) gb_cmd="geekbench7"
         [ "$is_arm" -eq 1 ] && gb_url="https://cdn.geekbench.com/Geekbench-7.0.0-LinuxARMPreview.tar.gz" \
                             || gb_url="https://cdn.geekbench.com/Geekbench-7.0.0-Linux.tar.gz" ;;
      *) return 1 ;;
    esac
  fi

  sb_spin_msg "正在运行 Geekbench ${version} 跑分（可能需要 15 分钟以上）..."

  if sb_has "$gb_cmd"; then
    gb_path=$(dirname "$(command -v "$gb_cmd")")
  else
    gb_path="$SB_TMP_DIR/geekbench_$version"
    mkdir -p "$gb_path"
    sb_curl --max-time 300 "$gb_url" 2>/dev/null | tar xz --strip-components=1 -C "$gb_path" &>/dev/null
    if [ ! -x "$gb_path/$gb_cmd" ]; then
      sb_progress_done
      if [ "${SB_IPV4_OK:-0}" -eq 0 ]; then
        sb_skip "cpu.geekbench${version}" "Geekbench 只能通过 IPv4 下载，当前无 IPv4"
      else
        sb_skip "cpu.geekbench${version}" "Geekbench ${version} 下载失败"
      fi
      return 1
    fi
  fi

  # 有 license 文件则解锁（沿用 YABS 行为）
  [ -f "geekbench.license" ] && "$gb_path/$gb_cmd" --unlock "$(cat geekbench.license)" >/dev/null 2>&1

  local gb_out gb_url_result gb_url_claim
  gb_out=$("$gb_path/$gb_cmd" --upload 2>/dev/null | grep "https://browser")
  sb_progress_done

  if [ -z "$gb_out" ]; then
    if grep -q "CentOS Linux 7" /etc/os-release 2>/dev/null; then
      sb_skip "cpu.geekbench${version}" "CentOS 7 与 Geekbench 存在已知 glibc 兼容问题"
    elif [ "$version" != 4 ] && [[ "${BENCH_TOTAL_RAM_RAW:-0}" =~ ^[0-9]+$ ]] && [ "${BENCH_TOTAL_RAM_RAW:-0}" -le 1048576 ]; then
      sb_skip "cpu.geekbench${version}" "内存不足 1GB，请增加 SWAP 或改用 Geekbench 4"
    else
      sb_skip "cpu.geekbench${version}" "Geekbench ${version} 运行失败，请手动运行排查"
    fi
    return 1
  fi

  gb_url_result=$(echo "$gb_out" | head -1 | awk '{print $1}')
  gb_url_claim=$(echo "$gb_out" | tail -1 | awk '{print $1}')
  sleep 10   # 等待结果页生成

  local scores single multi
  if [ "$version" = 4 ]; then
    scores=$(sb_curl "$gb_url_result" 2>/dev/null | grep "span class='score'")
  else
    scores=$(sb_curl "$gb_url_result" 2>/dev/null | grep "div class='score'")
  fi
  single=$(echo "$scores" | awk -v FS="(>|<)" '{print $3}' | head -n 1)
  multi=$(echo "$scores" | awk -v FS="(>|<)" '{print $3}' | tail -n 1)

  sb_row_add cpu.geekbench "$version" "${single:-未知}" "${multi:-未知}" "$gb_url_result"
  # claim URL 写到当前目录，便于用户认领结果（与 YABS 一致）
  [ -n "$gb_url_claim" ] && echo "$gb_url_claim" >> geekbench_claim.url 2>/dev/null
  sb_ok "Geekbench ${version} 完成：单核 ${single:-?} / 多核 ${multi:-?}"
  return 0
}

bench_run_cpu() {
  [ -n "${BENCH_ARCH:-}" ] || bench_detect_arch || {
    sb_skip "cpu" "不支持的 CPU 架构"
    return 0
  }
  if [ "${SB_IPV4_OK:-0}" -eq 0 ] && [ "${SB_IPV6_OK:-0}" -eq 0 ]; then
    sb_skip "cpu" "无网络连接，无法下载 Geekbench"
    return 0
  fi
  if bench_geekbench "${BENCH_GEEKBENCH_VERSION:-6}"; then
    sb_status_set cpu ok ""
  fi
}

# ===================== 国际带宽 (iperf3) =====================
# 节点表，五元组：域名 端口范围 提供商 位置(链路) 支持的协议
BENCH_IPERF_LOCS=(
  "lon.speedtest.clouvider.net"    "5200-5209" "Clouvider" "London, UK (10G)"          "IPv4|IPv6"
  "iperf-ams-nl.eranium.net"       "5201-5210" "Eranium"   "Amsterdam, NL (100G)"      "IPv4|IPv6"
  "speedtest.uztelecom.uz"         "5200-5209" "Uztelecom" "Tashkent, UZ (10G)"        "IPv4|IPv6"
  "speedtest.sin1.sg.leaseweb.net" "5201-5210" "Leaseweb"  "Singapore, SG (10G)"       "IPv4|IPv6"
  "la.speedtest.clouvider.net"     "5200-5209" "Clouvider" "Los Angeles, CA, US (10G)" "IPv4|IPv6"
  "speedtest.nyc1.us.leaseweb.net" "5201-5210" "Leaseweb"  "NYC, NY, US (10G)"         "IPv4|IPv6"
  "speedtest.sao1.edgoo.net"       "9204-9240" "Edgoo"     "Sao Paulo, BR (1G)"        "IPv4|IPv6"
)

# 快速档只测三个节点，减少带宽消耗
BENCH_IPERF_LOCS_REDUCED=(
  "lon.speedtest.clouvider.net"    "5200-5209" "Clouvider" "London, UK (10G)"    "IPv4|IPv6"
  "speedtest.sin1.sg.leaseweb.net" "5201-5210" "Leaseweb"  "Singapore, SG (10G)" "IPv4|IPv6"
  "speedtest.nyc1.us.leaseweb.net" "5201-5210" "Leaseweb"  "NYC, NY, US (10G)"   "IPv4|IPv6"
)

# bench_iperf_one <域名> <端口范围> <提供商> <-4|-6>
# 结果写入 BENCH_IPERF_SEND / BENCH_IPERF_RECV / BENCH_IPERF_LATENCY
bench_iperf_one() {
  local url="$1" ports="$2" host="$3" flags="$4"
  local i port run speed

  BENCH_IPERF_SEND="" BENCH_IPERF_RECV="" BENCH_IPERF_LATENCY="--"

  # 发送方向，最多重试 3 次（等待服务端空闲槽位 / 丢弃异常结果）
  i=1
  while [ "$i" -le 3 ]; do
    sb_spin_msg "iperf3 上传测试 → ${host}（第 $i/3 次）"
    port=$(shuf -i "$ports" -n 1 2>/dev/null || echo "${ports%%-*}")
    run=$(timeout 15 "$BENCH_IPERF_CMD" "$flags" -c "$url" -p "$port" -P 8 2>/dev/null)
    if [[ "$run" == *receiver* && "$run" != *error* ]]; then
      speed=$(echo "$run" | grep SUM | grep receiver | awk '{print $6}')
      if [ -n "$speed" ] && [ "$speed" != "0.00" ]; then
        BENCH_IPERF_SEND=$(echo "$run" | grep SUM | grep receiver | awk '{print $6 " " $7}')
        break
      fi
      i=$((i + 1))
    else
      [[ "$run" == *"unable to connect"* ]] && break
      i=$((i + 1)); sleep 2
    fi
  done

  sleep 1   # 给服务端喘息时间，避免下一个方向抢不到槽位

  i=1
  while [ "$i" -le 3 ]; do
    sb_spin_msg "iperf3 下载测试 ← ${host}（第 $i/3 次）"
    port=$(shuf -i "$ports" -n 1 2>/dev/null || echo "${ports%%-*}")
    run=$(timeout 15 "$BENCH_IPERF_CMD" "$flags" -c "$url" -p "$port" -P 8 -R 2>/dev/null)
    if [[ "$run" == *receiver* && "$run" != *error* ]]; then
      speed=$(echo "$run" | grep SUM | grep receiver | awk '{print $6}')
      if [ -n "$speed" ] && [ "$speed" != "0.00" ]; then
        BENCH_IPERF_RECV=$(echo "$run" | grep SUM | grep receiver | awk '{print $6 " " $7}')
        break
      fi
      i=$((i + 1))
    else
      [[ "$run" == *"unable to connect"* ]] && break
      i=$((i + 1)); sleep 2
    fi
  done

  if sb_has ping; then
    local lat
    lat=$(ping "$flags" -c1 -W 4 "$url" 2>/dev/null | grep -o 'time=.*' | sed 's/time=//')
    [ -n "$lat" ] && BENCH_IPERF_LATENCY="$lat"
  fi

  [ -z "$BENCH_IPERF_SEND" ] && BENCH_IPERF_SEND="繁忙"
  [ -z "$BENCH_IPERF_RECV" ] && BENCH_IPERF_RECV="繁忙"
}

# bench_iperf_mode <IPv4|IPv6>
bench_iperf_mode() {
  local mode="$1" flags i total=0 done_n=0
  [ "$mode" = IPv6 ] && flags="-6" || flags="-4"

  local -n locs="$BENCH_IPERF_ARRAY_NAME"
  local n=$((${#locs[@]} / 5))
  for (( i = 0; i < n; i++ )); do
    [[ "${locs[i*5+4]}" == *"$mode"* ]] && total=$((total + 1))
  done
  [ "$total" -eq 0 ] && return 0

  for (( i = 0; i < n; i++ )); do
    [[ "${locs[i*5+4]}" == *"$mode"* ]] || continue
    done_n=$((done_n + 1))
    sb_progress "$done_n" "$total" "${mode} ${locs[i*5+2]} ${locs[i*5+3]}"
    bench_iperf_one "${locs[i*5]}" "${locs[i*5+1]}" "${locs[i*5+2]}" "$flags"
    sb_row_add bandwidth.iperf "$mode" "${locs[i*5+2]}" "${locs[i*5+3]}" \
      "$BENCH_IPERF_SEND" "$BENCH_IPERF_RECV" "$BENCH_IPERF_LATENCY"
  done
  sb_progress_done
}

bench_run_iperf() {
  [ -n "${BENCH_ARCH:-}" ] || bench_detect_arch || {
    sb_skip "bandwidth" "不支持的 CPU 架构"
    return 0
  }
  if [ "${SB_IPV4_OK:-0}" -eq 0 ] && [ "${SB_IPV6_OK:-0}" -eq 0 ]; then
    sb_skip "bandwidth" "无网络连接"
    return 0
  fi

  BENCH_IPERF_CMD=$(bench_resolve_binary iperf3)
  if [ -z "$BENCH_IPERF_CMD" ]; then
    sb_skip "bandwidth" "iperf3 不可用（本地未安装且下载失败）"
    return 0
  fi

  if [ "${SB_PROFILE:-quick}" = all ]; then
    BENCH_IPERF_ARRAY_NAME=BENCH_IPERF_LOCS
  else
    BENCH_IPERF_ARRAY_NAME=BENCH_IPERF_LOCS_REDUCED
    sb_info "快速档：仅测试 3 个 iperf3 节点（全量档 -a 测试全部 7 个）"
  fi

  [ "${SB_IPV4_OK:-0}" -eq 1 ] && bench_iperf_mode "IPv4"
  [ "${SB_IPV6_OK:-0}" -eq 1 ] && bench_iperf_mode "IPv6"

  if sb_table_exists bandwidth.iperf; then
    sb_status_set bandwidth ok ""
    sb_ok "国际带宽测试完成"
  else
    sb_skip "bandwidth" "全部 iperf3 节点均不可用"
  fi
}
