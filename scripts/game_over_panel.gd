class_name GameOverPanel
extends CanvasLayer
## 结算面板：游戏结束 / 关卡通过 / 全部通关三种结算，显示标题、分数、最高分、
## 继续按钮与退出按钮。面板始终处理输入，因此暂停状态下按钮依然可点。

signal continue_requested()
signal quit_requested()

## 结算统计标签，只在连击次数不为 0 时显示整行
@onready var stats_label: Label = $Panel/Margin/VBox/StatsLabel

@onready var panel: PanelContainer = $Panel
@onready var title_label: Label = $Panel/Margin/VBox/TitleLabel
@onready var final_score_label: Label = $Panel/Margin/VBox/FinalScoreLabel
@onready var best_score_label: Label = $Panel/Margin/VBox/BestScoreLabel
@onready var continue_button: Button = $Panel/Margin/VBox/ContinueButton
@onready var quit_button: Button = $Panel/Margin/VBox/QuitButton
@onready var sfx: SfxBus = SfxBus.instance(self)


func _ready() -> void:
	# 暂停时也要能响应按钮，所以面板始终处理输入
	process_mode = Node.PROCESS_MODE_ALWAYS
	continue_button.pressed.connect(_on_continue_button_pressed)
	quit_button.pressed.connect(_on_quit_button_pressed)
	panel.visible = false


## 显示结算信息。
## mode 取 Main.State 中的 GAME_OVER / LEVEL_CLEAR / WON 三种之一。
## best_combo / combo_total 展示连击战绩；为 0 时整行隐藏（第一关没打出连击很正常）。
## palette 传 null 时沿用默认强调色（老场景没配调色板也能跑）。
func show_result(final_score: int, best_score: int, is_new_best: bool, mode: int,
		level: int = 1, best_combo: int = 0, combo_total: int = 0,
		palette: Palette = null) -> void:
	match mode:
		Main.State.LEVEL_CLEAR:
			title_label.text = "第 %d 关通过！" % level
			continue_button.text = "下一关"
		Main.State.WON:
			title_label.text = "通关！"
			continue_button.text = "再来一局"
		_:
			title_label.text = "游戏结束"
			continue_button.text = "再来一局"

	final_score_label.text = "最终分数 %d" % final_score
	if is_new_best:
		best_score_label.text = "新纪录！最高分 %d" % best_score
	else:
		best_score_label.text = "最高分 %d" % best_score

	# 通关时不统计连击：整局都打完了，「本局最高连击」已经没有参考价值
	if mode == Main.State.WON or combo_total <= 0:
		stats_label.visible = false
	else:
		stats_label.visible = true
		stats_label.text = "最高连击 ×%d · 连击结算 %d 次" % [best_combo, combo_total]

	set_palette(palette)
	panel.visible = true
	continue_button.grab_focus()


## 换肤用：标题与连击统计行吃当前关卡的强调色与主要文字色。
## 不给面板整体上色——面板底色是 StyleBox 资源，改它会跨场景重载残留。
func set_palette(palette: Palette) -> void:
	var accent := Color("f9c74f") if palette == null else palette.accent
	var primary := Color("ebf0ff") if palette == null else palette.text_primary
	title_label.add_theme_color_override("font_color", primary)
	stats_label.add_theme_color_override("font_color", accent)


func hide_result() -> void:
	panel.visible = false


func _on_continue_button_pressed() -> void:
	if sfx != null:
		sfx.play("ui")
	continue_requested.emit()


func _on_quit_button_pressed() -> void:
	if sfx != null:
		sfx.play("ui")
	quit_requested.emit()
