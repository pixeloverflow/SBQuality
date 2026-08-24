#!/usr/bin/env bash
#
# SBQuailty 自检脚本
#
# 不做任何网络探测，只验证：
#   1. 所有 shell 文件能被 bash 解析
#   2. 函数名在模块间没有冲突
#   3. 四种报告（TUI / 纯文本 / JSON / Markdown / HTML）都能用假数据渲染出来
#   4. 生成的 JSON 合法（有 jq 时）
#
# 用法: bash selfcheck.sh

cd "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)" || exit 1

FAIL=0
pass() { printf '  \033[0;32m[√]\033[0m %s\n' "$*"; }
fail() { printf '  \033[0;31m[X]\033[0m %s\n' "$*"; FAIL=1; }
info() { printf '  \033[2m%s\033[0m\n' "$*"; }

echo
echo "SBQuailty 自检"
echo "---------------------------------"

# ---- 1. 语法 ----
echo
echo "1. 语法解析"
syntax_ok=1
for f in sbquality.sh lib/*.sh assets/rootfs.sh selfcheck.sh; do
  [ -f "$f" ] || continue
  if err=$(bash -n "$f" 2>&1); then
    pass "$f"
  else
    fail "$f"
    printf '%s\n' "$err" | sed 's/^/      /'
    syntax_ok=0
  fi
done
if [ "$syntax_ok" -eq 0 ]; then
  echo
  echo "语法错误必须先修掉，后续检查跳过。"
  exit 1
fi

# ---- 2. 命名冲突 ----
echo
echo "2. 模块间函数名冲突"
dupes=$(grep -ohE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' lib/*.sh sbquality.sh 2>/dev/null | sort | uniq -d)
if [ -z "$dupes" ]; then
  pass "无重复函数名"
else
  fail "存在重复函数名："
  printf '%s\n' "$dupes" | sed 's/^/      /'
fi

# ---- 3. 报告渲染 ----
echo
echo "3. 报告渲染（--dry-run 假数据）"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/sbquality-selfcheck.XXXXXX") || exit 1
trap 'rm -rf -- "$tmp"' EXIT

if out=$(bash sbquality.sh --dry-run \
           -o "$tmp/r.txt" --json "$tmp/r.json" --html "$tmp/r.html" --md "$tmp/r.md" 2>&1); then
  pass "sbquality.sh --dry-run 退出码 0"
else
  fail "sbquality.sh --dry-run 失败："
  printf '%s\n' "$out" | tail -n 20 | sed 's/^/      /'
fi

for ext in txt json html md; do
  if [ -s "$tmp/r.$ext" ]; then
    pass "生成 r.$ext（$(wc -c < "$tmp/r.$ext" | tr -d ' ') 字节）"
  else
    fail "未生成 r.$ext 或为空"
  fi
done

# 结构完整性：退出码为 0 不代表内容成形，这里抽查各格式的收尾标记
if [ -s "$tmp/r.html" ]; then
  grep -q '</html>' "$tmp/r.html" && pass "HTML 结构完整" || fail "HTML 缺少结束标签"
fi
if [ -s "$tmp/r.md" ]; then
  grep -q '^# SBQuailty' "$tmp/r.md" && pass "Markdown 有标题" || fail "Markdown 缺少标题"
fi

# ---- 4. 表格对齐目视检查 ----
# CJK 全角字符的列宽计算是最容易出错、又完全无法用退出码发现的地方，
# 所以把渲染结果打出来让人眼确认一遍。
echo
echo "4. 表格对齐（请目视确认竖线/列边界是否对齐）"
if [ -s "$tmp/r.txt" ]; then
  sed -n '/单线程测速/,/^$/p' "$tmp/r.txt" | head -n 8 | sed 's/^/    /'
  echo
  sed -n '/回程线路识别/,/^$/p' "$tmp/r.txt" | head -n 8 | sed 's/^/    /'
else
  info "无纯文本报告，跳过"
fi

# ---- 5. JSON 合法性 ----
echo
echo "5. JSON 合法性"
if command -v jq >/dev/null 2>&1; then
  if [ -s "$tmp/r.json" ] && jq empty "$tmp/r.json" >/dev/null 2>&1; then
    pass "JSON 通过 jq 校验"
    info "顶层键: $(jq -r 'keys | join(", ")' "$tmp/r.json" 2>/dev/null)"
  else
    fail "JSON 不合法"
    [ -s "$tmp/r.json" ] && jq empty "$tmp/r.json" 2>&1 | sed 's/^/      /'
  fi
else
  info "未安装 jq，跳过 JSON 校验"
fi

# ---- 6. 帮助信息 ----
echo
echo "6. 帮助信息"
if bash sbquality.sh -h >/dev/null 2>&1; then
  pass "sbquality.sh -h 正常"
else
  fail "sbquality.sh -h 失败"
fi

echo
echo "---------------------------------"
if [ "$FAIL" -eq 0 ]; then
  printf '  \033[0;32m全部通过\033[0m\n\n'
  exit 0
fi
printf '  \033[0;31m存在失败项，见上\033[0m\n\n'
exit 1
