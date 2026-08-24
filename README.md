# SBQuailty

一次运行，覆盖 **硬件性能 → IP 质量与风控 → 国际带宽 → 中国三网回程**，输出一份统一报告。

融合自三个上游项目：

| 上游 | 贡献的能力 |
|---|---|
| [yet-another-bench-script](https://github.com/masonr/yet-another-bench-script) (Mason Rowe) | 系统信息、fio 磁盘、iperf3 国际带宽、Geekbench 跑分 |
| [IPQuality](https://github.com/xykt/IPQuality) (xykt) | 10 个 IP 数据库、风控评分、流媒体/AI 解锁、邮局与 DNSBL |
| [TcpQuality](https://github.com/ibsgss/TcpQuality) (ibsgss) | 三网回程线路识别、nping 丢包、国际互联、单线程测速 |

与直接跑三个脚本的区别：一次运行、一份报告、四种格式（终端 / 纯文本 / JSON / HTML / Markdown），数据完全一致；报告只写本地，不做任何在线上传。

---

## ⚠️ 当前状态

**代码已完成，但尚未在真实环境验证过。** 首次使用前请先跑自检：

```bash
bash selfcheck.sh
```

自检不做任何网络探测，只验证语法解析、函数名冲突、四种报告渲染和 JSON 合法性。通过后再跑真实测试。

---

## 环境要求

- **Linux**（系统信息读 `/proc`，三网探测需要裸 socket 与 chroot；macOS/Windows 不支持）
- bash ≥ 4.3（用到 `local -n` 名字引用）
- `curl` 必需；`jq` 用于 IP 质量模块；其余依赖脚本会按需自动安装

## 安装

```bash
# 从本仓库取这四样即可，三个上游工程不用带
tar czf sbquality.tar.gz sbquality.sh lib assets selfcheck.sh
scp sbquality.tar.gz root@your-vps:/root/
ssh root@your-vps 'cd /root && tar xzf sbquality.tar.gz && bash selfcheck.sh'
```

可选：把 YABS 的预编译二进制一起带上（`bin/fio/` 与 `bin/iperf/`），脚本会优先用它们，省去联网下载：

```bash
cp -R yet-another-bench-script/bin .    # 打包前执行
```

## 用法

```bash
# 快速档（默认，约 8-12 分钟）
bash sbquality.sh

# 全量档（约 30-45 分钟）
sudo bash sbquality.sh -a

# 四种报告一起出
sudo bash sbquality.sh -a --json ~/r.json --html ~/r.html --md ~/r.md -o ~/r.txt

# 只跑指定模块
bash sbquality.sh --system --disk          # 无网络依赖，最快
bash sbquality.sh --ip -4                  # 只看 IPv4 的 IP 质量
sudo bash sbquality.sh --cn -bj -sh        # 三网，只测北京和上海

# 不用 rootfs，依赖直接装到宿主
sudo bash sbquality.sh -a --no-rootfs
```

### 两档的差别

| | 快速档（默认） | 全量档 `-a` |
|---|---|---|
| 系统信息 | ✓ | ✓ |
| 磁盘 fio | ✓ | ✓ |
| IP 质量 | 5 个库 | 10 个库 + DNSBL + 邮局连通性 |
| iperf3 | 3 个节点 | 7 个节点 |
| 三网回程线路（IPv4/IPv6） | ✓ | ✓ |
| 教育网回程线路 | — | ✓ |
| 三网丢包 / 教育网丢包 | — | ✓（需 root） |
| IPv4 大包回程（1200B） | — | ✓（需 root） |
| 国际互联 + iPerf3 双向 | — | ✓ |
| 单线程测速 | — | ✓ |
| Geekbench | — | ✓ |

**IPv4 大包回程**：按 3:1 混合发送大包（900–1200B）与小包（120–480B），并用 1200B 单独跑一遍 traceroute。很多线路对小包放行、对大包做 QoS 或绕行 —— 把 `IPv4大包/TCP` 那几行的线路标签和 `IPv4/TCP` 对照，标签不同就说明大包被绕了。运行前会先拿 Cloudflare 预检出口是否拦大包，拦了就跳过（否则结果全是 100% 丢包，没有信息量）。

### 常用参数

```
-a, --all           全量档
--system --disk --cpu --ip --bandwidth --cn     只跑指定模块（可组合）
--skip-<模块>       跳过指定模块
-4 / -6             只测 IPv4 / IPv6
-i <iface>          指定出口网卡
-x <proxy>          HTTP 请求走代理，如 socks5://127.0.0.1:1080
--route-protocol <tcp|udp|both>
                    回程线路识别的探测协议，默认 tcp
                    both 会 TCP/UDP 各跑一遍：部分线路对 TCP 隐藏跳点但回应 UDP
-E                  IP 质量部分用英文
-f                  报告中显示完整 IP（默认打码）
-o/--json/--html/--md <file>    各格式报告输出路径
--no-rootfs         不使用临时 rootfs
--no-sudo           非 root 时不尝试提权
-y                  自动确认
--dry-run           假数据跑一遍报告渲染
--debug             保留临时文件
-h                  完整帮助
```

省份筛选用简写直接传：`-bj`（北京）、`-sh`（上海）、`-gd`（广东）…… 注意山西是 `-sx`、陕西是 `-sn`。

## 权限与 rootfs

三网丢包探测要发送裸 TCP SYN 包，必须 root。脚本按权限分级降级：

| 权限 | 行为 |
|---|---|
| root | 自动进入一次性 Debian rootfs，依赖装在 rootfs 内不碰宿主，退出自动清理 |
| 非 root 有 sudo | 询问是否提权；拒绝则降级 |
| 非 root 无 sudo | 跳过丢包探测（报告中标注 SKIP 及原因），回程线路识别降级为 traceroute，其余模块正常 |

rootfs 获取顺序：GitHub Release 预构建（manifest 版本 + 大小 + SHA256 双重校验）→ ibsgss 镜像 → 官方 Debian OCI（逐层校验 digest）→ debootstrap / Docker 导出。首次约需下载 100-200MB，`/tmp` 或 `/var/tmp` 需 ≥900MB 空余。

`--no-rootfs` 跳过整个流程，依赖用宿主的包管理器安装（apt/dnf/apk/pacman/zypper/brew）。

## 报告

终端 TUI 之外，可同时输出：

- **`--json`** — 统一结构，顶层键：`system` / `disk` / `cpu_bench` / `bandwidth` / `ip` / `cn_network` / `skipped`
- **`--html`** — 单文件，内联样式，跟随系统深浅色
- **`--md`** — Markdown 表格
- **`-o`** — 纯文本（剥离 ANSI 颜色）

任何模块失败或被跳过，都会在报告的 `skipped` 区块列出模块名与原因，其余模块不受影响。

## 架构

```
sbquality.sh          入口：参数解析、权限分级、rootfs 调度、模块编排
lib/common.sh         结果存储（kv/rows/status）、宽度对齐、单位格式化、依赖安装、进度
lib/bench.sh          bench_*  系统 / 磁盘 / CPU / 国际带宽
lib/ipinfo.sh         ipq_*    IP 数据库 / 解锁 / 邮局 / DNSBL
lib/cnnet.sh          cn_*     回程线路 / 丢包 / 国际互联 / 单线程测速
lib/report.sh         report_* 唯一呈现层：TUI / 文本 / JSON / HTML / Markdown
assets/rootfs.sh      临时 Debian rootfs 构建与 chroot
assets/sbquality-tcpinfo.c        LD_PRELOAD，采集连接级 TCP_INFO 重传
assets/sbquality-retrans-*.bt     bpftrace，重传段去重
selfcheck.sh          离线自检
```

**关键设计**：各模块只往 `$SB_RUN_DIR` 写结果（标量进 `kv`，表格进 `rows/*.tsv`，状态进 `status`），完全不打印最终报告；`lib/report.sh` 是唯一读取方，因此四种输出的数据必然一致。

模块间用函数前缀隔离（`sb_` / `bench_` / `ipq_` / `cn_` / `report_`）——三个上游脚本各自都定义了 `is_valid_ipv4`、`show_help`、`show_progress` 等同名但语义不同的函数，前缀方案是合并的前提。

## 移植说明

三网回程识别的核心判定（`cn_route_label_from_ip_trace`，约 310 行 awk，内含大量 ASN/前缀领域规则）、教育网专用判定（`cn_education_route_label_from_ip_trace`，HKIX/国际中转回溯）、nping 丢包探测与大包混合发送、Team Cymru 批量 ASN 查询、iPerf3 双向 RTT/重传、TOS 单线程测速与 bpftrace 重传去重，均**逐字搬运**自 TcpQuality，未做简化。

与上游的差异：

- 站点/CDN 国际互联每个域名取首个公网 IP（上游最多探测 2 个再合并）
- 大包回程线路用标准 traceroute 而非 `nexttrace-tiny`，少一个二进制依赖；代价是某些线路上大包路径可能探不全、落到 `Hidden`
- 未移植北京三段限速测速（会修改宿主 qdisc/ifb）
- 删除全部在线上传：`upload_report`、排名会话、`upload.check.place`、广告拉取

仍依赖的上游服务：三网节点列表来自 `tcpquality.ibsgss.uk/getNodes`（拉取失败会跳过三网模块并继续其余测试），IPQuality 的 `ref/` 参考文件来自 GitHub / jsDelivr。

## 许可

各部分沿用上游许可：YABS 为 GPL-3.0，IPQuality 与 TcpQuality 见各自仓库。本项目为三者的融合改写。
