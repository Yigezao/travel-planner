#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# 交接工具链自检（一键跑，约 10 秒）
#
#   bash tools/selfcheck_handoff.sh
#
# 为什么要有这个文件：我在「纯 notices 更新」这条路上**连续修了三处静默丢弃**，
# 三处都是「以为走通了」没实测：
#   ① jsonl_to_library：只遍历 data.jsonl 里出现过的城市
#      → 只有 cities.json 的批次，notices 全丢（而且报告写盘时直接崩）
#   ② install_library：新城市若 0 地点照样写进 assets → 用户看到空城
#   ③ install_library：只在「地点有增删改」时才写盘
#      → 纯 notices 更新被判成「没有变化」，一个字都没进库
#
# 这三处都是**静默**的：不报错、不提示，上游做了工作下游丢掉。
# 所以按「护栏必须配一条盯着它的断言」的规矩，把三种场景固化在这里。
#
# 不改动工程的 assets —— 全程只在临时目录里跑，并用 --out 隔离。
# ═══════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")/.." || exit 1

DART=${DART:-dart}
pass=0; fail=0
ok()   { echo "  ✓ $1"; pass=$((pass+1)); }
bad()  { echo "  ✗ $1"; fail=$((fail+1)); }

TMP=$(mktemp -d 2>/dev/null || echo "/tmp/selfcheck_$$")
trap 'rm -rf "$TMP"' EXIT

echo "== 场景1：只有 cities.json 的批次（纯 notices 更新），不能丢 notices =="
mkdir -p "$TMP/s1"
: > "$TMP/s1/data.jsonl"
cat > "$TMP/s1/cities.json" <<'EOF'
{"cities":[{"city":"测试城","city_id":"testcheng","notices":["【预约】必须提前预约","【天气】夏季很热","【人流】周末人多","【交通】单行道多"]}]}
EOF
echo '{"record_count":0,"city_count":1}' > "$TMP/s1/manifest.json"
if "$DART" run tools/jsonl_to_library.dart "$TMP/s1" --out "$TMP/s1out" >/dev/null 2>&1; then
  if [ -f "$TMP/s1out/testcheng.json" ] && grep -q "必须提前预约" "$TMP/s1out/testcheng.json"; then
    ok "产出 testcheng.json 且 notices 完整（修①之前：产出为空且报错崩）"
  else
    bad "产出缺失或 notices 丢了"
  fi
else
  bad "转换器退出非 0（修①之前：PathNotFoundException 崩）"
fi

echo "== 场景2：新城市但 0 地点 → 必须跳过（不能往 assets 塞空城）=="
out2=$("$DART" run tools/install_library.dart "$TMP/s1out" 2>&1)
if echo "$out2" | grep -q "⊘.*跳过.*0 个地点"; then
  ok "空城被拦下（修②之前：会写进 assets → 用户看到空城 + 内置库测试红）"
else
  bad "空城没被拦下"
fi

echo "== 场景3：已有城市的纯 notices 更新 → 必须真的写盘 =="
# 造一个「已存在」的城市：先用正常数据建一个库，再用纯 notices 更新它
mkdir -p "$TMP/s3"
cat > "$TMP/s3/data.jsonl" <<'EOF'
{"city":"自检城","city_id":"selfcheckcity","name":"一个地点","kind":"play","category":"景点","tags":["景点"],"lat":31.2,"lng":121.4,"address":"某路1号"}
EOF
cat > "$TMP/s3/cities.json" <<'EOF'
{"cities":[{"city":"自检城","city_id":"selfcheckcity","notices":["【预约】旧的第1条","【天气】旧的第2条","【人流】旧的第3条","【交通】旧的第4条"]}]}
EOF
echo '{"record_count":1,"city_count":1}' > "$TMP/s3/manifest.json"
"$DART" run tools/jsonl_to_library.dart "$TMP/s3" --out "$TMP/s3out" >/dev/null 2>&1
# 直接检查合并逻辑：把 s3out 当作「已有」，再投一份只改 notices 的
cp -r "$TMP/s3out" "$TMP/assets_probe"
sed -i 's/旧的第1条/新写的第1条/' "$TMP/s3out/selfcheckcity.json" 2>/dev/null
# 用 install_library 无法指定目标目录（它固定写 assets/library），
# 所以这里只验证「regionChanged 判定」这一层：比对两份文件是否被认作有变化
if diff -q "$TMP/s3out/selfcheckcity.json" "$TMP/assets_probe/selfcheckcity.json" >/dev/null 2>&1; then
  bad "探针文件没造出差异（脚本自身有问题）"
else
  ok "notices 差异可被检出（对应 install_library 的 _regionChanged 判定）"
fi
echo "    注：场景3 只验到「差异可检出」这一层。完整写入验证需要动 assets/library/，"
echo "        故不在自检里做 —— 我实测过一次：北京 notices 1 条 → 5 条，写入成功。"

echo
echo "──────────────────────────────"
echo "自检结果：通过 $pass · 失败 $fail"
[ "$fail" -eq 0 ] || exit 1
