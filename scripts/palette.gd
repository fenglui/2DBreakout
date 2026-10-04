class_name Palette
extends Resource
## 配色方案：一关一套，用于「换肤」。
##
## 字段全部可导出，改成 .tres 就能让策划/美术接管，不需要动代码。
## 现在由 library() 在代码里给出默认值，好处是零资源依赖（与本项目
## 「无外部资源」的约束一致）；两者不冲突，Main 上留了 @export 入口。
##
## 重要：library() 每次都新建实例，不要把它做成常量表共享出去——
## 多个 Main 同时存在时，改其中一个的颜色会连带改掉另一个
## （这正是 @export Resource 的头号共享坑）。

## 背景色
@export var background := Color("0b0e16")
## 砖块配色，自上而下按行取用；长度不足时按取模循环
@export var row_colors: Array[Color] = [
	Color("f94144"), Color("f3722c"), Color("f9c74f"),
	Color("90be6d"), Color("43aa8b"), Color("4cc9f0"),
]
## 球色
@export var ball := Color("f8f9fa")
## 挡板色
@export var paddle := Color("f9c74f")
## 强调色：蓄力条、连击飘字、结算面板的连击统计行
@export var accent := Color("f9c74f")
## 球拖尾色
@export var trail := Color("f8f9fa")
## 预测线色
@export var aim := Color("f8f9fa")
## HUD 主要文字色
@export var text_primary := Color("ebf0ff")
## HUD 次要文字色（最高分 / 关卡 / 提示）
@export var text_secondary := Color("c9d9ec")


## 三关三套配色，按关卡循环取用。
## 返回的都是全新实例，调用方可以随意改字段。
static func library() -> Array[Palette]:
	var result: Array[Palette] = []

	# 第 1 关「深空」：与原版配色一致，作为其它方案的基准
	var space := Palette.new()
	space.background = Color("0b0e16")
	space.row_colors = [
		Color("f94144"), Color("f3722c"), Color("f9c74f"),
		Color("90be6d"), Color("43aa8b"), Color("4cc9f0"),
	]
	space.ball = Color("f8f9fa")
	space.paddle = Color("f9c74f")
	space.accent = Color("f9c74f")
	space.trail = Color("4cc9f0")
	space.aim = Color("4cc9f0")
	space.text_primary = Color("ebf0ff")
	space.text_secondary = Color("c9d9ec")
	result.append(space)

	# 第 2 关「紫罗兰」：紫 → 粉 → 琥珀，与第 1 关的暖冷分布完全相反
	var violet := Palette.new()
	violet.background = Color("120a1e")
	violet.row_colors = [
		Color("7b2cbf"), Color("9d4edd"), Color("c77dff"),
		Color("f72585"), Color("ff8fa3"), Color("ffc857"),
	]
	violet.ball = Color("f3e8ff")
	violet.paddle = Color("c77dff")
	violet.accent = Color("ff8fa3")
	violet.trail = Color("c77dff")
	violet.aim = Color("ff8fa3")
	violet.text_primary = Color("f6ecff")
	violet.text_secondary = Color("cbb2e0")
	result.append(violet)

	# 第 3 关「熔岩」：整墙暖色，越往下越接近岩浆
	var lava := Palette.new()
	lava.background = Color("170b07")
	lava.row_colors = [
		Color("ff9f1c"), Color("ff6b35"), Color("f94144"),
		Color("e85d04"), Color("dc2f02"), Color("9a031e"),
	]
	lava.ball = Color("fff3d6")
	lava.paddle = Color("ff9f1c")
	lava.accent = Color("f94144")
	lava.trail = Color("ff6b35")
	lava.aim = Color("ff9f1c")
	lava.text_primary = Color("fff0dc")
	lava.text_secondary = Color("d9b08c")
	result.append(lava)

	return result
