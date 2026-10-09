#!/usr/bin/env bash
#
# 混淆前后「行为等价」冒烟测试
#
# 用本地 workerd（wrangler dev）分别拉起原始 worker 与混淆后的 worker，
# 对同一组端点发同样的请求，逐条比较状态码 / 响应体积 / 响应内容哈希。
#
# 用法:
#   scripts/worker-smoke-test.sh <原始worker> <混淆后worker> [工作目录]
#
# 环境变量:
#   WRANGLER_BIN    wrangler 可执行文件路径（默认从 PATH 取）
#   SMOKE_KEEP=1    保留工作目录（排查用）
#   SMOKE_PORT_A / SMOKE_PORT_B  两个实例的本地端口（默认 8901 / 8902）
#
# 说明:
#   断言的是「两个版本行为一致」，不是绝对正确性：两个版本都依赖同一个外部站点
#   （edgetunnel 的 Pages静态页面），外部不可用时两边一起失败，等价性依然成立。
#   响应天然带时间戳的端点（日志 JSON）只比较状态码与体积。
#
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "用法: scripts/worker-smoke-test.sh <原始worker> <混淆后worker> [工作目录]" >&2
  exit 2
fi

ORIG=$(realpath "$1")
OBF=$(realpath "$2")
WORK=${3:-$(mktemp -d /tmp/worker-smoke-XXXXXX)}
WRANGLER_BIN=${WRANGLER_BIN:-wrangler}
PORT_A=${SMOKE_PORT_A:-8901}
PORT_B=${SMOKE_PORT_B:-8902}
ADMIN_PASS='smoke-admin-pass'
# 响应含时间戳等动态内容的探测点（只比状态码与体积，不比哈希）
DYNAMIC_PROBES=${DYNAMIC_PROBES:-'admin-log'}

for f in "$ORIG" "$OBF"; do
  [ -f "$f" ] || { echo "[错误] 找不到文件: $f" >&2; exit 1; }
done
if ! command -v "$WRANGLER_BIN" >/dev/null 2>&1 && [ ! -x "$WRANGLER_BIN" ]; then
  echo "[错误] 找不到 wrangler: $WRANGLER_BIN" >&2
  exit 1
fi
command -v curl >/dev/null 2>&1 || { echo "[错误] 找不到 curl" >&2; exit 1; }

mkdir -p "$WORK"
WPID=''

cleanup() {
  if [ -n "$WPID" ]; then
    kill -TERM "-$WPID" 2>/dev/null || kill -TERM "$WPID" 2>/dev/null || true
    sleep 1
    kill -KILL "-$WPID" 2>/dev/null || kill -KILL "$WPID" 2>/dev/null || true
  fi
  if [ "${SMOKE_KEEP:-0}" != "1" ]; then
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

# 发一个探测请求并记录结果
# probe <工作目录> <base> <探测名> <方法> <路径> [curl 附加参数...]
probe() {
  local out=$1 base=$2 name=$3 method=$4 path=$5
  shift 5
  local code size md5
  code=$(curl -skS -m 30 -o "$out/$name.body" -w '%{http_code}' \
    -X "$method" "$@" "$base$path" 2>"$out/$name.curl.err") || code=000
  size=$(wc -c < "$out/$name.body" 2>/dev/null || echo 0)
  md5=$(md5sum "$out/$name.body" 2>/dev/null | awk '{print $1}')
  printf '%s %s %s status=%s size=%s md5=%s\n' "$name" "$method" "$path" "$code" "$size" "$md5" \
    >> "$out/summary.txt"
}

# run_one <worker文件> <端口> <工作目录> <标签>
run_one() {
  local worker=$1 port=$2 out=$3 label=$4
  mkdir -p "$out"
  cat > "$out/wrangler.toml" <<EOF
name = "worker-smoke"
main = "$worker"
compatibility_date = "2025-11-04"

[vars]
ADMIN = "$ADMIN_PASS"

[[kv_namespaces]]
binding = "KV"
id = "smoke"
EOF

  echo "[冒烟] 启动 $label（$worker，端口 $port）..."
  ( cd "$out" && CI=true exec setsid "$WRANGLER_BIN" dev \
      --port "$port" --ip 127.0.0.1 --local-protocol https ) > "$out/wrangler.log" 2>&1 &
  WPID=$!

  local i ready=0
  for i in $(seq 1 90); do
    if grep -q "Ready on" "$out/wrangler.log" 2>/dev/null; then ready=1; break; fi
    kill -0 "$WPID" 2>/dev/null || break
    sleep 1
  done
  if [ "$ready" != "1" ]; then
    echo "[错误] $label 的 wrangler dev 启动失败，日志尾部：" >&2
    tail -n 30 "$out/wrangler.log" >&2 || true
    return 1
  fi

  local base="https://127.0.0.1:$port"
  : > "$out/summary.txt"

  probe "$out" "$base" root GET "/"
  probe "$out" "$base" admin-noauth GET "/admin"
  probe "$out" "$base" login-page GET "/login"
  probe "$out" "$base" robots GET "/robots.txt"
  probe "$out" "$base" login-bad POST "/login" \
    -H 'Content-Type: application/x-www-form-urlencoded' --data 'password=wrong-password'

  # 正确密码登录，拿到 auth cookie 后访问需要鉴权的端点
  local code headers="$out/login-ok.headers"
  code=$(curl -skS -m 30 -D "$headers" -o "$out/login-ok.body" -w '%{http_code}' \
    -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
    --data "password=$ADMIN_PASS" "$base/login") || code=000
  printf 'login-ok POST /login status=%s size=%s md5=%s\n' \
    "$code" "$(wc -c < "$out/login-ok.body")" "$(md5sum "$out/login-ok.body" | awk '{print $1}')" \
    >> "$out/summary.txt"

  local cookie
  cookie=$(grep -oiE 'set-cookie: *auth=[^;]+' "$headers" 2>/dev/null | head -1 \
    | sed -E 's/.*(auth=[^;]+).*/\1/') || true
  if [ -z "$cookie" ]; then
    echo "[错误] $label：登录未返回 auth cookie，无法继续鉴权探测" >&2
    return 1
  fi

  probe "$out" "$base" admin-auth GET "/admin" -H "Cookie: $cookie"
  probe "$out" "$base" admin-log GET "/admin/log.json" -H "Cookie: $cookie"
  probe "$out" "$base" sub-auth GET "/sub?token=smoke" -H "Cookie: $cookie"

  kill -TERM "-$WPID" 2>/dev/null || kill -TERM "$WPID" 2>/dev/null || true
  wait "$WPID" 2>/dev/null || true
  WPID=''
  echo "[冒烟] $label 探测完成：$(wc -l < "$out/summary.txt") 个端点"
}

run_one "$ORIG" "$PORT_A" "$WORK/orig" "原始版"
run_one "$OBF" "$PORT_B" "$WORK/obf" "混淆版"

keep_strict() { grep -vE "^($DYNAMIC_PROBES) " "$1"; }
keep_dynamic() { grep -E "^($DYNAMIC_PROBES) " "$1" | sed -E 's/ md5=[0-9a-f]+//'; }

echo
echo "===== 原始版 ====="; cat "$WORK/orig/summary.txt"
echo "===== 混淆版 ====="; cat "$WORK/obf/summary.txt"
echo

ok=1
if ! diff -u <(keep_strict "$WORK/orig/summary.txt") <(keep_strict "$WORK/obf/summary.txt") > "$WORK/diff.strict"; then
  echo "[冒烟] ❌ 两版响应不一致：" >&2
  cat "$WORK/diff.strict" >&2
  ok=0
fi
if ! diff -u <(keep_dynamic "$WORK/orig/summary.txt") <(keep_dynamic "$WORK/obf/summary.txt") > "$WORK/diff.dynamic"; then
  echo "[冒烟] ❌ 动态端点的状态码/体积不一致：" >&2
  cat "$WORK/diff.dynamic" >&2
  ok=0
fi

[ "$ok" = "1" ] || exit 1

echo "[冒烟] ✅ 混淆前后行为一致（状态码 / 体积 / 内容哈希）"
exit 0
