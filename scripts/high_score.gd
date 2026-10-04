class_name HighScore
extends RefCounted
## 最高分本地存档：用 ConfigFile 保存在 user:// 下，游戏重启后依然保留。

const SAVE_PATH := "user://2d_breakout_save.cfg"
const SECTION := "progress"
const KEY_BEST := "best_score"

## 读取历史最高分；存档不存在或字段异常时返回 0。
static func load_best() -> int:
	var config := ConfigFile.new()
	if config.load(SAVE_PATH) != OK:
		return 0
	var raw: Variant = config.get_value(SECTION, KEY_BEST, 0)
	# 存档被手工改坏时不静默吞掉，给出提示并按 0 处理
	if typeof(raw) != TYPE_INT and typeof(raw) != TYPE_FLOAT:
		push_warning("最高分存档字段类型异常（%s），按 0 处理" % str(raw))
		return 0
	return int(raw)


## 写入最高分，返回是否保存成功。
static func save_best(best_score: int) -> bool:
	var config := ConfigFile.new()
	# 先把已有内容读进来，避免覆盖同一配置文件里的其它字段
	config.load(SAVE_PATH)
	config.set_value(SECTION, KEY_BEST, best_score)
	return config.save(SAVE_PATH) == OK
