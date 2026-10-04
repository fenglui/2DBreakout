class_name GameHUD
extends CanvasLayer
## 顶部信息栏：分数、生命、最高分、关卡，以及底部的操作提示。

@onready var score_label: Label = $ScoreLabel
@onready var best_label: Label = $BestLabel
@onready var lives_label: Label = $LivesLabel
@onready var level_label: Label = $LevelLabel
@onready var hint_label: Label = $HintLabel


func set_score(score: int, best_score: int) -> void:
	score_label.text = "分数 %d" % score
	best_label.text = "最高分 %d" % best_score


func set_lives(lives: int) -> void:
	lives_label.text = "生命 %d" % lives


func set_level(level: int, max_level: int) -> void:
	level_label.text = "第 %d / %d 关" % [level, max_level]


func set_hint(text: String) -> void:
	hint_label.text = text
