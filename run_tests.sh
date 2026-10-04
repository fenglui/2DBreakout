#!/usr/bin/env bash
#
# 一键验证：资源导入 + --check-only 静态门禁 + 无头冒烟测试（Linux / macOS / CI 版）。
# Windows 下请用同目录的 run_tests.ps1，行为与退出码完全一致。
# 第 0 步的 --import 用于生成 class_name 全局类缓存，全新检出的仓库必须有它。
#
# 用法：
#   ./run_tests.sh              静态检查 + 冒烟测试
#   ./run_tests.sh --strict     GDScript warning 也计为失败
#   ./run_tests.sh --skip-smoke 只做静态检查
#   ./run_tests.sh --detailed   打印 Godot 完整输出
#   ./run_tests.sh --windowed   追加窗口运行冒烟（音频开播路径，需要显示器）
#
# 退出码：0 全部通过 / 1 检查失败 / 2 未找到 Godot
#
# Godot 查找顺序：$GODOT_PATH -> PATH 中的 godot/godot4/godot-console
#                 -> 项目目录及其上两级、~/Downloads、~/.local/bin、/usr/local/bin、/opt

set -u

STRICT=0
SKIP_SMOKE=0
DETAILED=0
WINDOWED=0

for arg in "$@"; do
	case "$arg" in
		--strict) STRICT=1 ;;
		--skip-smoke) SKIP_SMOKE=1 ;;
		--detailed) DETAILED=1 ;;
		--windowed) WINDOWED=1 ;;
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

# ---------- 0. 资源导入 ----------
# class_name 的全局类缓存（.godot/global_script_class_cache.cfg）由 Godot 的导入流程生成。
# 全新检出的仓库没有 .godot/，此时 --check-only 会因为找不到跨脚本引用的 class_name 而报错，
# 因此先跑一次导入（CI 与新克隆的本地环境都依赖这一步）。
echo "== 0/2 资源导入（生成 class_name 全局类缓存）=="
import_out="$("$GODOT" --headless --path . --import 2>&1)"
if [ ! -f ".godot/global_script_class_cache.cfg" ]; then
	printf '%s\n' "$import_out" | sed 's/^/        /'
	echo "导入失败：未能生成 .godot/global_script_class_cache.cfg" >&2
	exit 1
fi
echo "  OK"
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

if [ "$smoke_exit" -ne 0 ]; then
	echo "冒烟测试失败（Godot 退出码 $smoke_exit）。" >&2
	exit 1
fi

# ---------- 3. 窗口运行冒烟（--windowed 才跑）----------
# 无头模式下音频驱动是 Dummy，Sfx 在 play() 里直接返回，播放器根本不创建，
# 「开播」这条路径完全不被执行。GDScript 对 native 方法/属性的调用是运行时检查：
# 调用不存在的 native 方法（AudioStreamGenerator.get_playback）或属性
# （AudioStreamPlayer.playback_mode）都能通过 --check-only，运行时才抛错，
# 而 _ready() 一旦中断，播放器就永远不会开播——表现为「所有平台都没有音效」。
# 这两次事故都是带窗口运行才暴露的，所以提供这一步作为音频路径的自动化兜底。
# 需要显示器，CI 默认不跑。
if [ "$WINDOWED" -eq 1 ]; then
	echo "== 3/3 窗口运行冒烟（音频开播路径，需要显示器）=="
	tmp="$(mktemp -t 2dbreakout_windowed.XXXXXX)"
	"$GODOT" --path . --quit-after 300 >"$tmp" 2>&1
	run_exit=$?
	bad=""
	for pat in "SCRIPT ERROR" "Failed to instantiate an autoload" "Failed to load script" \
		"cannot be sampled" "Leaked instance" "ObjectDB instances leaked"; do
		if grep -qF "$pat" "$tmp"; then bad="$bad $pat"; fi
	done
	if [ "$run_exit" -ne 0 ]; then bad="$bad Godot退出码$run_exit"; fi
	rm -f "$tmp"
	if [ -z "$bad" ]; then
		echo "  OK    窗口运行 300 帧：无脚本错误、无 autoload 失败、无音频开播错误、无泄漏"
	else
		echo "  FAIL  窗口运行发现问题：$bad" >&2
		"$GODOT" --path . --quit-after 300 2>&1 | grep -E "SCRIPT ERROR|at:|autoload|sample|Leaked|^ERROR" | head -12 | sed 's/^/        /' >&2
		exit 1
	fi
	echo ""
fi

echo "全部通过。"
exit 0
