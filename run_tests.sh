#!/usr/bin/env bash
#
# 一键验证：--check-only 静态门禁 + 无头冒烟测试（Linux / macOS / CI 版）。
# Windows 下请用同目录的 run_tests.ps1，行为与退出码完全一致。
#
# 用法：
#   ./run_tests.sh              静态检查 + 冒烟测试
#   ./run_tests.sh --strict     GDScript warning 也计为失败
#   ./run_tests.sh --skip-smoke 只做静态检查
#   ./run_tests.sh --detailed   打印 Godot 完整输出
#
# 退出码：0 全部通过 / 1 检查失败 / 2 未找到 Godot
#
# Godot 查找顺序：$GODOT_PATH -> PATH 中的 godot/godot4/godot-console
#                 -> 项目目录及其上两级、~/Downloads、~/.local/bin、/usr/local/bin、/opt

set -u

STRICT=0
SKIP_SMOKE=0
DETAILED=0

for arg in "$@"; do
	case "$arg" in
		--strict) STRICT=1 ;;
		--skip-smoke) SKIP_SMOKE=1 ;;
		--detailed) DETAILED=1 ;;
		-h|--help) sed -n '2,20p' "$0"; exit 0 ;;
		*) echo "未知参数：$arg" >&2; exit 2 ;;
	esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT" || exit 2

find_godot() {
	if [ -n "${GODOT_PATH:-}" ] && [ -x "${GODOT_PATH}" ]; then
		printf '%s' "$GODOT_PATH"
		return 0
	fi
	local name
	for name in godot godot4 godot-console; do
		if command -v "$name" >/dev/null 2>&1; then
			command -v "$name"
			return 0
		fi
	done
	local dir hit
	for dir in "$ROOT" "$ROOT/.." "$ROOT/../.." "$HOME/Downloads" "$HOME/.local/bin" /usr/local/bin /opt; do
		[ -d "$dir" ] || continue
		hit="$(find "$dir" -maxdepth 3 -type f -iname 'godot*' -perm -u+x 2>/dev/null | sort | head -n 1)"
		if [ -n "$hit" ]; then
			printf '%s' "$hit"
			return 0
		fi
	done
	return 1
}

echo "2DBreakout 一键验证"
echo "项目目录: $ROOT"

GODOT="$(find_godot)"
if [ -z "${GODOT:-}" ]; then
	echo ""
	echo "未找到 Godot 可执行文件。" >&2
	echo "请安装 Godot 4.7，或设置环境变量 GODOT_PATH 指向 Godot 可执行文件后重试。" >&2
	exit 2
fi
echo "Godot:     $GODOT"
echo ""

# ---------- 1. 静态门禁 ----------
echo "== 1/2 静态检查（--check-only）=="
errors=0
warnings=0
checked=0

for f in scripts/*.gd tests/*.gd; do
	[ -f "$f" ] || continue
	checked=$((checked + 1))
	out="$("$GODOT" --headless --path . --check-only --script "res://$f" 2>&1)"

	if printf '%s' "$out" | grep -q "SCRIPT ERROR"; then
		errors=$((errors + 1))
		echo "  FAIL  $f"
		printf '%s\n' "$out" | grep -E "SCRIPT ERROR|at:|Parse" | sed 's/^/        /'
	elif printf '%s' "$out" | grep -qE "^WARNING:"; then
		warnings=$((warnings + 1))
		if [ "$STRICT" -eq 1 ]; then
			echo "  FAIL  $f（warning，--strict）"
		else
			echo "  WARN  $f"
		fi
		printf '%s\n' "$out" | grep -E "WARNING|at:" | sed 's/^/        /'
	else
		echo "  OK    $f"
	fi
	if [ "$DETAILED" -eq 1 ]; then
		printf '%s\n' "$out" | sed 's/^/        /'
	fi
done

echo "  共 $checked 个脚本：$errors 个错误，$warnings 个警告$( [ "$STRICT" -eq 1 ] && echo "（--strict：警告计为失败）" )"
echo ""

if [ "$errors" -gt 0 ] || { [ "$STRICT" -eq 1 ] && [ "$warnings" -gt 0 ]; }; then
	echo "静态门禁未通过，已跳过冒烟测试。" >&2
	exit 1
fi
echo "静态门禁通过。"
echo ""

# ---------- 2. 冒烟测试 ----------
if [ "$SKIP_SMOKE" -eq 1 ]; then
	echo "已按 --skip-smoke 跳过冒烟测试。"
	exit 0
fi

echo "== 2/2 无头冒烟测试 =="
"$GODOT" --headless --path . --script res://tests/headless_smoke_test.gd
smoke_exit=$?
echo ""

if [ "$smoke_exit" -eq 0 ]; then
	echo "全部通过。"
	exit 0
fi

echo "冒烟测试失败（Godot 退出码 $smoke_exit）。" >&2
exit 1
