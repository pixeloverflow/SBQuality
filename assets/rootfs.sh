#!/usr/bin/env bash
#
# SBQuailty - assets/rootfs.sh
#
# 在临时 Debian rootfs + chroot 中运行 SBQuailty。guest 与宿主共享网络命名空间，
# 所以回程线路、丢包、测速结果仍然代表这台 VPS；好处是 nping/traceroute/iperf3/
# bpftrace 等依赖装在一次性 rootfs 里，不污染宿主的包环境。
#
# 移植自 TcpQuality:runTcpQuality-rootfs.sh（ibsgss）。与原版的差别：
#   - guest 内运行的是 sbquality.sh（连同 lib/ 一起拷进去），不是 runTcpQuality-core.sh
#   - 去掉 Alpine 分支与交互式菜单：SBQuailty 的档位由入口参数决定
#   - 去掉 --allow-speedtest（未移植会改宿主 qdisc/ifb 的北京三段限速测速）
#   - 预构建 rootfs 仍复用 TcpQuality 的 release 产物（公开的 Debian rootfs）
#
# 用法（由 sbquality.sh 自动调用，一般不需要手工执行）:
#   sudo bash assets/rootfs.sh --source-dir <SBQuailty 目录> --output DIR -- <sbquality.sh 参数>

set -Eeuo pipefail

SELF_SCRIPT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")"
SOURCE_DIR=""
OUTPUT_DIR="${SBQUALITY_OUTPUT_DIR:-/tmp}"
ROOTFS_DIR=""
ROOTFS_URL="${SBQUALITY_ROOTFS_URL:-}"
ROOTFS_SHA256="${SBQUALITY_ROOTFS_SHA256:-}"
KEEP_ROOTFS=0
DEBUG_MODE=0
DEBIAN_SUITE="${SBQUALITY_DEBIAN_SUITE:-bookworm}"
ROOTFS_RELEASE_TAG="${SBQUALITY_ROOTFS_RELEASE_TAG:-v1.latest}"
ROOTFS_SOURCE_ORDER="${SBQUALITY_ROOTFS_SOURCE_ORDER:-github ibsgss}"
ROOTFS_GITHUB_REPOSITORY="${SBQUALITY_ROOTFS_GITHUB_REPOSITORY:-ibsgss/TcpQuality}"
ROOTFS_IBSGSS_BASE="${SBQUALITY_ROOTFS_IBSGSS_BASE:-https://tcpquality.ibsgss.uk/rootfs/releases}"
GUEST_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MIN_ROOTFS_FREE_KB=$((900 * 1024))
ORIGINAL_ARGS=("$@")

die() { echo "[X] $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }

usage() {
  cat <<'EOF'
用法:
  sudo bash assets/rootfs.sh [选项] -- [sbquality.sh 参数]

选项:
  --source-dir DIR   SBQuailty 源码目录（含 sbquality.sh 与 lib/），必填
  --output DIR       报告输出目录，默认 /tmp
  --rootfs DIR       复用已有 rootfs，不下载也不删除
  --url URL          自定义 rootfs tar(.gz/.xz/.zst)
  --sha256 HEX       校验自定义 rootfs
  --keep             保留本次创建的临时 rootfs
  --debug            输出更多诊断信息
  -h, --help         显示帮助
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source-dir) [ "$#" -ge 2 ] || die "--source-dir 缺少参数"; SOURCE_DIR="$2"; shift 2 ;;
    --output)     [ "$#" -ge 2 ] || die "--output 缺少参数"; OUTPUT_DIR="$2"; shift 2 ;;
    --rootfs)     [ "$#" -ge 2 ] || die "--rootfs 缺少参数"; ROOTFS_DIR="$2"; shift 2 ;;
    --url)        [ "$#" -ge 2 ] || die "--url 缺少参数"; ROOTFS_URL="$2"; shift 2 ;;
    --sha256)     [ "$#" -ge 2 ] || die "--sha256 缺少参数"; ROOTFS_SHA256="$2"; shift 2 ;;
    --keep)       KEEP_ROOTFS=1; shift ;;
    --debug)      DEBUG_MODE=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    --)           shift; break ;;
    *)            die "未知参数: $1（sbquality.sh 参数请放在 -- 之后）" ;;
  esac
done

[ -n "$SOURCE_DIR" ] || die "必须提供 --source-dir"
[ -f "$SOURCE_DIR/sbquality.sh" ] || die "找不到 $SOURCE_DIR/sbquality.sh"
[ -d "$SOURCE_DIR/lib" ] || die "找不到 $SOURCE_DIR/lib"
[ -z "$ROOTFS_DIR" ] || [ -z "$ROOTFS_URL" ] || die "--rootfs 与 --url 不能同时使用"
[ -z "$ROOTFS_SHA256" ] || [ -n "$ROOTFS_URL" ] || die "--sha256 只能与 --url 一起使用"
[ "$(id -u)" -eq 0 ] || die "rootfs/chroot 需要 root 权限"
[ "$(uname -s)" = Linux ] || die "rootfs/chroot 仅支持 Linux"
[ -z "$ROOTFS_SHA256" ] || [[ "$ROOTFS_SHA256" =~ ^[[:xdigit:]]{64}$ ]] || die "--sha256 必须是 64 位十六进制"

# 临时挂载点保持私有；部分受限 VPS 不允许 unshare，此时退回显式卸载。
if [ "${SBQUALITY_MOUNT_NS:-0}" -eq 0 ] && command -v unshare >/dev/null 2>&1; then
  if unshare -m true >/dev/null 2>&1; then
    exec env SBQUALITY_MOUNT_NS=1 unshare -m /bin/bash "$SELF_SCRIPT" "${ORIGINAL_ARGS[@]}"
  fi
fi
if [ "${SBQUALITY_MOUNT_NS:-0}" -eq 1 ]; then
  mount --make-rprivate / >/dev/null 2>&1 || mount -o rprivate / >/dev/null 2>&1 || true
fi

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)  DEBIAN_ARCH=amd64; OCI_ARCH=amd64; OCI_VARIANT="";   DOCKER_PLATFORM=linux/amd64 ;;
  aarch64|arm64) DEBIAN_ARCH=arm64; OCI_ARCH=arm64; OCI_VARIANT=v8;   DOCKER_PLATFORM=linux/arm64 ;;
  armv7l|armv7)  DEBIAN_ARCH=armhf; OCI_ARCH=arm;   OCI_VARIANT=v7;   DOCKER_PLATFORM=linux/arm/v7 ;;
  *) die "暂不支持的 CPU 架构: $ARCH" ;;
esac

for c in tar mount umount chroot curl awk env grep sed tr; do need_cmd "$c"; done

CREATED_ROOTFS=0
TEMP_ROOT_PARENT=""
RUNTIME_DIR=""
GUEST_TMP_HOST=""
OUTPUTS_PERSISTED=0
DOCKER_CID=""
DOCKER_IMAGE=""
DOCKER_REMOVE_IMAGE=0
MOUNTED=()
UNMOUNT_FAILED=0
INTERRUPTED=0

# guest 把报告写到 /tmp（bind 自 GUEST_TMP_HOST），退出前搬回宿主输出目录
persist_guest_outputs() {
  local artifact base destination stem suffix counter
  [ "$OUTPUTS_PERSISTED" -eq 0 ] || return 0
  [ -n "${GUEST_TMP_HOST:-}" ] && [ -d "$GUEST_TMP_HOST" ] || return 0
  mkdir -p "$OUTPUT_DIR" || return 0
  for artifact in "$GUEST_TMP_HOST"/sbquality-report.*; do
    [ -f "$artifact" ] || continue
    base=$(basename -- "$artifact")
    destination="$OUTPUT_DIR/$base"
    if [ -e "$destination" ]; then
      stem=${base%.*}; suffix=.${base##*.}
      counter=1
      while [ -e "$OUTPUT_DIR/${stem}.${counter}${suffix}" ]; do counter=$((counter + 1)); done
      destination="$OUTPUT_DIR/${stem}.${counter}${suffix}"
    fi
    mv -- "$artifact" "$destination" || echo "[!] 输出保留失败: $artifact" >&2
  done
  OUTPUTS_PERSISTED=1
}

cleanup() {
  local i target
  set +e
  [ "$INTERRUPTED" -eq 0 ] && persist_guest_outputs
  if [ -n "${DOCKER_CID:-}" ]; then docker rm -f "$DOCKER_CID" >/dev/null 2>&1; DOCKER_CID=""; fi
  if [ "$DOCKER_REMOVE_IMAGE" -eq 1 ] && [ -n "${DOCKER_IMAGE:-}" ]; then
    docker image rm "$DOCKER_IMAGE" >/dev/null 2>&1; DOCKER_REMOVE_IMAGE=0
  fi
  for ((i=${#MOUNTED[@]}-1; i>=0; i--)); do
    target="${MOUNTED[$i]}"
    if ! umount "$target" >/dev/null 2>&1; then
      sleep 0.1
      if ! umount -R "$target" >/dev/null 2>&1 &&
         ! umount -R -l "$target" >/dev/null 2>&1 &&
         ! umount -l "$target" >/dev/null 2>&1; then
        UNMOUNT_FAILED=1
      fi
    fi
    if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$target"; then UNMOUNT_FAILED=1; fi
  done
  [ -n "${RUNTIME_DIR:-}" ] && [ -d "$RUNTIME_DIR" ] && rm -rf -- "$RUNTIME_DIR"
  if [ "$CREATED_ROOTFS" -eq 1 ] && { [ "$KEEP_ROOTFS" -eq 0 ] || [ "$INTERRUPTED" -eq 1 ]; } &&
     [ -n "${TEMP_ROOT_PARENT:-}" ] && [ -d "$TEMP_ROOT_PARENT" ]; then
    if [ "$UNMOUNT_FAILED" -eq 0 ]; then
      rm -rf -- "$TEMP_ROOT_PARENT"
    else
      echo "[!] 存在未卸载的挂载点，已保留临时 rootfs: $TEMP_ROOT_PARENT" >&2
    fi
  fi
}
on_interrupt() {
  local signal="${1:-TERM}" status=143
  [ "$signal" = INT ] && status=130
  INTERRUPTED=1
  cleanup
  trap - EXIT
  exit "$status"
}
trap 'on_interrupt INT' INT
trap 'on_interrupt TERM' TERM
trap cleanup EXIT

verify_sha256() {
  local checksum="$1" file="$2" actual
  checksum=$(printf '%s' "$checksum" | tr 'A-F' 'a-f')
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s  %s\n' "$checksum" "$file" | sha256sum -c - >/dev/null
  elif command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 "$file" | awk '{print $1}')
    [ "$actual" = "$checksum" ]
  else
    die "缺少 SHA256 校验工具"
  fi
}

rootfs_archive_supported() {
  case "$1" in
    *.tar.xz)
      command -v xz >/dev/null 2>&1 && return 0
      echo "[!] 跳过 .tar.xz rootfs：宿主缺少 xz" >&2
      return 1 ;;
    *) return 0 ;;
  esac
}

download_extract() {
  local url="$1" archive="$2" checksum="${3:-}"
  rootfs_archive_supported "$archive" || die "解压 .tar.xz 需要 xz-utils"
  echo "[i] 下载 rootfs: $url"
  [ -n "$checksum" ] || echo "[!] 自定义 rootfs 未提供 SHA256，仅适合可信来源" >&2
  curl -fL --retry 3 --connect-timeout 15 --max-time 600 "$url" -o "$archive" || die "rootfs 下载失败"
  [ -z "$checksum" ] || verify_sha256 "$checksum" "$archive" || die "rootfs SHA256 校验失败"
  mkdir -p "$ROOTFS_DIR"
  case "$archive" in
    *.tar.gz|*.tgz) tar -xzf "$archive" -C "$ROOTFS_DIR" ;;
    *.tar.xz)       tar -xJf "$archive" -C "$ROOTFS_DIR" ;;
    *.tar.zst)
      if tar --help 2>&1 | grep -q -- '--zstd'; then tar --zstd -xf "$archive" -C "$ROOTFS_DIR"
      elif command -v unzstd >/dev/null 2>&1; then unzstd -c "$archive" | tar -xf - -C "$ROOTFS_DIR"
      else die "解压 .tar.zst 需要支持 --zstd 的 tar 或 unzstd"; fi ;;
    *.tar) tar -xf "$archive" -C "$ROOTFS_DIR" ;;
    *) die "无法识别的压缩格式: $archive" ;;
  esac
  rm -f -- "$archive"
}

rootfs_source_base() {
  case "$1" in
    github) printf 'https://github.com/%s/releases/download/%s\n' "$ROOTFS_GITHUB_REPOSITORY" "${2:-$ROOTFS_RELEASE_TAG}" ;;
    ibsgss) printf '%s/%s\n' "${ROOTFS_IBSGSS_BASE%/}" "${2:-$ROOTFS_RELEASE_TAG}" ;;
    *) return 1 ;;
  esac
}

parse_manifest_version() {
  awk '
    /"version"[[:space:]]*:/ {
      line=$0; sub(/^.*"version"[[:space:]]*:[[:space:]]*"/, "", line); sub(/".*$/, "", line)
      if (line ~ /^v1\.[0-9][0-9][0-9][0-9][0-9]$/) print line
      exit
    }' "$1"
}

parse_manifest_entry() {
  awk -v wanted="$2" '
    $0 ~ ("\"" wanted "\"[[:space:]]*:") { inside=1; next }
    inside && /"file"[[:space:]]*:/ { l=$0; sub(/^.*"file"[[:space:]]*:[[:space:]]*"/,"",l); sub(/".*$/,"",l); file=l }
    inside && /"fallbackFile"[[:space:]]*:/ { l=$0; sub(/^.*"fallbackFile"[[:space:]]*:[[:space:]]*"/,"",l); sub(/".*$/,"",l); ffile=l }
    inside && /"sha256"[[:space:]]*:/ { l=$0; sub(/^.*"sha256"[[:space:]]*:[[:space:]]*"/,"",l); sub(/".*$/,"",l); sha=l }
    inside && /"fallbackSha256"[[:space:]]*:/ { l=$0; sub(/^.*"fallbackSha256"[[:space:]]*:[[:space:]]*"/,"",l); sub(/".*$/,"",l); fsha=l }
    inside && /"size"[[:space:]]*:/ { l=$0; sub(/^.*"size"[[:space:]]*:[[:space:]]*/,"",l); sub(/[^0-9].*$/,"",l); size=l }
    inside && /"fallbackSize"[[:space:]]*:/ { l=$0; sub(/^.*"fallbackSize"[[:space:]]*:[[:space:]]*/,"",l); sub(/[^0-9].*$/,"",l); fsize=l }
    inside && /^([[:space:]]*)}/ {
      if (file != "" && length(sha) == 64 && sha !~ /[^0-9a-fA-F]/ && size ~ /^[0-9]+$/)
        print file "|" tolower(sha) "|" size "|" ffile "|" tolower(fsha) "|" fsize
      exit
    }' "$1"
}

download_prebuilt_from() {
  local source="$1" base asset_base manifest manifest_version metadata archive tar_opt
  local pfile psha psize ffile fsha fsize file checksum expected actual cache_buster
  base=$(rootfs_source_base "$source") || return 1
  manifest="$TEMP_ROOT_PARENT/rootfs-manifest-${source}.json"
  echo "[i] 尝试 ${source} 预构建 rootfs: ${ROOTFS_RELEASE_TAG}"
  cache_buster="$(date +%s)-$$"
  curl -fsSL --retry 2 --connect-timeout 10 --max-time 45 \
    "$base/rootfs-manifest.json?refresh=$cache_buster" -o "$manifest" || return 1
  manifest_version=$(parse_manifest_version "$manifest") || return 1
  [ -n "$manifest_version" ] || return 1
  asset_base=$(rootfs_source_base "$source" "$manifest_version") || return 1
  metadata=$(parse_manifest_entry "$manifest" "$DEBIAN_ARCH") || return 1
  [ -n "$metadata" ] || return 1
  IFS='|' read -r pfile psha psize ffile fsha fsize <<< "$metadata"

  # 优先 .tar.xz（体积小）；宿主无 xz 或资源不存在时退回 .tar.gz
  if [[ "$pfile" == *.tar.xz ]] && rootfs_archive_supported "$pfile"; then
    file="$pfile"; checksum="$psha"; expected="$psize"
  elif [[ "$ffile" == *.tar.gz ]] && [[ "$fsha" =~ ^[0-9a-fA-F]{64}$ ]] && [[ "$fsize" =~ ^[0-9]+$ ]]; then
    file="$ffile"; checksum="$fsha"; expected="$fsize"
  elif [[ "$pfile" == *.tar.gz ]]; then
    file="$pfile"; checksum="$psha"; expected="$psize"
  else
    return 1
  fi

  case "$file" in
    *.tar.gz) archive="$TEMP_ROOT_PARENT/debian-rootfs-${source}.tar.gz"; tar_opt=-xzf ;;
    *.tar.xz) archive="$TEMP_ROOT_PARENT/debian-rootfs-${source}.tar.xz"; tar_opt=-xJf ;;
    *) return 1 ;;
  esac
  echo "[i] 下载 rootfs: $asset_base/$file"
  curl -fL --retry 3 --connect-timeout 15 --max-time 600 "$asset_base/$file" -o "$archive" || return 1
  actual=$(wc -c < "$archive" | tr -d ' ')
  if [ "$actual" != "$expected" ]; then
    echo "[!] ${source} rootfs 大小校验失败: expected=$expected actual=$actual" >&2
    rm -f -- "$archive"; return 1
  fi
  if ! verify_sha256 "$checksum" "$archive"; then
    echo "[!] ${source} rootfs SHA256 校验失败" >&2
    rm -f -- "$archive"; return 1
  fi
  rm -rf -- "$ROOTFS_DIR"; mkdir -p "$ROOTFS_DIR"
  if ! tar "$tar_opt" "$archive" -C "$ROOTFS_DIR"; then
    rm -rf -- "$ROOTFS_DIR"; mkdir -p "$ROOTFS_DIR"; return 1
  fi
  rm -f -- "$archive"
  [ -r "$ROOTFS_DIR/etc/os-release" ] || return 1
  echo "[√] 已使用 ${source} 预构建 rootfs"
}

download_prebuilt() {
  local source
  case "$DEBIAN_ARCH" in amd64|arm64) ;; *) return 1 ;; esac
  for source in $ROOTFS_SOURCE_ORDER; do
    case "$source" in
      github|ibsgss)
        download_prebuilt_from "$source" && return 0
        echo "[!] ${source} 预构建 rootfs 不可用，尝试下一来源" >&2 ;;
    esac
  done
  return 1
}

download_debian_oci() {
  local registry="https://registry-1.docker.io" repository="library/debian"
  local token index platform_line manifest_digest manifest layer_lines layer_count layer_digest layer_file
  echo "[i] 下载官方 Debian ${DEBIAN_SUITE}-slim rootfs"
  token=$(curl -fsSL --retry 3 \
    "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repository}:pull" |
    sed -n 's/.*"token":"\([^"]*\)".*/\1/p') || return 1
  [ -n "$token" ] || return 1
  index=$(curl -fsSL --retry 3 -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    "$registry/v2/$repository/manifests/${DEBIAN_SUITE}-slim") || return 1
  platform_line=$(printf '%s' "$index" | sed 's/},{/}\n{/g' |
    grep "\"platform\":{\"architecture\":\"${OCI_ARCH}\",\"os\":\"linux\"" |
    { if [ -n "$OCI_VARIANT" ]; then grep "\"variant\":\"${OCI_VARIANT}\""; else cat; fi; } | head -n 1) || return 1
  manifest_digest=$(printf '%s' "$platform_line" | sed -n 's/.*"digest":"\(sha256:[^"]*\)".*/\1/p')
  [ -n "$manifest_digest" ] || return 1
  manifest=$(curl -fsSL --retry 3 -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "$registry/v2/$repository/manifests/$manifest_digest") || return 1
  layer_lines=$(printf '%s' "$manifest" | sed 's/},{/}\n{/g' |
    grep -E '"mediaType":"application/vnd\.(oci\.image\.layer\.v1\.tar\+gzip|docker\.image\.rootfs\.diff\.tar\.gzip)"') || return 1
  layer_count=$(printf '%s\n' "$layer_lines" | awk 'NF {c++} END {print c+0}')
  [ "$layer_count" -eq 1 ] || return 1
  layer_digest=$(printf '%s\n' "$layer_lines" | sed -n 's/.*"digest":"\(sha256:[^"]*\)".*/\1/p' | head -n 1)
  [ -n "$layer_digest" ] || return 1
  layer_file="$TEMP_ROOT_PARENT/debian-rootfs.tar.gz"
  curl -fL --retry 3 --connect-timeout 15 --max-time 600 -H "Authorization: Bearer $token" \
    "$registry/v2/$repository/blobs/$layer_digest" -o "$layer_file" || return 1
  verify_sha256 "${layer_digest#sha256:}" "$layer_file" || return 1
  tar -xzf "$layer_file" -C "$ROOTFS_DIR" || return 1
  rm -f -- "$layer_file"
}

build_debian() {
  local archive url_path
  if [ -n "$ROOTFS_URL" ]; then
    archive="$TEMP_ROOT_PARENT/debian-rootfs.tar"
    url_path=${ROOTFS_URL%%[\?#]*}
    case "$url_path" in
      *.tar.gz|*.tgz) archive="$TEMP_ROOT_PARENT/debian-rootfs.tar.gz" ;;
      *.tar.xz)       archive="$TEMP_ROOT_PARENT/debian-rootfs.tar.xz" ;;
      *.tar.zst)      archive="$TEMP_ROOT_PARENT/debian-rootfs.tar.zst" ;;
    esac
    download_extract "$ROOTFS_URL" "$archive" "$ROOTFS_SHA256"
    return
  fi
  download_prebuilt && return
  echo "[!] 预构建 rootfs 不可用，回退官方 Debian OCI" >&2
  download_debian_oci && return
  echo "[!] Debian OCI 下载失败，尝试本地构建" >&2
  rm -rf -- "$ROOTFS_DIR"; mkdir -p "$ROOTFS_DIR"
  if command -v debootstrap >/dev/null 2>&1; then
    echo "[i] 使用 debootstrap 创建 Debian ${DEBIAN_SUITE} rootfs"
    debootstrap --variant=minbase --arch="$DEBIAN_ARCH" "$DEBIAN_SUITE" "$ROOTFS_DIR" \
      "https://deb.debian.org/debian" >/dev/null
    return
  fi
  if command -v docker >/dev/null 2>&1; then
    echo "[i] 未找到 debootstrap，使用 Docker 导出 Debian rootfs"
    DOCKER_IMAGE="debian:${DEBIAN_SUITE}-slim"
    docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1 || DOCKER_REMOVE_IMAGE=1
    DOCKER_CID=$(docker create --platform "$DOCKER_PLATFORM" "$DOCKER_IMAGE" /bin/true) ||
      die "Docker 创建容器失败"
    if ! docker export "$DOCKER_CID" | tar -xf - -C "$ROOTFS_DIR"; then
      docker rm -f "$DOCKER_CID" >/dev/null 2>&1 || true; DOCKER_CID=""
      die "Docker 导出 rootfs 失败"
    fi
    docker rm "$DOCKER_CID" >/dev/null 2>&1 || true; DOCKER_CID=""
    return
  fi
  die "创建 Debian rootfs 需要 debootstrap、Docker，或用 --url 指定 tar 包"
}

canonical_dir() { (CDPATH= cd -- "$1" 2>/dev/null && pwd -P); }
available_kb() { df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4+0}'; }

select_temp_base() {
  local base best="" best_free=0 free
  local -a candidates=()
  [ -n "${SBQUALITY_ROOTFS_TMPDIR:-}" ] && candidates+=("$SBQUALITY_ROOTFS_TMPDIR")
  [ -n "${TMPDIR:-}" ] && candidates+=("$TMPDIR")
  candidates+=("/var/tmp" "/tmp")
  for base in "${candidates[@]}"; do
    [ -d "$base" ] && [ -w "$base" ] || continue
    free=$(available_kb "$base")
    [ "$free" -gt 0 ] || continue
    if [ "$free" -ge "$MIN_ROOTFS_FREE_KB" ]; then printf '%s\n' "$base"; return 0; fi
    if [ "$free" -gt "$best_free" ]; then best="$base"; best_free="$free"; fi
  done
  [ -n "$best" ] || die "没有可写的临时目录"
  echo "[!] 临时目录空间不足 $((MIN_ROOTFS_FREE_KB / 1024))MB，使用最大可用: $best ($((best_free / 1024))MB)" >&2
  printf '%s\n' "$best"
}

validate_rootfs() {
  local resolved rootfs_id
  resolved=$(canonical_dir "$ROOTFS_DIR") || die "无法解析 rootfs 路径: $ROOTFS_DIR"
  case "$resolved" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/var|"$SOURCE_DIR")
      die "拒绝使用危险的 rootfs 路径: $resolved" ;;
  esac
  [ -r "$resolved/etc/os-release" ] || die "rootfs 缺少 /etc/os-release: $resolved"
  rootfs_id=$(sed -n 's/^ID=//p' "$resolved/etc/os-release" | head -n 1)
  rootfs_id=${rootfs_id#\"}; rootfs_id=${rootfs_id%\"}
  [ "$rootfs_id" = debian ] || die "rootfs 类型不匹配: 期望 debian，实际 ${rootfs_id:-unknown}"
  ROOTFS_DIR="$resolved"
}

# 防止 rootfs 内被做成软链的路径把 mount 指到宿主目录
assert_rootfs_path_safe() {
  local allow_symlink="$1" rel path resolved parent
  shift
  for rel in "$@"; do
    path="$ROOTFS_DIR/$rel"
    if [ "$allow_symlink" -eq 0 ] && [ -L "$path" ]; then
      die "rootfs 内 $rel 不能是符号链接: $path"
    fi
    if [ -e "$path" ]; then
      resolved=$(canonical_dir "$path") || die "无法解析: $path"
    else
      parent=$(dirname -- "$path")
      resolved=$(canonical_dir "$parent") || die "无法解析: $parent"
    fi
    case "$resolved/" in
      "$ROOTFS_DIR/"*) ;;
      *) die "rootfs 内路径逃逸: $path -> $resolved" ;;
    esac
  done
}

prepare_rootfs() {
  if [ -n "$ROOTFS_DIR" ]; then
    [ -d "$ROOTFS_DIR" ] || die "rootfs 目录不存在: $ROOTFS_DIR"
    validate_rootfs
    return
  fi
  TEMP_ROOT_PARENT=$(mktemp -d "$(select_temp_base)/sbquality-rootfs.XXXXXX")
  ROOTFS_DIR="$TEMP_ROOT_PARENT/rootfs"
  mkdir -p "$ROOTFS_DIR"
  CREATED_ROOTFS=1
  build_debian
  validate_rootfs
}

mount_guest() {
  RUNTIME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sbquality-runtime.XXXXXX")
  GUEST_TMP_HOST="$RUNTIME_DIR/guest-tmp"
  mkdir -p "$GUEST_TMP_HOST"
  chmod 1777 "$GUEST_TMP_HOST"

  assert_rootfs_path_safe 0 dev proc sys tmp
  assert_rootfs_path_safe 1 root usr usr/local usr/local/bin etc lib
  mkdir -p "$ROOTFS_DIR/dev" "$ROOTFS_DIR/proc" "$ROOTFS_DIR/sys" "$ROOTFS_DIR/tmp"

  mount --rbind /dev "$ROOTFS_DIR/dev" 2>/dev/null || mount --bind /dev "$ROOTFS_DIR/dev"
  MOUNTED+=("$ROOTFS_DIR/dev")
  mount --make-rslave "$ROOTFS_DIR/dev" >/dev/null 2>&1 || true

  mount -t proc proc "$ROOTFS_DIR/proc"; MOUNTED+=("$ROOTFS_DIR/proc")

  mount --rbind /sys "$ROOTFS_DIR/sys" 2>/dev/null || mount --bind /sys "$ROOTFS_DIR/sys"
  MOUNTED+=("$ROOTFS_DIR/sys")
  mount --make-rslave "$ROOTFS_DIR/sys" >/dev/null 2>&1 || true

  mount --bind "$GUEST_TMP_HOST" "$ROOTFS_DIR/tmp"
  MOUNTED+=("$ROOTFS_DIR/tmp")

  # bpftrace 需要宿主的内核模块目录
  if [ -d /lib/modules ]; then
    mkdir -p "$ROOTFS_DIR/lib/modules"
    mount --bind /lib/modules "$ROOTFS_DIR/lib/modules"
    MOUNTED+=("$ROOTFS_DIR/lib/modules")
    mount -o remount,bind,ro "$ROOTFS_DIR/lib/modules" >/dev/null 2>&1 || true
  fi

  mkdir -p "$ROOTFS_DIR/etc"
  rm -f -- "$ROOTFS_DIR/etc/resolv.conf"
  cp -L /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf" 2>/dev/null ||
    printf 'nameserver 1.1.1.1\n' > "$ROOTFS_DIR/etc/resolv.conf"
  [ -e "$ROOTFS_DIR/etc/hosts" ] ||
    printf '127.0.0.1 localhost\n::1 localhost\n' > "$ROOTFS_DIR/etc/hosts"
}

in_guest() {
  env -i HOME=/root "PATH=$GUEST_PATH" TERM=dumb chroot "$ROOTFS_DIR" /bin/bash -c "$1"
}

install_guest_deps() {
  # 预构建 rootfs 已带齐依赖时直接跳过 apt
  if in_guest 'for c in bash curl dig gawk ip iperf3 jq ping nping nc sed ss tar traceroute fio; do command -v "$c" >/dev/null || exit 1; done' 2>/dev/null; then
    echo "[√] rootfs 依赖已就绪"
    return 0
  fi
  local apt_log="$GUEST_TMP_HOST/rootfs-apt.log"
  echo "[i] 正在 rootfs 内安装依赖（首次约需 1-2 分钟）"
  if ! in_guest 'export DEBIAN_FRONTEND=noninteractive
     apt-get update -qq &&
     apt-get install -y -qq --no-install-recommends \
       bash ca-certificates coreutils curl dnsutils findutils fio gawk grep \
       iperf3 iproute2 iputils-ping jq kmod netcat-openbsd nmap ncurses-bin \
       bpftrace sed tar traceroute tzdata &&
     rm -rf /var/lib/apt/lists/*' > "$apt_log" 2>&1; then
    echo "[X] rootfs 依赖安装失败，日志: $apt_log" >&2
    [ "$DEBUG_MODE" -eq 1 ] && tail -n 60 "$apt_log" >&2
    return 1
  fi
}

# 单线程测速需要连接级 TCP_INFO（LD_PRELOAD）与 eBPF 重传去重脚本
ensure_guest_tcp_info() {
  local asset_dir
  asset_dir=$(CDPATH= cd -- "$(dirname -- "$SELF_SCRIPT")" && pwd)

  if [ -r "$ROOTFS_DIR/usr/local/lib/libsbquality-tcpinfo.so" ] &&
     [ -r "$ROOTFS_DIR/usr/local/libexec/sbquality-retrans-seq.bt" ]; then
    echo "[√] TCP_INFO preload 与 eBPF 重传脚本已就绪"
    return 0
  fi
  [ -r "$asset_dir/sbquality-tcpinfo.c" ] || {
    echo "[!] 缺少 sbquality-tcpinfo.c，测速将不带连接级重传统计" >&2
    return 0
  }

  cp -L "$asset_dir/sbquality-tcpinfo.c" "$GUEST_TMP_HOST/sbquality-tcpinfo.c"
  echo "[i] 正在 rootfs 内编译 TCP_INFO preload 库"
  if ! in_guest 'export DEBIAN_FRONTEND=noninteractive
     apt-get update -qq
     apt-get install -y -qq --no-install-recommends gcc libc6-dev binutils
     mkdir -p /usr/local/lib /usr/local/libexec
     gcc -O2 -fPIC -shared -Wl,-z,now \
       -o /usr/local/lib/libsbquality-tcpinfo.so /tmp/sbquality-tcpinfo.c -ldl -pthread
     strip --strip-unneeded /usr/local/lib/libsbquality-tcpinfo.so
     chmod 0644 /usr/local/lib/libsbquality-tcpinfo.so'; then
    echo "[!] 编译 libsbquality-tcpinfo.so 失败，测速将不带连接级重传统计" >&2
    return 0
  fi

  mkdir -p "$ROOTFS_DIR/usr/local/libexec"
  local bt
  for bt in sbquality-retrans-seq.bt sbquality-retrans-skb.bt; do
    [ -r "$asset_dir/$bt" ] || continue
    cp -L "$asset_dir/$bt" "$ROOTFS_DIR/usr/local/libexec/$bt"
    chmod 0644 "$ROOTFS_DIR/usr/local/libexec/$bt"
  done
  rm -f -- "$GUEST_TMP_HOST/sbquality-tcpinfo.c"
  echo "[√] TCP_INFO preload 已就绪"
}

prepare_guest_files() {
  mkdir -p "$ROOTFS_DIR/root/sbquality" "$ROOTFS_DIR/usr/local/bin"
  cp -R "$SOURCE_DIR/sbquality.sh" "$SOURCE_DIR/lib" "$ROOTFS_DIR/root/sbquality/"
  [ -d "$SOURCE_DIR/bin" ] && cp -R "$SOURCE_DIR/bin" "$ROOTFS_DIR/root/sbquality/" || true
  chmod 0755 "$ROOTFS_DIR/root/sbquality/sbquality.sh"
}

mkdir -p "$OUTPUT_DIR" || die "无法创建输出目录: $OUTPUT_DIR"
OUTPUT_DIR=$(canonical_dir "$OUTPUT_DIR") || die "无法解析输出目录: $OUTPUT_DIR"
SOURCE_DIR=$(canonical_dir "$SOURCE_DIR") || die "无法解析源码目录"
prepare_rootfs
case "$OUTPUT_DIR/" in
  "$ROOTFS_DIR/"*) die "输出目录不能位于 rootfs 内部: $OUTPUT_DIR" ;;
esac
mount_guest
install_guest_deps || exit 1
ensure_guest_tcp_info
prepare_guest_files

echo "[i] 进入临时 Debian rootfs；退出后自动清理"
[ "$KEEP_ROOTFS" -eq 1 ] && echo "[i] --keep 已启用，rootfs 保留于: $ROOTFS_DIR"

guest_term="${TERM:-dumb}"
case "$guest_term" in xterm-ghostty) guest_term=xterm ;; "") guest_term=dumb ;; esac

guest_env=(
  HOME=/root
  "PATH=$GUEST_PATH"
  LANG=C.UTF-8
  LC_ALL=C.UTF-8
  "TERM=$guest_term"
  SBQUALITY_INSIDE_ROOTFS=1
)
for env_name in SBQUALITY_GET_NODES_URL SBQUALITY_ROUTE_ASN_API SBQUALITY_PACKETS \
  HTTP_PROXY HTTPS_PROXY NO_PROXY ALL_PROXY http_proxy https_proxy no_proxy all_proxy; do
  [ "${!env_name+x}" = x ] && guest_env+=("$env_name=${!env_name}")
done

set +e
env -i "${guest_env[@]}" chroot "$ROOTFS_DIR" \
  /bin/bash /root/sbquality/sbquality.sh "$@"
guest_rc=$?
set -e
persist_guest_outputs
exit "$guest_rc"
