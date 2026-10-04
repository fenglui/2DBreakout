class_name GameOverPanel
extends CanvasLayer
## 结算面板：游戏结束 / 全部通关时显示标题、最终分数、最高分与重开按钮。

signal restart_requested()

@onready var panel: PanelContainer = $Panel
@onready var title_label: Label = $Panel/Margin/VBox/TitleLabel
@onready var final_score_label: Label = $Panel/Margin/VBox/FinalScoreLabel
@onready var best_score_label: Label = $Panel/Margin/VBox/BestScoreLabel
@onready var restart_button: Button = $Panel/Margin/VBox/RestartButton


func _ready() -> void:
	# 暂停时也要能响应按钮，所以面板始终处理输入
	process_mode = Node.PROCESS_MODE_ALWAYS
	restart_button.pressed.connect(_on_restart_button_pressed)
	panel.visible = false


## 显示结算信息。victory 为真时按“通关”呈现。
func show_result(final_score: int, best_score: int, is_new_best: bool, victory: bool = false) -> void:
	title_label.text = "通关！" if victory else "游戏结束"
	final_score_label.text = "最终分数 %d" % final_score
	if is_new_best:
		best_score_label.text = "新纪录！最高分 %d" % best_score
	else:
		best_score_label.text = "最高分 %d" % best_score
	panel.visible = true
	restart_button.grab_focus()


func _on_restart_button_pressed() -> void:
	restart_requested.emit()
