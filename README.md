# MCPBreakout

一个通过 Godot MCP 自动创建的 2D 打砖块（Breakout）小游戏，使用 Godot 4.7.2 + GDScript 开发，无外部资源、无 C#、无第三方插件。

## 快速开始

1. 用 Godot 打开项目目录 `E:\root\game\game-dev\2DBreakout`
2. 双击 `scenes/Main.tscn` 或直接运行（F5）
3. 玩法：左右方向键 / A/D 移动挡板；空格发射球；P 键暂停/继续；击破全部砖块通关，空格/R 重开

## 项目结构

```
MCPBreakout
├── project.godot          # 项目配置 + 输入映射（move_left/move_right/launch/pause/restart）
├── .gitignore             # 忽略 .godot/ 缓存、build/ 导出产物
├── export_presets.cfg     # 导出预设：Windows / Linux / macOS / Web
├── LICENSE                # MIT
├── icon.svg               # 项目图标（导出时作为应用图标）
├── .github/workflows/
│   ├── ci.yml                  # 静态检查 + 冒烟测试 + 四平台导出
│   └── deploy-web.yml          # 手动触发：导出 Web 版并发布到 GitHub Pages
├── run_tests.ps1              # 一键验证（Windows / PowerShell）
├── run_tests.sh               # 一键验证（Linux / macOS / CI）
├── scenes/Main.tscn       # 主场景（Node2D）
├── scripts/
│   ├── main.gd                # 主控：砖墙生成、分数/生命/暂停/通关/游戏结束、最高分读取
│   ├── paddle.gd              # 挡板：左右移动、边界夹紧、球吸附检测
│   ├── ball.gd                # 球：CharacterBody2D + 手动反射，吸附发射、挡板偏转
│   ├── brick.gd               # 砖块：StaticBody2D，击中后消失并返回分数
│   ├── hud.gd                 # HUD：分数、生命、最高分、操作提示
│   ├── game_over_panel.gd     # 结算面板：游戏结束 / 通关标题 + 最终分数/最高分/重开按钮
│   ├── pause_panel.gd         # 暂停面板：“已暂停”
│   └── high_score.gd           # 最高分存档（ConfigFile，保存至 user://mcp_breakout_save.cfg）
├── tests/
│   ├── headless_smoke_test.gd      # 无头冒烟测试（60 项检查，覆盖核心玩法，可重复运行）
│   └── capture_screenshot.gd       # 截图辅助脚本（生成运行/暂停/结束/通关四张预览图）
└── screenshots/              # 预览截图
```

## 手动测试步骤（共 11 项）

1. **启动游戏**：打开 `scenes/Main.tscn` 并运行。检查：画面显示深蓝色背景、顶部分数/生命/最高分正确、底部提示“按 空格 发射球”、6×8 砖墙整齐排列、挡板居中、球停在挡板顶部。
2. **移动挡板**：按住 `←`（或 `A`）和 `→`（或 `D`）。检查：挡板平滑左右移动，且不会超出左右墙体内侧边界。
3. **发射球**：按 `空格`。检查：球从吸附状态切换为飞行状态，初速度略微带水平偏移，朝上运动；吸附时球**上方**有朝上的发射提示箭头（与发射方向一致），**发射后箭头立即消失、不残留**。
4. **砖块碰撞**：控制挡板让球撞击砖块。检查：砖块被击中立即消失，分数每次 +10，HUD 分数实时更新；被击中的砖块不再参与碰撞。
5. **分数增加**：持续击破若干砖块。检查：分数累加正确，击破更多砖块后分数持续增长。
6. **球掉落扣命**：让球落到底部（超出死亡线）。检查：生命 -1，球重新吸附到挡板顶部，等待重新发射；生命值在 HUD 正确更新。
7. **游戏结束**：让球连续掉落直至生命为 0。检查：进入 Game Over 状态，结算面板弹出，标题为“游戏结束”，显示“最终分数”和“最高分”，同时显示“再来一局”按钮与“按 空格 / R 重开”的提示；**HUD 底部提示同步变为“按 空格 / R 重开”，不再显示“按 空格 发射球”**；**此时按左右键挡板应保持静止**，重开后恢复可操控。
8. **通关**：击破全部 48 块砖。检查：进入通关状态，结算面板标题为“通关！”，最后一块砖同样计入分数，球停止运动并隐藏，HUD 底部提示为“全部通关！按 空格 / R 再来一局”。
9. **暂停与继续**：在游戏进行中按 `P`（或 `Esc`）。检查：游戏暂停，画面上出现“已暂停”面板，球和挡板保持静止；再次按 `P` 恢复游戏，画面恢复正常。
10. **重开游戏**：游戏结束或通关后按 `空格` 或 `R`，或点击“再来一局”按钮。检查：场景重新加载，分数归零，生命恢复为 3，砖墙重新生成，最高分保留并显示在 HUD 与结算面板；球重新吸附到挡板。
11. **最高分保存与边界碰撞**：打出较高分使游戏结束（触发存档），关闭并重新打开游戏。检查：重新运行后 HUD 的“最高分”恢复为之前的最高分；球碰到左右墙和顶部墙时反射方向正确，不会穿透墙体；挡板与球的碰撞根据击中位置正确改变水平方向，避免死循环。

## 技术要点

- 物理：球使用 `CharacterBody2D` + 手动 bounce 处理碰撞，配合最小水平速度保障避免长时间近乎垂直的卡住问题。
- 碰撞层：严格对应 `project.godot` 的 `layer_names` —— Wall=1、Paddle=2、Brick=4、Ball=8。球掩码为 `1|2|4`，挡板传感器掩码只指向 Ball 层，砖块掩码为 0（碰撞全部由球发起）。
- 存档：`HighScore.load_best()` / `save_best()` 基于 `ConfigFile`，路径为 `user://mcp_breakout_save.cfg`，重启游戏后仍保留最高分。
- 状态：`Main` 的 `State` 枚举为 `PLAYING / PAUSED / GAME_OVER / WON`。主控设为 `PROCESS_MODE_ALWAYS` 以便处理暂停输入，`Ball` 与 `Paddle` 设为 `PAUSABLE` 使暂停时真正静止。
- 结算：击破最后一块砖 → `WON`（通关），生命归零 → `GAME_OVER`，两者共用 `_settle(victory)` 与同一个结算面板，仅标题与提示文案不同。
- 运行时生成：砖墙在 `_ready()` 时按 6 行 × 8 列动态生成，不依赖外部纹理。
- 无头验证：`tests/headless_smoke_test.gd` 已全量通过（60 项检查），覆盖移动、发射、碰撞层配置、碰撞计分、掉命、暂停、游戏结束、通关（含「同一帧击破最后两块砖」边界）、重开、最高分持久化、存档损坏兜底等关键逻辑。用例开头会清理 `user://` 存档，因此可任意次连续运行（幂等）。
- 测试不写死游戏侧数值：`State` 枚举、砖块总数、每块砖分值、初始生命从 `main.gd` 的 `get_script_constant_map()` 读取，碰撞层位值从 `project.godot` 的 `layer_names` 反查，游戏侧改名或调数不会让测试静默失效。
- 结算后挡板通过 `Paddle.input_enabled = false` 冻结，不会在结算面板后面滑来滑去；重开时随场景重载恢复。
- 存档健壮性：`HighScore.load_best()` 对字段类型异常（如手工改坏的存档）会 `push_warning` 并安全回落到 0，不会崩溃。

## 预览截图

- `screenshots/breakout.png` — 游戏进行中
- `screenshots/paused.png` — 暂停状态
- `screenshots/game_over.png` — 游戏结束界面
- `screenshots/victory.png` — 全部通关界面

## 一键验证

把「静态门禁 + 冒烟测试」串成一条命令，任一步失败即以非零码退出，可直接用于提交前检查：

```powershell
# Windows / PowerShell
.\run_tests.ps1
.\run_tests.ps1 -Strict        # GDScript warning 也计为失败
.\run_tests.ps1 -SkipSmoke     # 只做静态检查
.\run_tests.ps1 -Detailed      # 打印 Godot 完整输出
```

```bash
# Linux / macOS / CI
./run_tests.sh
./run_tests.sh --strict
./run_tests.sh --skip-smoke
./run_tests.sh --detailed
```

执行内容与退出码：

1. 对 `scripts/` 与 `tests/` 下每个 `.gd` 逐个跑 `--check-only`，出现 `SCRIPT ERROR` 即失败并打印错误行；**门禁未通过时不会继续跑冒烟测试**。
2. 跑 `res://tests/headless_smoke_test.gd`，以其退出码作为结果。

| 退出码 | 含义 |
|---|---|
| `0` | 全部通过 |
| `1` | 静态检查或冒烟测试失败 |
| `2` | 未找到 Godot 可执行文件 |

Godot 可执行文件查找顺序：环境变量 `GODOT_PATH` → `PATH` 中的 `godot` / `godot4` / `godot-console` → 项目目录及其上两级目录、`Downloads`、`Program Files`（Windows）或 `~/.local/bin`、`/usr/local/bin`、`/opt`（类 Unix）下递归两层的 Godot 可执行文件。找不到时设置 `GODOT_PATH` 即可。

> PowerShell 版脚本文件必须保存为 **带 BOM 的 UTF-8**：Windows PowerShell 5.1 会按系统代码页读取无 BOM 的 `.ps1`，脚本里的中文会破坏字符串终止符导致解析失败。

## 导出与持续集成

导出预设见 `export_presets.cfg`，四个预设的输出目录统一为 `build/<平台>/`（已加入 `.gitignore`）：

| 预设 | 平台标识 | 产物 |
|---|---|---|
| `Windows Desktop` | `Windows Desktop` | `build/windows/MCPBreakout.exe`（x86_64） |
| `Linux` | `Linux/X11` | `build/linux/MCPBreakout.x86_64` |
| `macOS` | `macOS` | `build/macos/MCPBreakout.zip`（universal，arm64 + x86_64） |
| `Web` | `Web` | `build/web/`（单线程构建，无需 COOP/COEP 响应头） |

本地导出（需先在 编辑器 → 导出 → 导出资源 安装 **4.7.2 标准版**导出模板，且目标目录必须预先存在）：

```
mkdir -p build/windows   # Windows 下用 New-Item -ItemType Directory build\windows
godot --headless --path . --export-release "Windows Desktop" build/windows/MCPBreakout.exe
godot --headless --path . --export-release "Linux"           build/linux/MCPBreakout.x86_64
godot --headless --path . --export-release "macOS"           build/macos/MCPBreakout.zip
godot --headless --path . --export-release "Web"             build/web/index.html
```

> 注意：Godot 的 **.NET/Mono 版编辑器不支持 Web 导出**。本项目是纯 GDScript，导出请用标准版编辑器；
> CI 使用的 `barichello/godot-ci:4.7.2-stable` 即标准版镜像。

CI 流水线（GitHub Actions）：

- `.github/workflows/ci.yml`（push / PR 自动触发）
  1. **validate**：调用 `./run_tests.sh --strict`（静态门禁 + 冒烟测试），任一项失败即整条流水线失败。
  2. **export**：依赖 validate 通过，矩阵导出四个平台，校验产物非空后上传为构建产物（保留 14 天）。
- `.github/workflows/deploy-web.yml`（仅 `workflow_dispatch` 手动触发）：导出 Web 版并发布到 GitHub Pages，
  需先在仓库设置中启用 Pages（来源选 GitHub Actions）。

## 许可证

[MIT](LICENSE)。项目为纯 GDScript 自研代码、无外部美术资源，可自由使用、修改与再分发（含闭源），仅需保留版权声明。



- 输入映射已在 `project.godot` 定义：`move_left`（←/A）、`move_right`（→/D）、`launch`（空格/Enter）、`pause`（P/Esc）、`restart`（R/F1）。
- 所有节点与脚本命名清晰，关键逻辑均有注释，符合 Godot 4.x GDScript 最佳实践。
- 通过 Godot MCP 完整创建与运行验证，无脚本错误、无场景加载错误。
- 自动化验证命令：
  - 一键验证：`.\run_tests.ps1`（Windows）/ `./run_tests.sh`（类 Unix）
  - 单独跑冒烟测试：`godot --headless --path . --script res://tests/headless_smoke_test.gd`
  - 截图生成：`godot --path . --script res://tests/capture_screenshot.gd`
