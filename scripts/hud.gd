class_name GameHUD
extends CanvasLayer
## 顶部信息栏：分数、生命、最高分、关卡、连击，以及底部的操作提示。
## 另含一个居中的连击飘字标签（ComboPop），只在结算连击奖励时短暂出现。

const COMBO_POP_DURATION := 0.75
const COMBO_POP_RISE := 26.0

@onready var score_label: Label = $ScoreLabel
@onready var best_label: Label = $BestLabel
@onready var lives_label: Label = $LivesLabel
@onready var level_label: Label = $LevelLabel
@onready var balls_label: Label = $BallsLabel
@onready var mode_label: Label = $ModeLabel
@onready var hint_label: Label = $HintLabel
@onready var combo_label: Label = $ComboLabel
@onready var combo_pop: Label = $ComboPop

var _accent := Color("f9c74f")
## 当前这次飘字的 Tween。重播前要 kill 掉上一个，
## 否则两个 tween 会抢同一条 modulate:a，旧的那个还会提前把新飘字藏掉。
var _combo_tween: Tween = null
## 飘字的静止位置。tween 只往上改 position:y，每次重播都要回到这里，
## 因此必须在布局稳定后记一次，不能在 _init() 里取。
var _pop_origin_y := 0.0


func _ready() -> void:
	_pop_origin_y = combo_pop.position.y
	combo_pop.visible = false
	combo_label.visible = false
	balls_label.visible = false
	mode_label.visible = false


func set_score(score: int, best_score: int) -> void:
	score_label.text = "分数 %d" % score
	best_label.text = "最高分 %d" % best_score


func set_lives(lives: int) -> void:
	lives_label.text = "生命 %d" % lives


## max_level 传 0 表示「没有最后一关」（无尽模式），走「第 N 关」的单数写法。
func set_level(level: int, max_level: int) -> void:
	if max_level <= 0:
		level_label.text = "第 %d 关" % level
	else:
		level_label.text = "第 %d / %d 关" % [level, max_level]


## 场上球数。多球下「现在到底有几颗球在飞」是玩家必须随时知道的信息：
## 掉球不再立刻扣命，玩家只能靠这个数字判断这一轮还剩几次机会。
## 只有 >1 时显示——单球是常态，常驻一个「球 ×1」只会把连击这类
## 真正需要被一眼看到的临时状态挤下去。
func set_balls(count: int) -> void:
	balls_label.visible = count > 1
	if count > 1:
		balls_label.text = "球 ×%d" % count


func set_hint(text: String) -> void:
	hint_label.text = text


## 当前玩法与种子（经典模式下 Main 传空串，等于不显示）。
##
## 种子必须在 HUD 上常驻而不是只在菜单里看一眼：无尽与每日都是「这副牌我能
## 复现」才成立的玩法，玩家中途被打断（切窗口、退出）之后回来靠这行字
## 才知道自己玩的是哪一局。
func set_mode(text: String) -> void:
	mode_label.visible = not text.is_empty()
	mode_label.text = text


## combo 为 0 时隐藏连击标签，否则显示当前连击数。
func set_combo(combo: int) -> void:
	combo_label.visible = combo > 0
	if combo > 0:
		combo_label.text = "连击 ×%d" % combo


## 换肤用：强调色同时驱动蓄力条与连击飘字。
## 只存起来，由 flash_combo() 通过 modulate 一次性套上去——
## 再补一条 font_color 的 theme override 就等于把同一个颜色乘了两次平方，
## 熔岩关的 #f94144 会被叠成近乎纯红的 #f31112。
func set_accent(accent: Color) -> void:
	_accent = accent


## 换肤用：主要文字（分数 / 生命 / 关卡 / 连击）与次要文字（最高分 / 提示）分组换色。
##
## 用 add_theme_color_override 而不是改 Label.font_color：
## 后者会写进 Label 自己的资源副本，主题（Web 版靠内嵌字体）就再也管不到它了。
func set_text_colors(primary: Color, secondary: Color) -> void:
	for label in [score_label, lives_label, level_label, balls_label, combo_label]:
		(label as Label).add_theme_color_override("font_color", primary)
	for label in [best_label, hint_label, mode_label]:
		(label as Label).add_theme_color_override("font_color", secondary)


## 连击入账时在画面中央飘一行字。
##
## Tween 用 get_tree().create_tween() 而不是 create_tween()：
## HUD 是常驻节点，但整局重开走 reload_current_scene，
## 绑在 HUD 上的 tween 会在节点被 free 的同一帧尝试写入已释放的对象。
## 每次重播先 kill 上一次：连击结算很密集，不掐断旧 tween 的话
## 两个 tween 会同时写 modulate:a，旧的那个收尾时还会把新飘字提前藏掉。
func flash_combo(combo: int, bonus: int) -> void:
	if combo <= 0:
		return
	if _combo_tween != null and _combo_tween.is_valid():
		_combo_tween.kill()
	combo_pop.text = "连击 ×%d   +%d" % [combo, bonus]
	combo_pop.visible = true
	combo_pop.modulate = _accent
	# 每次重播都从同一位置起跳：连击结算很密集，复用位置才不会叠成一团
	combo_pop.position = Vector2(combo_pop.position.x, _pop_origin_y)

	var tween := get_tree().create_tween()
	_combo_tween = tween
	tween.set_parallel(true)
	tween.tween_property(combo_pop, "position:y",
		_pop_origin_y - COMBO_POP_RISE, COMBO_POP_DURATION) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(combo_pop, "modulate:a", 0.0, COMBO_POP_DURATION)
	tween.chain().tween_callback(func() -> void: combo_pop.visible = false)
