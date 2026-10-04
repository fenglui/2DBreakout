class_name GameOverPanel
extends CanvasLayer
## 结算面板：游戏结束 / 关卡通过 / 全部通关三种结算，显示标题、分数、最高分、
## 继续按钮与退出按钮。面板始终处理输入，因此暂停状态下按钮依然可点。

signal continue_requested()
signal quit_requested()

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
func show_result(final_score: int, best_score: int, is_new_best: bool, mode: int, level: int = 1) -> void:
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
	panel.visible = true
	continue_button.grab_focus()


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
