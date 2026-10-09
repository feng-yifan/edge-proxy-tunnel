#!/usr/bin/env bash
#
# 混淆 Cloudflare Worker 入口文件（edgetunnel 的 _worker.js）
#
# 用法:
#   scripts/obfuscate-worker.sh <输入文件> <输出文件> [seed]
#
# 环境变量:
#   OBFUSCATOR_BIN     javascript-obfuscator 可执行文件路径（默认从 PATH 取）
#   OBFUSCATE_CONFIG   混淆配置路径（默认仓库根 obfuscate.config.json）
#
# 说明:
#   - 输出只保留混淆后的代码：源文件里的注释（含上游用来伪装的 4.8MB 注释）会被丢弃
#   - 配置里 target=browser-no-eval：Cloudflare Workers 运行时禁止 eval/new Function
#   - 混淆完做 ESM 语法检查（源文件用 export default），并确认入口仍在
#
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "用法: scripts/obfuscate-worker.sh <输入文件> <输出文件> [seed]" >&2
  exit 2
fi

INPUT=$1
OUTPUT=$2
SEED=${3:-}

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONFIG=${OBFUSCATE_CONFIG:-$ROOT/obfuscate.config.json}
BIN=${OBFUSCATOR_BIN:-javascript-obfuscator}

[ -f "$INPUT" ] || { echo "[错误] 找不到输入文件: $INPUT" >&2; exit 1; }
[ -f "$CONFIG" ] || { echo "[错误] 找不到混淆配置: $CONFIG" >&2; exit 1; }
if ! command -v "$BIN" >/dev/null 2>&1 && [ ! -x "$BIN" ]; then
  echo "[错误] 找不到 javascript-obfuscator: $BIN" >&2
  exit 1
fi
command -v node >/dev/null 2>&1 || { echo "[错误] 找不到 node" >&2; exit 1; }

ARGS=("$INPUT" --config "$CONFIG" --advertisement false)
if [ -n "$SEED" ]; then
  ARGS+=(--seed "$SEED")
fi

echo "[混淆] 输入: $INPUT ($(wc -c < "$INPUT") 字节)"
echo "[混淆] 配置: $CONFIG"
echo "[混淆] seed: ${SEED:-<由工具随机生成>}"

# javascript-obfuscator 的 --output 只在以 .js/.mjs 结尾时才当文件，否则会把该路径当目录
# 并在其中写一个同名文件；这里先落到临时 .js 文件，再移动到调用方指定的路径。
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/obfuscate-XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT
TMP_OUT="$WORK_DIR/obfuscated.js"

"$BIN" "${ARGS[@]}" --output "$TMP_OUT"

if [ ! -f "$TMP_OUT" ] || [ ! -s "$TMP_OUT" ]; then
  echo "[错误] 混淆产物为空或不是文件: $TMP_OUT" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
mv "$TMP_OUT" "$OUTPUT"

# ESM 语法检查：_worker.js 是 ES module（export default），必须按 module 解析
if ! node --input-type=module --check < "$OUTPUT"; then
  echo "[错误] 混淆产物语法检查失败" >&2
  exit 1
fi

if ! grep -q 'export default' "$OUTPUT"; then
  echo "[错误] 混淆产物缺少 export default 入口" >&2
  exit 1
fi

SIZE_IN=$(wc -c < "$INPUT")
SIZE_OUT=$(wc -c < "$OUTPUT")
echo "[混淆] 输出: $OUTPUT ($SIZE_OUT 字节，源文件 $SIZE_IN 字节)"
echo "[混淆] ✅ 语法检查通过，export default 入口保留"
