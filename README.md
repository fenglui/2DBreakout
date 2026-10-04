# 2DBreakout

一个通过 Godot MCP 自动创建的 2D 打砖块（Breakout）小游戏，使用 Godot 4.7.2 + GDScript 开发，**无外部资源、无 C#、无第三方插件**——连音效都是运行时程序化合成的。

## 快速开始

1. 用 Godot 打开项目目录 `2DBreakout`
2. 双击 `scenes/Main.tscn` 或直接运行（F5）
3. 玩法：左右方向键 / A/D 移动挡板；**按住空格蓄力、松开发射**，蓄力时按住 ←/→ 可选择发射方向；P 键暂停/继续；击破整面砖墙进入下一关，共 3 关；生命耗尽游戏结束；空格/R 继续或重开；面板上有「退出游戏」按钮

### 玩法要点

- **蓄力发射**：按住 `空格` 蓄力，挡板上出现蓄力条，同时从球心画出**反弹预测线**；蓄力越久球速越快（最高 ×1.35）、发射角越偏（最大偏 35.5°）。蓄满（0.45 秒）会自动发射，不会卡住不放。松手角度由蓄力期间按住的 ←/→ 决定，只蓄力不按键就是垂直上弹。
- **连击**：一次飞行中连续击破的砖块数记为连击，球被挡板接住时折算成额外分数（`max(0, 连击-1) × 10`，第 2 块起每多一块多给一份），**掉球则整段作废**——不去接球就拿不到奖励。连击达到 3 时 HUD 显示连击数，回挡板时飘出奖励数字并播放音高随连击升高的音效，连击 ≥5 时拖尾明显变粗并偏向暖金色。
- **3 关递进 + 逐关换肤**：砖块耐久 1 → 2 → 3 次，球速 430 → 500 → 570；每关一套配色（深空 / 紫罗兰 / 熔岩），进入下一关时背景、球、挡板、砖墙与 HUD 文字一起过渡到新配色。
- **挡板随命收窄**：108 → 92 → 76 像素，按「已失去的生命数」取值，关卡之间生命延续。
- **多耐久砖块**：耐久未耗尽的砖不会消失，颜色逐次变暗并叠加裂纹，每次击打都计分。
- **手感反馈**：撞墙/撞板/击碎/击裂/发射/蓄满/连击/掉命/过关/通关各有程序化音效，击碎砖块迸出同色碎屑粒子，并按事件强度触发屏幕震动。
- **轨迹角度包络**：球的飞行夹角被限制在约 20°~80°，不会出现「近乎水平地在左右墙之间来回弹」或「贴在砖块面上卡死」的轨迹。

## 项目结构

```
2DBreakout
├── project.godot          # 项目配置 + 输入映射 + autoload（Sfx / Shake）
├── .gitignore             # 忽略 .godot/ 缓存、build/ 导出产物
├── export_presets.cfg     # 导出预设：Windows / Linux / macOS / Web
├── LICENSE                # MIT
├── icon.svg               # 项目图标（导出时作为应用图标）
├── fonts/
│   ├── ui-font.otf            # 项目默认字体：Noto Sans CJK SC 子集（65 个中文 + ASCII/标点，23KB）
│   └── LICENSE.txt            # 该字体的 SIL OFL 1.1 全文与出处（代码本身仍是 MIT）
├── .github/workflows/
│   ├── ci.yml                  # 静态检查 + 冒烟测试 + 四平台导出
│   └── deploy-web.yml          # 手动触发：导出 Web 版并发布到 GitHub Pages
├── run_tests.ps1              # 一键验证（Windows / PowerShell）
├── run_tests.sh               # 一键验证（Linux / macOS / CI）
├── build_windows-x86_64.bat   # 一键导出 Windows x86_64 版（双击即可）
├── build_web.bat              # 一键导出 Web/HTML5 版（含 serve 本地预览）
├── scenes/Main.tscn       # 主场景（Background 底色 + Walls + Bricks + Fx 粒子容器 + BallTrail + AimLine + Camera2D + HUD / 两个面板）
├── scripts/
│   ├── main.gd                # 主控：砖墙生成、分数/生命/关卡/暂停/结算、最高分、蓄力发射与连击调度、手感反馈
│   ├── paddle.gd              # 挡板：左右移动、边界夹紧、球吸附检测、宽度随生命收窄、蓄力条绘制
│   ├── ball.gd                # 球：CharacterBody2D + 手动反射，吸附发射、挡板偏转、碰撞信号
│   ├── ball_trail.gd          # 球拖尾：最近若干帧球心的渐隐色带，线宽与色相由连击强度派生
│   ├── aim_line.gd            # 发射预测线：intersect_ray 多段镜面反射预测，由近及远渐淡的虚线 + 反射点圆环
│   ├── brick.gd               # 砖块：StaticBody2D，多耐久 + 裂纹显示
│   ├── palette.gd             # 配色方案 Resource：背景/砖色/球/挡板/强调色/拖尾/预测线/HUD 文字 + library()
│   ├── palette_space.tres     # 第 1 关「深空」配色
│   ├── palette_violet.tres    # 第 2 关「紫罗兰」配色
│   ├── palette_lava.tres      # 第 3 关「熔岩」配色
│   ├── hud.gd                 # HUD：分数、生命、最高分、关卡、连击数、连击飘字、操作提示
│   ├── game_over_panel.gd     # 结算面板：游戏结束 / 关卡通过 / 通关 + 最高连击等统计 + 继续 / 退出按钮
│   ├── pause_panel.gd         # 暂停面板：“已暂停” + 继续 / 退出按钮
│   ├── sfx.gd                 # Autoload Sfx：AudioStreamGenerator 逐样本合成音效
│   ├── shake.gd               # Autoload Shake：trauma 模型驱动 Camera2D 偏移的屏幕震动
│   ├── spark_burst.gd         # 一次性碎屑粒子（CPUParticles2D，播完自毁）
│   └── high_score.gd          # 最高分存档（ConfigFile，保存至 user://2d_breakout_save.cfg）
├── tests/
│   ├── headless_smoke_test.gd      # 无头冒烟测试（182 项检查，覆盖核心玩法与手感系统，可重复运行）
│   └── capture_screenshot.gd       # 截图辅助脚本（生成 7 张运行画面预览）
└── screenshots/              # 预览截图
```

## 手动测试步骤（共 19 项）

1. **启动游戏**：打开 `scenes/Main.tscn` 并运行。检查：画面显示深蓝色背景、顶部「分数 / 生命 / 最高分 / 第 1 / 3 关」正确、底部提示「按住 空格 蓄力，松开发射（第 1 关 · 剩余生命 3）」、6×8 砖墙整齐排列、挡板居中、球停在挡板顶部。
2. **移动挡板**：按住 `←`（或 `A`）和 `→`（或 `D`）。检查：挡板平滑左右移动，且不会超出左右墙体内侧边界。
3. **蓄力发射**：按住 `空格` 不放。检查：**球不会立刻飞出去**，挡板上出现逐渐填满的蓄力条，球心前方画出虚线预测线并在反射点画小圆环；继续按住约 0.45 秒，蓄力条满后**自动发射**（不必松手），球飞出、预测线与蓄力条同时消失、播放发射音效。
4. **发射方向可控**：按住 `空格` 蓄力到一半，同时按住 `←`（或 `→`）再松手。检查：球**斜着**朝对应方向飞出（不按键就是垂直上弹），且球速明显快于本关基础速；角度与球速都随蓄力时长连续变化，蓄得越满偏得越多、越快。预测线画的落点方向应与实际飞行方向一致。
5. **砖块碰撞与反馈**：控制挡板让球撞击砖块。检查：第 1 关砖块被击中即消失，分数每次 +10，HUD 分数实时更新；击碎瞬间迸出与砖块同色的碎屑粒子并播放碎裂音效，画面轻微震动。
6. **撞墙反馈**：球碰到左右墙与顶部墙。检查：反射方向正确、不穿透墙体，每次触墙有短促音效与轻微震动；球飞行时身后有一段渐隐拖尾，球停回挡板上时拖尾立即清空。
7. **分数增加与连击**：一次飞行中连续击破多块砖。检查：分数累加正确，连击达到 3 时 HUD 出现「连击 ×N」；用挡板接住球后**连击折算入账**（总分 = 基础分之和 + `(连击-1) × 10`），HUD 飘出奖励数字并播放音高升高的连击音效，连击数清零；连击 ≥5 时拖尾明显变粗发白。
8. **掉球丢连击**：攒到 2 块以上连击后**故意让球掉出底部**。检查：生命 -1，球重新吸附到挡板顶部等待重新发射；**这一段连击整段作废**（HUD 连击消失、结算时不加分）；**挡板明显变窄**（108 → 92），可活动范围同步收窄；播放掉命音效并出现较强震动。
9. **暂停与继续**：在游戏进行中按 `P`（或 `Esc`）。检查：游戏暂停，出现「已暂停」面板，球和挡板保持静止，**拖尾与预测线也停止更新**；面板上有「继续」与「退出游戏」两个按钮且可点击；再次按 `P` 恢复游戏。
10. **游戏结束**：让球连续掉落直至生命为 0。检查：进入 Game Over 状态，结算面板弹出，标题「游戏结束」，显示「最终分数」「最高分」「再来一局」「退出游戏」与「按 空格 / R 重开」提示，并列出**最高连击与连击次数**；**HUD 底部提示同步变为「按 空格 / R 重开」**；**此时按左右键挡板应保持静止**，重开后恢复可操控；挡板已收窄到最窄一档（76）。
11. **关卡递进**：击破第 1 关全部 48 块砖。检查：进入「关卡通过」结算，标题为「第 1 关通过！」、按钮文案为「下一关」、HUD 提示「第 1 关通过！按 空格 / R 进入下一关」；按空格/R 后进入第 2 关——**分数与生命延续**、砖墙重建、球速加快、砖块需要打 2 次才碎。
12. **逐关换肤**：进入第 2 关。检查：背景由深蓝渐变到紫罗兰、球/挡板/砖墙/预测线/HUD 文字一起换色（0.35 秒过渡，不是瞬切）；结算面板配色跟随当前关卡；回到第 1 关时颜色还原。
13. **多耐久砖块**：在第 2 关用球击中同一块砖一次。检查：砖块**不消失**、颜色变暗并出现一条裂纹、分数 +10、HUD 不变；再击中一次才碎，此时才计入「已清除」数量。
14. **通关**：打到第 3 关并击破全部砖块。检查：进入通关状态，结算面板标题为「通关！」，最后一块砖同样计入分数，球停止运动并隐藏，HUD 提示「全部通关！按 空格 / R 再来一局」。
15. **退出按钮**：在暂停面板或结算面板点击「退出游戏」。检查：桌面版进程立刻退出；Web 版结束 Godot 运行时并停在页面画布上（要显示自定义「已退出」页面，需要自备 HTML 外壳的 `onExit` 回调，本项目未附带）。
16. **重开游戏**：游戏结束或通关后按 `空格` 或 `R`，或点击「再来一局」按钮。检查：场景重新加载，分数归零、生命恢复为 3、回到第 1 关、挡板恢复初始宽度、砖墙重新生成、最高分保留并显示在 HUD 与结算面板；球重新吸附到挡板。
17. **最高分保存与音效**：打出较高分使游戏结束（触发存档），关闭并重新打开游戏。检查：重新运行后 HUD 的「最高分」恢复为之前的最高分；破纪录时结算面板显示「新纪录！最高分 N」；全程无音频相关报错，`--headless` 下运行也不因音频系统报错。
18. **轨迹角度包络（防横弹 / 防卡死）**：发射后放任球长时间飞行（可用挡板接不住的方式让它多打几轮）。检查：球**永远不会近乎水平地在左右墙之间来回弹**，轨迹与水平面的夹角始终在约 20°~80° 之间；球**不会贴在砖块面上原地抖动**（速度正常但位置不动）；球也不会近乎垂直地在砖块下方来回弹而不落地。满蓄力斜射也不应把角度甩出包络。
19. **Web 版**：运行 `build_web.bat serve`，浏览器访问 `http://127.0.0.1:8000`。检查：**HUD 与面板的中文正常显示，不出现方框 □□**（Web 构建没有系统字体，中文靠内嵌的 `fonts/ui-font.otf`）；按 F12 打开控制台，**没有任何 warning / error**——尤其不应出现 `is trying to play a sample from a stream that cannot be sampled`（Web 默认的 Sample 播放类型对永不结束的程序化音频流不成立，脚本已按 `OS.has_feature("web")` 切到 Stream 类型）；音效能听到（浏览器要求先有一次用户交互，先点一下画面再按住 `空格`）；重新导出后若行为没变，用 Ctrl+Shift+R 绕过浏览器缓存。

## 技术要点

- **物理**：球使用 `CharacterBody2D` + 手动 bounce 处理碰撞。每帧**只处理穿透最深的那一个接触点**：`move_and_slide()` 报告的所有法线都基于「本帧移动前」的速度，把它们依次 bounce 到已经反弹过的速度上是不物理的，会把垂直分量直接抹平。
- **角度包络**：球速与水平面的夹角被强制限制在 `MIN_ANGLE_FROM_HORIZONTAL = 0.35` ~ `MAX_ANGLE_FROM_HORIZONTAL = 1.40` 弧度（约 20°~80°）之间，两个边界缺一不可——低于下限球会横着飞来飞去并卡死在砖块面上，高于上限球会在砖块下方垂直来回弹、长时间不落地。**必须用角度而不是「分量下限」钳制**：把分量抬到下限后再归一化到固定速率，会把分量重新缩回下限之下（实测 x 分量 67.93 < 下限 68.8），钳制自己违反自己。另有 `_track_stuck()`：连续 8 帧位移不足 0.5px 判定为被挤进几何体内部，向下强制脱离（砖块下方是空场，最坏情况是球落向挡板）。
- **碰撞层**：严格对应 `project.godot` 的 `layer_names` —— Wall=1、Paddle=2、Brick=4、Ball=8。球掩码为 `1|2|4`，挡板传感器掩码只指向 Ball 层，砖块掩码为 0（碰撞全部由球发起）。球在 `_resolve_collisions()` 中按「砖块 / 挡板 / 墙」三分支发出 `brick_hit` / `paddle_hit` / `wall_hit`，音效与震动由 Main 统一调度。
- **蓄力发射（手感三件套之一）**：按下 `launch` 只进入蓄力态，**松手才发射**，方向与球速都由蓄力强度算出：`tilt = power × MAX_CHARGE_TILT × _charge_dir`，方向 `Vector2(sin tilt, -cos tilt)`，球速 `本关基础速 × lerp(1.0, CHARGE_SPEED_MUL, power)`。
  - **必须先改 `ball.speed` 再 `ball.launch()`**：`launch()` 用当前 `speed` 算初速度，顺序反了第一帧会以旧速度出球，表现为「满蓄力打出去的第一帧明显偏慢」。
  - **速度与角度是两条独立的轴**：`Ball._clamp_direction()` 是「先归一化到 `speed` 再钳角度」，所以抬速度改不动角度包络，`MAX_CHARGE_TILT` 才是发射角的唯一来源。反过来说，蓄力满不满不会让角度越界。
  - **蓄满自动发射**：否则玩家可以把空格按住不放，看着满蓄力条却不发球，像卡住。
  - **蓄力进度放 `_process` 而不是 `_physics_process`**：蓄力是输入反馈，应与帧率无关；且 `Main` 是 `PROCESS_MODE_ALWAYS`，暂停时也能立刻把蓄力清掉，避免恢复后看到满蓄力条却按不动。
  - **发射方向由 Main 统一计算**（`_launch_direction()`），预测线与实际飞行共用同一个函数——球自己不决定发射角，否则预测线画的落点会和实际落点对不上，瞄准工具就废了。`Ball.launch(direction)` 的参数留默认值 `Vector2.ZERO`，无参调用退回旧的随机略微偏水平发射，冒烟测试与调试仍可无参调用。
- **发射预测线（手感三件套之二）**：`AimLine` 用 `PhysicsDirectSpaceState2D.intersect_ray` 沿发射方向做 3 次镜面反射，**不挂 `RayCast2D` 节点**——节点数会随球数/道具数线性增长，且每次查询都要走一遍节点生命周期。命中后沿法线挪开 `SKIN = 0.5`，否则下一段会立刻再命中同一块砖，预测线在一个点上反复打转。节点 `z_index` 压在砖块与球之下：射线止于碰撞体表面，线本来就不会画进砖块内部，这条顺序真正的用处是保证线也盖不住球。
  - **掩码只有 Wall|Brick（`AIM_MASK_WALL | AIM_MASK_BRICK`）**：把挡板算进去的话预测线会在脚边撞上自己，画出一段毫无意义的短线。
  - **点、段、反射是三个不同的量**：每次循环追加「当前点 + 终点」两个点，所以**段数 = 点数 / 2**，而衰减是按**段号**算的（`SEGMENT_FADE ^ 段号`）。按点下标循环会把相邻两段首尾错接、衰减退化成平方（0.55² ≈ 0.30，第三段基本看不见）。`get_point_count()` / `get_segment_count()` / `get_bounce_count()` 三个访问器就是给冒烟测试区分这三者用的。
  - 只在吸附态画：球已经在飞时方向是确定的，再画线是噪音。节点声明为 `PROCESS_MODE_PAUSABLE`——`_draw()` 本身不受 `process_mode` 管，真正让暂停时线消失的是 `Main._process` 里「暂停即 `_reset_charge()`」这条分支。
- **球拖尾**：`BallTrail` 记录最近 14 帧球心，画成由粗到细、由透明到实的渐隐色带。采样在 `Main._physics_process` 里做而不是 `_process`——拖尾必须与球的移动同频，否则高刷屏上会画出不等距的锯齿。位移不足 `MIN_STEP = 2.0` 的帧不记点：球吸附在挡板上时位置不变，否则会在同一个点上堆满 14 段，退化成一块方块。线宽按连击数在 `MIN_WIDTH`~`MAX_WIDTH` 之间插值，把 combo 数值直接映射成视觉权重。
  - **换肤写 `base_color`，逐帧派生 `color`**：Main 每帧按连击强度重算一次颜色，如果换肤 tween 直接写 `color`，下一帧就被覆盖回去，`palette.trail` 会变成改了没反应的死配置。基色只由 `_apply_palette_colors()` 写，实际颜色由 `set_intensity(0~1)` 从基色向 `GLOW_COLOR` 插值。
- **连击（手感三件套之三）**：奖励公式 `max(0, combo-1) × POINTS_PER_BRICK`，**只做整数乘加**，总分始终是每块砖分值的整数倍（冒烟测试有一条断言专门守这个不变量）。刻意避开三角数 `combo*(combo+1)/2`：那会让 1 块砖也白送一份分，而 1 块砖是完全不需要技巧的默认操作，送分等于告诉玩家「乱打也有奖励」。
  - **回挡板入账、掉球作废**：这是 combo 的风险面。如果掉球也结算，玩家会无脑刷砖等结算，反而不会去接球。撞墙**不**清零——只在「回到挡板」和「掉出底部」这两个明确节点处理。
  - `_settle()` 里补一次结算，否则最后一球打空砖墙时那点连击就丢了。
  - 公式声明成 `static func combo_bonus_for()`，冒烟测试直接调用它算期望值，而不是把公式抄一份进测试——抄副本的话公式一改测试就会静默失效。
- **逐关换肤**：`Palette` 是纯 `Resource`，字段全部可导出，改成 `.tres` 就能让美术接管而不动代码；`library()` 在代码里给出默认值（与本项目「无外部资源」的约束一致），Main 上留 `@export level_palettes` 入口，两者不冲突。
  - **`library()` 每次都新建实例**，不能做成常量表共享出去：多个 `Main` 同时存在时（冒烟测试就会同时造两个），改其中一个的颜色会连带改掉另一个——这是 `@export Resource` 的头号共享坑。
  - 换肤用 tween 过渡（0.35s）而不是瞬切，让「进入下一关」有视觉分量；文字色与强调色**不**参与 tween，`Label` 上逐帧插值 theme override 没有意义。
  - **`Palette` 的每个字段都要真的落到画面上**：`background` / `row_colors` / `ball` / `paddle` 走 tween，`aim` 给预测线、`trail` 给拖尾基色，`accent` 给蓄力条 / 连击飘字 / 结算面板统计行，`text_primary` / `text_secondary` 给 HUD 文字。留着没人用的字段是典型的「配置看起来很全、实际改了没反应」，冒烟测试逐字段核对（拖尾色必须在**球正在飞**的时候采：球吸附时 `Main._physics_process` 直接 return，采到的是没人覆盖的残留值）。
  - 场上砖块不在换肤时补色：`_apply_palette_colors()` 的唯一调用点紧跟 `_build_bricks()`，而砖色本来就出自 `palette.row_colors`，再按 `y` 反推行号刷一遍是空操作。
- **音效音高缩放**：`Sfx.play(preset, pitch)` 按 `pitch` 缩放每个音符的 `f0`/`f1`，**不动 `playback.pitch_scale`**——后者会把同时播放的其它声音一起拖慢。逻辑抽成 `static func pitched_notes(preset, pitch)`：无头模式下 `play()` 在 `_playback == null` 处就返回了，运行时根本走不到缩放逻辑，测试只能验这个静态函数（下限钳在 0.25，避免次声）。
- **状态机**：`Main.State` 为 `PLAYING / PAUSED / GAME_OVER / LEVEL_CLEAR / WON`。主控设为 `PROCESS_MODE_ALWAYS` 以便处理暂停输入，`Ball` 与 `Paddle` 设为 `PAUSABLE` 使暂停时真正静止；`AimLine` 与 `BallTrail` 也声明为 `PAUSABLE`，它们自身没有 `_process`（数据全由 Main 推过来），写死在这里是为了让将来挂在它们身上的 tween / 计时在暂停时自动停摆。
- **结算**：`_settle(final_state)` 统一处理三种结算（游戏结束 / 关卡通过 / 通关），共用同一个面板，只有标题、按钮文案与提示不同。关卡通过时 `_on_continue_requested()` 走 `_level += 1` 的推进分支，其余结算走 `reload_current_scene()`。
- **通关判定用计数器**：`_bricks_cleared` 计数，而不是 `get_child_count() <= 1`——`Brick.hit()` 内部是 `queue_free()`，被击破的砖块要到帧末才从子节点移除，若最后一帧同时击破两块砖，只查子节点数就会漏判。
- **多耐久砖块**：`Brick.max_hits` / `hits_left`，`hit()` 每次返回分值，耐久归零才 `queue_free()`；`is_destroyed()` 供 Main 判断本次击打是否真正清除。
- **关卡配置**：`LEVEL_BRICK_HITS = [1,2,3]`、`LEVEL_BALL_SPEED = [430,500,570]`、`MAX_LEVEL = 3`，超出关卡数按取模循环取值。
- **挡板宽度**：`Paddle.set_width()` 同步替换碰撞形状与传感器形状并重绘，Main 负责按新宽度重算 `left_bound` / `right_bound`。
- **音效（零音频资源）**：`SfxBus` 用 `AudioStreamGenerator` + `AudioStreamPlayer`，在 `_process` 里按「本帧需要消费的样本数」补算并 `push_buffer()`。声部表最多 24 个，每个预设是若干带延迟的音符（正弦/方波/锯齿/噪声 + 平方衰减包络）。声部用带成员变量的内部类 `Voice`，不用字典——混音是每样本执行的热路径。
  - 采样率取 **22050**：GDScript 逐样本混音是性能敏感路径，本项目最高基频是连击预设的 1320Hz，即便 `pitch` 拉到上限 2.0 也只有 2640Hz，22050 的奈奎斯特上限 11025Hz 绰绰有余。
  - 每帧补算量按 `ceil(delta * MIX_RATE) + slack` 计算，**不能取一个小于需求的常数**：60FPS 下每帧要消费 368 个样本，补得比这少就会长期欠载，表现为爆音/断续。
  - Godot 4.7 的 API 形态与旧版差异较大：`AudioStreamGenerator` 只有 `mix_rate` / `mix_rate_mode` / `buffer_length`（无 `max_latency_msec`）；可用方法在子类 `AudioStreamGeneratorPlayback` 上（`get_frames_available()` / `push_buffer()`）；GDScript 没有 `AudioFrame` 类型，音频帧是 `Vector2`（x = 左声道，y = 右声道）。
  - **无头模式（`--headless`）下直接不创建播放器**：Dummy 驱动下播出来的声音没人听，而且 Godot 4.7 的 Dummy 路径不会释放 `AudioStreamGeneratorPlayback`，进程退出时会留下一条 ObjectDB 泄漏记录。`play()` 在 `_playback == null` 时直接返回，所有调用安全空转。
  - `NOTIFICATION_PREDELETE` 里显式 `stop()` 并放下 `_playback` 引用：`AudioStreamGeneratorPlayback` 是 `AudioStreamPlayer` 的成员，只要 GDScript 侧还持有一份引用，销毁后计数就停在 1。用 PREDELETE 而不是 `_exit_tree`，因为场景重载也会触发 `_exit_tree`。
  - **Web 平台必须把播放类型改成 Stream**：`AudioStreamPlayer.playback_type = AudioServer.PLAYBACK_TYPE_STREAM`（仅 `OS.has_feature("web")` 时）。默认的 Sample 类型要求把整条流一次性装进内存，而 `AudioStreamGenerator` 是一条永不结束的程序化流，引擎在 `play_basic()` 里会走 `stream->can_be_sampled()` 的失败分支并打印 `is trying to play a sample from a stream that cannot be sampled`。桌面端保持默认类型，延迟更低。
  - **属性名的坑**：4.7 里这个属性叫 `playback_type`，旧文档里的 `playback_mode` 已经不存在。写 `playback_mode` 时 `--check-only` **不报错**（静态检查不校验 native 属性名），运行时才抛 `Invalid access to property or key 'playback_mode'`，后果是 `Sfx._ready()` 中断、autoload 建不起来、**所有平台的音效一起消失**。冒烟测试里有一条专门核对 `AudioStreamPlayer` 运行时属性表的用例，就是为拦住这一类「编译通过、运行时炸」的属性名。
  - **同一个坑的第二例**：`AudioStreamGenerator` 在 4.7 **没有** `get_playback()`。曾写过一版「开播前把缓冲区预热成静音」，调用它导致运行时 `Invalid call. Nonexistent function 'get_playback'`，同样中断 `_ready()`、`play()` 永不执行。开播前的缓冲区拿不到，也不需要预热：Web 的问题由 `playback_type` 解决。
  - **音频路径的自动化覆盖只能靠带窗口运行**：无头模式不创建播放器，所以这类错误 `--check-only` 与无头冒烟测试都看不见。`run_tests.ps1 -Windowed` / `run_tests.sh --windowed` 会带窗口跑 300 帧并检查 `SCRIPT ERROR`、autoload 失败、`cannot be sampled` 与泄漏，是这条路径的兜底。
- **UI 字体（Web 中文）**：项目默认字体是 `fonts/ui-font.otf`（`gui/theme/custom_font`），Noto Sans CJK SC Regular 用 fontTools 子集化到 UI 实际用到的 **171 个字符**（65 个中文 + ASCII + 标点），**23KB**。**为什么必须内嵌**：桌面版靠系统字体回退渲染中文，而 Godot 的 Web 构建没有系统字体可用，不内嵌字体时浏览器里所有中文都显示成方框（□□）。字体是 SIL OFL 1.1，全文与出处在 `fonts/LICENSE.txt`；游戏代码本身仍是 MIT。
  - **子集必须随 UI 文案一起长**：Web 构建下缺一个字形就是屏幕上一个 □，而冒烟测试跑在桌面版上、有系统字体回退，**看不见这个问题**。所以改任何 UI 文案都要重新子集化（把新字符加进 `pyftsubset` 的 `unicodes`），并核对 `.tscn` 的 `text=` 与 `.gd` 的字符串字面量里没有子集外的字符（包括 U+3000 全角空格这类「看着是空格、其实是独立码位」的字符）。
- **屏幕震动**：`ShakeBus` 用 trauma 模型（`shake(amount)` 累加、每秒衰减 1.9、位移取创伤值平方 × 14px），只改 `Camera2D.offset`，不移动任何游戏节点，因此不影响碰撞与坐标。相机固定在视口中心 (240, 360)，视口 480×720，画面布局与无相机时完全一致。暂停瞬间调用 `reset()` 归零，避免「已暂停」画面上相机还在随机跳动。
- **粒子碎屑**：`SparkBurst extends CPUParticles2D`，不挂贴图（无 texture 时绘制方块），`one_shot` + `explosiveness = 1` + `color_ramp`（Gradient）淡出，`finished` 信号自毁；另有 `_process` 计时兜底自毁，避免暂停等原因收不到 `finished` 时累积泄漏。
- **面板输入**：结算/暂停面板均设为 `PROCESS_MODE_ALWAYS`，暂停状态下按钮依然可点；「退出游戏」只发 `quit_requested` 信号，由 Main 决定 `get_tree().quit()`，面板不直接操作进程。
- **存档**：`HighScore.load_best()` / `save_best()` 基于 `ConfigFile`，路径为 `user://2d_breakout_save.cfg`；对字段类型异常（如手工改坏的存档）会 `push_warning` 并安全回落到 0，不会崩溃。
- **运行时生成**：砖墙在每关开始时按 6 行 × 8 列动态生成，不依赖外部纹理。
- **无头验证**：`tests/headless_smoke_test.gd` 全量通过（**182 项检查**），覆盖移动、发射、碰撞层配置、碰撞计分、掉命与挡板收窄、暂停、游戏结束、关卡递进（含「推进后挡板必须恢复可操控」）、多耐久砖块、通关（含「同一帧击破最后两块砖」边界）、重开、最高分持久化、存档损坏兜底、粒子生成与自毁、震动衰减归零、音效预设齐全性与声部上限、`AudioStreamPlayer` 运行时暴露 `playback_type`、退出按钮信号、球速角度包络与防卡死（逐帧采样球速，断言夹角始终落在包络内、包络余量非负、飞行中不出现位移为 0 的卡死帧、卡死脱离落点位于砖墙下方空场），以及 P0 手感三件套（蓄力进态 / 蓄力条 / 预测线打在墙上、预测线掩码与「点/段/反射」三者的自洽关系、贴地平飞射线在左右墙之间反射满配置次数、蓄满自动发射、发射角与球速由同一个 power 导出、拖尾增长与清空、连击入账与作废、连击 HUD 双向切换、逐关换肤的每个 `Palette` 字段、`Ball.launch()` 无参向后兼容、音高缩放不改动常量表）。用例开头会清理 `user://` 存档，因此可任意次连续运行（幂等）。
- **测试不写死游戏侧数值**：`State` 枚举、砖块总数、每块砖分值、初始生命、关卡数、砖块耐久阶梯、挡板宽度阶梯、墙厚与视口尺寸、蓄力时长 / 提速倍率 / 最大偏角、预测线掩码与反弹次数、连击阈值与拖尾增粗阈值从 `main.gd` 的 `get_script_constant_map()` 读取，碰撞层位值从 `project.godot` 的 `layer_names` 反查，音效预设从 `sfx.gd` 常量与脚本源码中实际用到的音效名比对，游戏侧改名或调数不会让测试静默失效。
- **断言要挑「坏了会变」的那一个量**：预测线曾经只断言「点数 ≥ 2」，而线一路飞出场地也是 2 个点——这条断言恒真，等于没测。改成同时看**反射次数**（真的打在墙/砖上）与**段数**（`点数 / 2`，衰减的索引单位）；多段反射则单独喂一条「贴地平飞、掩码只有墙」的射线，砖完全够不着，反弹次数只由配置决定，与砖块布局无关。
- **模拟输入必须同时走两条路径**：`Input.action_press/release` 更新 `Input` 的动作状态（`Input.get_axis` 才读得到），`Input.parse_input_event(InputEventAction)` 才把事件派发进 `_input` / `_unhandled_input`，**缺一条就有一半功能是幽灵的**。另外 `parse_input_event` 会把事件**缓冲到下一帧**才派发：同一帧 `await` 之前就读状态，读到的是事件到达之前的状态（实测表现为「松手后球根本没飞出去」，因为读到的还是吸附态的 `Vector2.ZERO`）。
- **不写死「随帧率漂移」的期望值**：蓄力进度逐帧累加，「测试读到 power 的那一帧」与「游戏真正松手的那一帧」之间还会多涨一帧，按读到的值算期望必然对不上（实测差整整一倍）。这类断言改成验证**不变量**：由实测球速反解出游戏实际用的 power，再断言发射角等于同一个 power 导出的值——既守住「角度与球速同源」，又与帧时序无关。
- **结算后挡板冻结**：`Paddle.input_enabled = false`，挡板不会在结算面板后面滑来滑去；重开时随场景重载恢复。

## 预览截图

- `screenshots/charging.png` — 蓄力中（挡板蓄力条 + 发射预测线与反射点圆环）
- `screenshots/breakout.png` — 游戏进行中（含碎屑粒子与球拖尾）
- `screenshots/paused.png` — 暂停状态（继续 / 退出按钮）
- `screenshots/game_over.png` — 游戏结束界面（挡板已收窄）
- `screenshots/level_clear.png` — 第 1 关通过界面
- `screenshots/level2.png` — 第 2 关多耐久砖块（带裂纹，配色已切成紫罗兰）
- `screenshots/victory.png` — 全部通关界面

重新生成：`godot --path . --script res://tests/capture_screenshot.gd`（**不要加 `--headless`**，无头模式不渲染）。

## 一键验证

把「资源导入 + 静态门禁 + 冒烟测试」串成一条命令，任一步失败即以非零码退出，可直接用于提交前检查：

```powershell
# Windows / PowerShell
.\run_tests.ps1
.\run_tests.ps1 -Strict        # GDScript warning 也计为失败
.\run_tests.ps1 -SkipSmoke     # 只做静态检查
.\run_tests.ps1 -Detailed      # 打印 Godot 完整输出
.\run_tests.ps1 -Windowed      # 追加带窗口运行冒烟（音频开播路径，需要显示器）
```

```bash
# Linux / macOS / CI
./run_tests.sh
./run_tests.sh --strict
./run_tests.sh --skip-smoke
./run_tests.sh --detailed
./run_tests.sh --windowed      # 追加带窗口运行冒烟（音频开播路径，需要显示器）
```

执行内容与退出码：

1. `--headless --import`：生成 `class_name` 的全局类缓存 `.godot/global_script_class_cache.cfg`。**全新检出的仓库没有 `.godot/` 时这一步是必需的**，否则 `--check-only` 会因为找不到跨脚本引用的 `class_name` 而报错。
2. 对 `scripts/` 与 `tests/` 下每个 `.gd` 逐个跑 `--check-only`，出现 `SCRIPT ERROR` 即失败并打印错误行；**门禁未通过时不会继续跑冒烟测试**。
3. 跑 `res://tests/headless_smoke_test.gd`，以其退出码作为结果。
4. （可选，`-Windowed` / `--windowed`）带窗口运行 300 帧，检查 `SCRIPT ERROR`、autoload 实例化失败、`cannot be sampled`、实例泄漏与非零退出码。**这是音频开播路径唯一的自动化覆盖**：无头模式不创建播放器，GDScript 对 native 方法/属性的运行时错误（`playback_mode`、`get_playback` 两次事故）在无头下全部隐形。需要显示器，CI 不跑。

| 退出码 | 含义 |
|---|---|
| `0` | 全部通过 |
| `1` | 导入失败、静态检查失败或冒烟测试失败 |
| `2` | 未找到 Godot 可执行文件 |

Godot 可执行文件查找顺序：环境变量 `GODOT_PATH` → `PATH` 中的 `godot` / `godot4` / `godot-console` → 项目目录及其上两级目录、`Downloads`、`Program Files`（Windows）或 `~/.local/bin`、`/usr/local/bin`、`/opt`（类 Unix）下递归两层的 Godot 可执行文件。找不到时设置 `GODOT_PATH` 即可。

> PowerShell 版脚本文件必须保存为 **带 BOM 的 UTF-8**：Windows PowerShell 5.1 会按系统代码页读取无 BOM 的 `.ps1`，脚本里的中文会破坏字符串终止符导致解析失败。

## 导出与持续集成

导出预设见 `export_presets.cfg`，四个预设的输出目录统一为 `build/<平台>/`（已加入 `.gitignore`）：

| 预设 | 平台标识 | 产物 |
|---|---|---|
| `Windows Desktop` | `Windows Desktop` | `build/windows/2DBreakout.exe`（x86_64） |
| `Linux` | `Linux/X11` | `build/linux/2DBreakout.x86_64` |
| `macOS` | `macOS` | `build/macos/2DBreakout.zip`（universal，arm64 + x86_64） |
| `Web` | `Web` | `build/web/`（单线程构建，无需 COOP/COEP 响应头） |

本地导出（需先在 编辑器 → 导出 → 导出资源 安装 **4.7.2 标准版**导出模板，且目标目录必须预先存在）：

```
mkdir -p build/windows   # Windows 下用 New-Item -ItemType Directory build\windows
godot --headless --path . --export-release "Windows Desktop" build/windows/2DBreakout.exe
godot --headless --path . --export-release "Linux"           build/linux/2DBreakout.x86_64
godot --headless --path . --export-release "macOS"           build/macos/2DBreakout.zip
godot --headless --path . --export-release "Web"             build/web/index.html
```

> 注意：Godot 的 **.NET/Mono 版编辑器不支持 Web 导出**。本项目是纯 GDScript，导出请用标准版编辑器；
> CI 使用的 `barichello/godot-ci:4.7.2-stable` 即标准版镜像。

### Windows 一键导出

`build_windows-x86_64.bat` 双击即可出 Windows x86_64 版，无需记命令：

```
build_windows-x86_64.bat            导出 release 版（默认）
build_windows-x86_64.bat debug      导出 debug 版
build_windows-x86_64.bat clean      清空 build 目录后导出 release 版
build_windows-x86_64.bat help       查看说明
```

它会依次：自动查找 Godot（`GODOT_PATH` → PATH → 项目目录及上两级 → `%LOCALAPPDATA%\Programs` → `%USERPROFILE%\Downloads`，优先 console 版）→
按编辑器版本推导 `%APPDATA%\Godot\export_templates\<版本>\windows_release_x86_64.exe` 并检查模板是否就位 →
校验预设存在 → 跑一次 `--import` → `--export-release` → 校验产物并打印体积。

产物是 `build\windows\2DBreakout.exe` + `2DBreakout.pck`（预设未启用 `embed_pck`，**两个文件必须放在同一目录一起分发**）。

| 退出码 | 含义 |
|---|---|
| `0` | 导出成功，产物已校验 |
| `2` | 未找到 Godot 可执行文件 |
| `3` | 未安装与编辑器同版本的 Windows 导出模板（附安装指引） |
| `4` | 导出命令失败 / 预设缺失 / 导入失败 |
| `5` | 导出命令成功但 exe 或 pck 缺失 |

> 该脚本刻意保持**纯 ASCII 文本 + CRLF 换行**：cmd.exe 分块读取批处理并按字符维护文件偏移，
> 文件里的非 ASCII 字节（GBK 或 UTF-8 中文）会让偏移错位，表现为命令被从中间截断、
> 中文输出变成「锟斤拷」。脚本自身的中文说明写在本 README 里。两个 bat 脚本都是这个规则。

### Web 一键导出

`build_web.bat` 双击即可出 HTML5 版：

```
build_web.bat              导出 release 版（默认）
build_web.bat debug        导出 debug 版
build_web.bat clean        清空 build 目录后导出 release 版
build_web.bat serve        导出后起一个本地服务器，然后访问 http://127.0.0.1:8000
build_web.bat help         查看说明
```

产物是 `build\web\` 整个目录：`index.html` + `index.js` + `index.wasm` + `index.pck`
+ 两个音频 worklet + 图标。这些文件名互相引用，**整目录原样分发**，不要改名。

与 Windows 脚本的两点差异：

1. **自动跳过 .NET/Mono 编辑器**：Mono 版编辑器不能导出 Web，脚本在自动查找时过滤掉路径含 `mono` 的候选；
   若 `GODOT_PATH` 指向 Mono 版，脚本会直接停下并说明原因（退出码 6）。
2. **按预设自动挑模板**：预设关闭线程支持 → `web_nothreads_release.zip`；开启线程 → `web_release.zip`；
   开启 GDExtension → `web_dlink_release.zip`。预设改开关不需要改脚本。

Web 版必须通过 `http://` 访问，**双击 `index.html` 打不开**：浏览器会拒绝 file:// 页面上的
`.js` / `.wasm` / `.pck` 请求。最省事的是 `build_web.bat serve`（需要 Python，脚本会自动探测 `python` / `py`）。

> 浏览器会缓存旧的 `index.pck`：重新导出后如果游戏行为没变，请强制刷新（Ctrl+Shift+R）或换个端口再打开。

| 退出码 | 含义 |
|---|---|
| `0` | 导出成功，html/js/wasm/pck 四个核心产物已校验 |
| `2` | 未找到 Godot 可执行文件 |
| `3` | 未安装与编辑器同版本的 Web 导出模板（附安装指引） |
| `4` | 导出命令失败 / 预设缺失 / 导入失败 |
| `5` | 导出命令成功但 html/js/wasm/pck 有缺失 |
| `6` | 找到的是 .NET/Mono 版编辑器，无法导出 Web |

导出完成后脚本会顺手删掉 `build\web\*.import`，并在 `build\` 下放一个 `.gdignore`：Godot 会给项目目录内的
png 生成 `.import` 边车文件，而 Web 导出的图标 png 就落在 `build\web\` 里。`.gdignore` 让 Godot 彻底跳过
`build\`（两个 bat 都会自动补这个文件），边车文件从此不再产生，发布到 Pages 的目录是干净的。

导出预设的 `exclude_filter` 排除了 `build/*` 与 `screenshots/*`：前者是导出产物、后者是 README 配图，
都不是运行时资源。不排除时 `all_resources` 过滤会把它们一并打进 `.pck`（本项目实测 166 KB → 70 KB）。

CI 流水线（GitHub Actions）：

- `.github/workflows/ci.yml`（push / PR 自动触发）
  1. **validate**：调用 `./run_tests.sh --strict`（导入 + 静态门禁 + 冒烟测试），任一项失败即整条流水线失败。
  2. **export**：依赖 validate 通过，矩阵导出四个平台，校验产物非空后上传为构建产物（保留 14 天）。
- `.github/workflows/deploy-web.yml`（仅 `workflow_dispatch` 手动触发）：导出 Web 版并发布到 GitHub Pages，
  需先在仓库设置中启用 Pages（来源选 GitHub Actions）。

## 许可证

[MIT](LICENSE)。项目代码为纯 GDScript 自研、无外部美术与音频资源，可自由使用、修改与再分发（含闭源），仅需保留版权声明。

唯一的第三方文件是 UI 字体 `fonts/ui-font.otf`：Noto Sans CJK SC Regular 的字符子集，**SIL Open Font License 1.1**
（全文与出处见 [fonts/LICENSE.txt](fonts/LICENSE.txt)，字体 © 2014-2021 Adobe，Noto 为 Google 商标）。
OFL 要求随分发副本附上其版权与许可声明，分发本游戏时请连同 `fonts/` 一并打包。

---

- 输入映射已在 `project.godot` 定义：`move_left`（←/A）、`move_right`（→/D）、`launch`（空格/Enter）、`pause`（P/Esc）、`restart`（R/F1）。
- Autoload：`Sfx`（`scripts/sfx.gd`，类型 `SfxBus`）、`Shake`（`scripts/shake.gd`，类型 `ShakeBus`）。两者都通过 `SfxBus.instance(self)` / `ShakeBus.instance(self)` 取得类型化引用，不直接写全局名——`godot --check-only --script` 不会实例化 autoload，直接引用全局名会让静态检查失败。
- 所有节点与脚本命名清晰，关键逻辑均有注释，符合 Godot 4.x GDScript 最佳实践。
- 通过 Godot MCP 完整创建与运行验证，无脚本错误、无场景加载错误、无 ObjectDB 泄漏。
- 自动化验证命令：
  - 一键验证：`.\run_tests.ps1`（Windows）/ `./run_tests.sh`（类 Unix）
  - 单独跑冒烟测试：`godot --headless --path . --script res://tests/headless_smoke_test.gd`
  - 截图生成：`godot --path . --script res://tests/capture_screenshot.gd`
