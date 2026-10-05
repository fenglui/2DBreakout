"""UI 字体子集核算与重建。

扫描规则必须与 tests/headless_smoke_test.gd 的 _scan_ui_characters /
_is_ui_glyph_candidate 逐条一致，否则这里报「齐了」而冒烟测试仍报缺字：

  - 只扫 scripts/ 与 scenes/ 下的 .gd / .tscn（tests/ 里的断言文案不上屏）；
  - 只看**成对双引号之间**的内容（项目里没有转义引号），注释里的引号也算，
    因为实现就是纯 find('"') 配对、不做词法分析——扫宽一点只会让子集略胖，
    比漏字安全；
  - 只收 U+3000-303F、U+4E00-9FFF、U+FF00-FFEF 三段。

为什么需要这个工具：Web 构建没有系统字体回退，缺一个字形就是屏幕上一个大 □，
而冒烟测试跑在桌面版上、有系统字体回退，**看不见这个问题**。所以每次改 UI 文案
都要跑一遍本脚本 + 一次冒烟测试。

重建时取的是「现有子集 ∪ 本次需要」的并集，**不是**「只要本次需要的」：
扫不到的显示路径（动态拼串、历史文案里删掉的字）不该因为一次重建就被从字体里删掉，
那会把一个当前的 □ 换成另一个当前的 □——从绿变红的风险比反过来更大。
并集是单调的：字形只增不减。

用法：
    python tools/check_font_subset.py            # 只报告
    python tools/check_font_subset.py --write    # 顺带重建子集
"""

from __future__ import annotations

import sys
from pathlib import Path

from fontTools import subset
from fontTools.ttLib import TTFont

PROJECT_ROOT = Path(__file__).resolve().parent.parent
FONT_PATH = PROJECT_ROOT / "fonts" / "ui-font.otf"
SCAN_DIRS = ("scripts", "scenes")
SCAN_SUFFIXES = (".gd", ".tscn")

# 与 U+3000-303F、U+4E00-9FFF、U+FF00-FFEF 保持一致。
GLYPH_RANGES = ((0x3000, 0x303F), (0x4E00, 0x9FFF), (0xFF00, 0xFFEF))

# 源字体候选，按优先级。必须与子集同族同字重（Regular、CFF/OTTO），
# 否则重建等于换了款字体：缺字是没了，但全部 300 多个既有字形的字宽与笔形都变了。
SOURCE_FONTS = (
    Path(r"C:\Windows\Fonts\Noto Sans SC (TrueType).otf"),
    Path(r"C:\Windows\Fonts\NotoSansSC-VF.ttf"),
)

# 保留全部 OpenType 布局特性。HUD 的分数与生命用等宽数字对齐、
# 中英混排的基线都依赖 GSUB/GPOS。默认的特性白名单只有几十项，
# 子集化会把其余特性连同它们的 lookup 一起丢掉，症状是「某个字在别的机器上间距不对」。
# 注意这是 Subsetter 的 **options**，不是 populate() 的参数——
# fontTools 把这两件事分开了，误传成 populate(layout_features=...) 会直接 TypeError。
LAYOUT_FEATURES = "*"


def is_candidate(code: int) -> bool:
    return any(lo <= code <= hi for lo, hi in GLYPH_RANGES)


def scan_text(text: str) -> set[int]:
    """从一段文本里收集成对双引号之间的候选码位。"""
    found: set[int] = set()
    pos = 0
    while True:
        open_at = text.find('"', pos)
        if open_at < 0:
            return found
        close_at = text.find('"', open_at + 1)
        if close_at < 0:
            return found
        pos = close_at + 1
        for char in text[open_at + 1:close_at]:
            if is_candidate(ord(char)):
                found.add(ord(char))


def collect_needed() -> set[int]:
    needed: set[int] = set()
    for dirname in SCAN_DIRS:
        for path in sorted((PROJECT_ROOT / dirname).iterdir()):
            if path.suffix not in SCAN_SUFFIXES:
                continue
            # errors="replace" 对齐 Godot 的宽松解码：坏字节不会让整个核算崩掉。
            needed |= scan_text(path.read_text(encoding="utf-8-sig", errors="replace"))
    return needed


def pick_source(unicodes: set[int]) -> Path | None:
    """找一个盖住全部目标码位的同族 Regular 源字体。"""
    for candidate in SOURCE_FONTS:
        if not candidate.exists():
            continue
        if unicodes <= set(TTFont(candidate, lazy=True).getBestCmap()):
            return candidate
    return None


def main() -> int:
    needed = collect_needed()
    current = set(TTFont(FONT_PATH).getBestCmap())
    missing = sorted(needed - current)

    print(f"界面文案需要 {len(needed)} 个码位")
    print(f"当前子集含   {len(current)} 个码位")
    print(f"缺失         {len(missing)} 个")
    if missing:
        print("缺字：" + " ".join(f"{chr(c)} U+{c:04X}" for c in missing))

    if "--write" not in sys.argv:
        return 1 if missing else 0
    if not missing:
        print("子集已齐，无需重建")
        return 0
    return rebuild(needed)


def rebuild(needed: set[int]) -> int:
    """按「现有 ∪ 需要」重建子集。只增不减。"""
    unicodes = set(TTFont(FONT_PATH).getBestCmap()) | needed
    source = pick_source(unicodes)
    if source is None:
        print("找不到盖住全部目标码位的同族源字体，未改动 ui-font.otf")
        print("已知候选：" + ", ".join(str(p) for p in SOURCE_FONTS))
        return 1

    font = TTFont(source)
    options = subset.Options()
    options.layout_features = LAYOUT_FEATURES
    subsetter = subset.Subsetter(options=options)
    subsetter.populate(unicodes=sorted(unicodes))
    subsetter.subset(font)
    # 子集仍是 CFF/OTTO；顺手把 flavor 清掉，免得 save() 按 sfntVersion 再猜一次。
    font.flavor = None
    font.save(FONT_PATH)
    print(f"已按 {source.name} 重建：{len(unicodes)} 个码位 -> {FONT_PATH.name}")

    after = set(TTFont(FONT_PATH).getBestCmap())
    still_missing = sorted(needed - after)
    dropped = sorted(unicodes - after)
    if dropped:
        print("警告：目标码位没能全部落进子集，丢了 " + " ".join(chr(c) for c in dropped))
    if still_missing:
        print("写入后仍缺：" + " ".join(chr(c) for c in still_missing))
        return 1
    print("子集已盖住全部界面文案")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())