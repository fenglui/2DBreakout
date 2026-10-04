class_name SfxBus
extends Node
## 程序化音效（Autoload 名：Sfx，类型：SfxBus）
##
## 不依赖任何音频资源文件：用 AudioStreamGenerator 在运行时逐样本合成波形，
## 与项目「无外部资源」的约束保持一致。
##
## 用法：在节点里写 `@onready var sfx: SfxBus = SfxBus.instance(self)`，然后 `sfx.play("brick")`。
## 之所以用 get_node 而不是直接写全局名 Sfx，是因为 `godot --check-only --script` 不会实例化
## autoload，直接引用全局名会让静态检查失败（CI 的静态门禁依赖这条命令）。
##
## 无头模式（--headless）下音频驱动是 Dummy，get_stream_playback() 返回 null，
## 所有调用都会安全空转，不影响无头测试。
##
## Godot 4.7 的 API 形态（与旧版差异较大，踩过的坑记在这里）：
## - AudioStreamGenerator 只有 mix_rate / mix_rate_mode / buffer_length，没有 max_latency_msec
## - AudioStreamPlayer.get_stream_playback() 返回 AudioStreamPlayback，
##   真正可用的是其子类 AudioStreamGeneratorPlayback：get_frames_available() / push_buffer()
## - AudioStreamGenerator 自己没有 get_playback()：开播前拿不到缓冲区，无法预热。
##   调用不存在的 native 方法在 GDScript 里是运行时错误，会中断所在的 _ready()，
##   表现为「播放器建了但从未开播」——所有平台一起没声音，而 --check-only 不报错。
## - 播放类型属性叫 playback_type（旧文档的 playback_mode 在 4.7 已删除），枚举挂在
##   AudioServer 上：PLAYBACK_TYPE_DEFAULT / STREAM / SAMPLE。Web 平台必须用 STREAM。
## - GDScript 里没有 AudioFrame 类型，音频帧用 Vector2 表示：x = 左声道，y = 右声道
## - GDScript 逐样本混音是性能敏感路径：采样率取 22050（连击音效按 pitch=2.0 拉到
##   2640Hz 仍远低于 Nyquist），声部用带成员变量的内部类而不是 Dictionary，
##   避免每样本十次字典取值。

const MIX_RATE := 22050
## 同时发声的最大音数，防止极端情况下声部无限增长
const MAX_VOICES := 24
## 单帧最多补算的样本数。必须明显大于「一帧需要消费的样本数」（44100/60≈735、22050/60≈368），
## 否则生成速率长期低于消费速率，缓冲区必然持续欠载，表现为爆音/断续。
const MAX_FRAMES_PER_TICK := 2048
## 每帧额外多补的样本，吸收帧时间抖动
const CATCH_UP_SLACK := 128

const WAVE_SINE := 0
const WAVE_SQUARE := 1
const WAVE_SAWTOOTH := 2
const WAVE_NOISE := 3

## 预设里的波形名 -> 波形枚举
const WAVE_BY_NAME := {
	"sine": WAVE_SINE,
	"square": WAVE_SQUARE,
	"sawtooth": WAVE_SAWTOOTH,
	"noise": WAVE_NOISE,
}

## 音效预设：每个条目是若干音符，各自带起始延迟（秒）
const PRESETS := {
	"wall":   [{"f0": 300.0, "f1": 210.0, "dur": 0.05, "wave": "square", "vol": 0.14, "delay": 0.0}],
	"paddle": [{"f0": 230.0, "f1": 150.0, "dur": 0.09, "wave": "sine",   "vol": 0.28, "delay": 0.0}],
	"brick":  [{"f0": 620.0, "f1": 980.0, "dur": 0.07, "wave": "square", "vol": 0.20, "delay": 0.0}],
	"crack":  [
		{"f0": 190.0, "f1": 120.0, "dur": 0.07, "wave": "noise",  "vol": 0.22, "delay": 0.0},
		{"f0": 420.0, "f1": 300.0, "dur": 0.05, "wave": "square", "vol": 0.10, "delay": 0.02},
	],
	"launch": [{"f0": 330.0, "f1": 900.0, "dur": 0.16, "wave": "sine",   "vol": 0.26, "delay": 0.0}],
	# 蓄力：低频持续音，用短促的单音近似「能量聚集」的听感
	"charge": [
		{"f0": 200.0, "f1": 520.0, "dur": 0.10, "wave": "sawtooth", "vol": 0.10, "delay": 0.00},
		{"f0": 400.0, "f1": 780.0, "dur": 0.08, "wave": "sine",     "vol": 0.08, "delay": 0.07},
	],
	# 连击入账：上行琶音，音高随连击数升高（play 的 pitch 参数）
	"combo": [
		{"f0": 660.0, "f1": 660.0, "dur": 0.07, "wave": "square", "vol": 0.16, "delay": 0.00},
		{"f0": 880.0, "f1": 880.0, "dur": 0.07, "wave": "square", "vol": 0.16, "delay": 0.06},
		{"f0": 1320.0, "f1": 1320.0, "dur": 0.12, "wave": "sine",  "vol": 0.18, "delay": 0.12},
	],
	"life":   [
		{"f0": 320.0, "f1": 90.0, "dur": 0.42, "wave": "sawtooth", "vol": 0.26, "delay": 0.0},
		{"f0": 160.0, "f1": 60.0, "dur": 0.30, "wave": "sine",     "vol": 0.18, "delay": 0.06},
	],
	# 生命砖：上行三音。和 life（掉命，下行）方向相反，
	# 玩家不用看画面就能分清「捡到命」还是「掉了一条命」
	"powerup": [
		{"f0": 523.0, "f1": 523.0, "dur": 0.09, "wave": "square",   "vol": 0.18, "delay": 0.00},
		{"f0": 784.0, "f1": 784.0, "dur": 0.09, "wave": "square",   "vol": 0.18, "delay": 0.07},
		{"f0": 1046.0, "f1": 1046.0, "dur": 0.20, "wave": "sine",    "vol": 0.20, "delay": 0.14},
	],
	# 爆破砖：宽带噪声 + 下滑低频。噪声层给「炸开」的瞬间，
	# 低频层给重量；只给其中一层都会显得像普通砖碎的音效
	"boom": [
		{"f0": 900.0, "f1": 140.0, "dur": 0.30, "wave": "noise",  "vol": 0.30, "delay": 0.0},
		{"f0": 180.0, "f1": 48.0, "dur": 0.34, "wave": "sawtooth", "vol": 0.22, "delay": 0.02},
	],
	# 分裂砖：两声短促短音错开，读起来像「一分为二」
	"split": [
		{"f0": 740.0, "f1": 980.0, "dur": 0.06, "wave": "square", "vol": 0.16, "delay": 0.0},
		{"f0": 980.0, "f1": 740.0, "dur": 0.06, "wave": "square", "vol": 0.16, "delay": 0.05},
	],
	# 减速砖：长音程下滑的三角波，「慢下来」的听觉暗示
	"slow": [
		{"f0": 700.0, "f1": 300.0, "dur": 0.34, "wave": "sine", "vol": 0.20, "delay": 0.0},
		{"f0": 350.0, "f1": 150.0, "dur": 0.28, "wave": "sine", "vol": 0.14, "delay": 0.06},
	],
	"over":   [
		{"f0": 440.0, "f1": 440.0, "dur": 0.18, "wave": "square", "vol": 0.20, "delay": 0.00},
		{"f0": 349.0, "f1": 349.0, "dur": 0.18, "wave": "square", "vol": 0.20, "delay": 0.14},
		{"f0": 293.0, "f1": 293.0, "dur": 0.18, "wave": "square", "vol": 0.20, "delay": 0.28},
		{"f0": 220.0, "f1": 110.0, "dur": 0.55, "wave": "square", "vol": 0.24, "delay": 0.42},
	],
	"clear":  [
		{"f0": 523.0, "f1": 523.0, "dur": 0.12, "wave": "square", "vol": 0.18, "delay": 0.00},
		{"f0": 659.0, "f1": 659.0, "dur": 0.12, "wave": "square", "vol": 0.18, "delay": 0.09},
		{"f0": 784.0, "f1": 784.0, "dur": 0.12, "wave": "square", "vol": 0.18, "delay": 0.18},
		{"f0": 1046.0, "f1": 1046.0, "dur": 0.26, "wave": "square", "vol": 0.20, "delay": 0.27},
	],
	"win":    [
		{"f0": 523.0, "f1": 523.0, "dur": 0.14, "wave": "square", "vol": 0.18, "delay": 0.00},
		{"f0": 659.0, "f1": 659.0, "dur": 0.14, "wave": "square", "vol": 0.18, "delay": 0.11},
		{"f0": 784.0, "f1": 784.0, "dur": 0.14, "wave": "square", "vol": 0.18, "delay": 0.22},
		{"f0": 1046.0, "f1": 1046.0, "dur": 0.14, "wave": "square", "vol": 0.18, "delay": 0.33},
		{"f0": 1318.0, "f1": 1318.0, "dur": 0.45, "wave": "square", "vol": 0.22, "delay": 0.44},
	],
	"ui":     [{"f0": 880.0, "f1": 880.0, "dur": 0.04, "wave": "square", "vol": 0.14, "delay": 0.0}],
}

var enabled := true


## 单个发声单元。用成员变量而不是字典：混音是每样本执行的热路径。
class Voice:
	var f0 := 440.0
	var f1 := 440.0
	var dur := 0.1
	var wave := WAVE_SINE
	var vol := 0.2
	var start := 0
	var phase := 0.0
	var done := false


## 取得 autoload 单例。找不到时返回 null，调用方需判空。
static func instance(node: Node) -> SfxBus:
	return node.get_node_or_null("/root/Sfx") as SfxBus


var _generator: AudioStreamGenerator
var _player: AudioStreamPlayer
var _playback: AudioStreamGeneratorPlayback
var _voices: Array[Voice] = []
var _frames := PackedVector2Array()
var _sample_index := 0
var _need_cleanup := false


func _ready() -> void:
	# 暂停时也要能发声（UI 音效在暂停面板上触发）
	process_mode = Node.PROCESS_MODE_ALWAYS

	# 无头模式（--headless / --quit / CI）下音频驱动是 Dummy：播出来的声音没人听，
	# 而且 Godot 4.7 的 Dummy 路径不会释放 AudioStreamGeneratorPlayback，
	# 进程退出时会留下一条 ObjectDB 泄漏记录。因此无头下干脆不建播放器。
	if DisplayServer.get_name() == "headless":
		return

	_generator = AudioStreamGenerator.new()
	_generator.mix_rate = MIX_RATE
	_generator.buffer_length = 0.2

	_player = AudioStreamPlayer.new()
	_player.stream = _generator
	_player.volume_db = -4.0
	_player.bus = "Master"
	# Web 平台必须用 Stream 播放类型：默认的 Sample 类型要求把整条流一次性装进内存，
	# 而 AudioStreamGenerator 是一条永不结束的程序化流，Sample 类型下开播会打印
	# "is trying to play a sample from a stream that cannot be sampled"。
	# 引擎源码 scene/audio/audio_stream_player_internal.cpp 的 play_basic() 里就是这个分支。
	# 桌面端保持默认类型：延迟更低，对音效更合适。
	# 注意：属性名是 playback_type（4.7），枚举挂在 AudioServer 上（PlaybackType）。
	# 旧文档里的 playback_mode 在 4.7 已不存在，写它会编译通过但运行时抛
	# "Invalid access to property or key 'playback_mode'"，整个 _ready() 中断、音效全灭。
	if OS.has_feature("web"):
		_player.playback_type = AudioServer.PLAYBACK_TYPE_STREAM
	add_child(_player)
	_player.play()
	_playback = _player.get_stream_playback() as AudioStreamGeneratorPlayback



## 退出时主动停播并放下 playback 引用。
## AudioStreamGeneratorPlayback 由播放器持有引用计数，不显式 stop() 会在进程退出时
## 留下一条 "Leaked instance: AudioStreamGeneratorPlayback" 的 ObjectDB 泄漏记录。
## 用 NOTIFICATION_PREDELETE 而不是 _exit_tree：场景重载（reload_current_scene）也会走
## _exit_tree，在那里 stop() 会让播放器立刻重新实例化一个 playback，重载几次就多份残留；
## PREDELETE 只在真正销毁时触发一次。
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _player != null:
		_player.stop()
		# 关键：放下 GDScript 侧对 playback 的引用。AudioStreamGeneratorPlayback 是
		# AudioStreamPlayer 的成员，播放器销毁时释放的正是这个引用；
		# 只要 GDScript 还持有一份，引用计数就停在 1，ObjectDB 会报泄漏。
		_playback = null


## 显式停播并释放播放器节点。
## 正常退出时 NOTIFICATION_PREDELETE 已足够；但测试脚本用 SceneTree.quit() 结束进程时
## 不会走到节点销毁流程，必须手动 stop() + 放下引用，
## 否则会留下 "Leaked instance: AudioStreamGeneratorPlayback" 的 ObjectDB 泄漏记录。
func shutdown() -> void:
	if _player == null:
		return
	_player.stop()
	_playback = null


## 按音高倍率缩放预设里的音符，返回一份新的音符数组（纯函数，不碰播放器）。
##
## 直接缩放 f0/f1 而不是改 playback.pitch_scale：后者作用于整个播放器，
## 会把正在播放的其它音效（掉命、砖裂）一起拉高，语义就串了。
##
## 抽成 static 有两个原因：
## 1) 无头模式下 _playback 为 null，play() 第一行就返回，光靠调用 play()
##    根本验证不到缩放逻辑——这正是最容易悄悄坏掉的部分。
## 2) 缩放规则（0.25 下限）单独可测，不用非得开音频设备。
static func pitched_notes(preset: String, pitch: float) -> Array:
	# 夹住下限：pitch 过小会让频率掉到 20Hz 以下变成次声，听感反而是「没声音」；
	# 上限交给调用方的业务常量控制，不在这里替它做主。
	var ratio := maxf(pitch, 0.25)
	var notes: Array = []
	for note: Dictionary in PRESETS.get(preset, []):
		var scaled := note.duplicate()
		scaled["f0"] = float(note["f0"]) * ratio
		scaled["f1"] = float(note["f1"]) * ratio
		notes.append(scaled)
	return notes


## 播放一个预设音效。预设名不存在时静默忽略。
## 无头模式（_playback == null）下直接返回，不积累声部。
##
## pitch 是音高倍率（1.0 = 原音），供连击越高音调越高的听感使用。
func play(preset: String, pitch: float = 1.0) -> void:
	if not enabled or _playback == null:
		return
	for note in pitched_notes(preset, pitch):
		# 声部上限：超出就丢最早的那个，宁可截断也不让 voices 无界增长
		if _voices.size() >= MAX_VOICES:
			_voices.pop_front()
		var voice := Voice.new()
		voice.f0 = float(note["f0"])
		voice.f1 = float(note["f1"])
		voice.dur = float(note["dur"])
		voice.wave = int(WAVE_BY_NAME.get(String(note["wave"]), WAVE_SINE))
		voice.vol = float(note["vol"])
		voice.start = _sample_index + int(float(note["delay"]) * MIX_RATE)
		_voices.append(voice)


func _process(delta: float) -> void:
	if _playback == null:
		return

	# 按「本帧需要多少样本」来补，而不是一个小于需求的小常数：
	# 60FPS 下每帧要消费 MIX_RATE/60 个样本，补得比这少就会长期欠载 → 爆音/断续。
	var need := int(ceilf(delta * MIX_RATE)) + CATCH_UP_SLACK
	var available := mini(mini(need, MAX_FRAMES_PER_TICK), _playback.get_frames_available())
	if available <= 0:
		return

	_frames.resize(available)
	for i in available:
		_frames[i] = _next_frame()
	_playback.push_buffer(_frames)

	# 收尾统一清理已结束的声部：不要在逐样本循环里 erase，那是 O(n^2)
	if _need_cleanup:
		var alive: Array[Voice] = []
		for voice in _voices:
			if not voice.done:
				alive.append(voice)
		_voices = alive
		_need_cleanup = false


## 把所有活跃声部混音成一个立体声帧，并推进一个采样点。
func _next_frame() -> Vector2:
	var sum := 0.0
	for voice in _voices:
		if voice.done or _sample_index < voice.start:
			continue
		var local := float(_sample_index - voice.start)
		var total := voice.dur * MIX_RATE
		if local >= total:
			voice.done = true
			_need_cleanup = true
			continue
		var progress := local / total
		# 线性衰减后再平方，得到更自然的收尾
		var envelope := (1.0 - progress) * (1.0 - progress)
		var freq := lerpf(voice.f0, voice.f1, progress)
		voice.phase += TAU * freq / MIX_RATE
		if voice.phase > TAU:
			voice.phase -= TAU
		sum += _wave(voice.wave, voice.phase) * envelope * voice.vol

	_sample_index += 1
	var sample := clampf(sum, -1.0, 1.0)
	return Vector2(sample, sample)


func _wave(kind: int, phase: float) -> float:
	match kind:
		WAVE_SQUARE:
			return 1.0 if sin(phase) >= 0.0 else -1.0
		WAVE_SAWTOOTH:
			return 2.0 * (phase / TAU) - 1.0
		WAVE_NOISE:
			return randf() * 2.0 - 1.0
		_:
			return sin(phase)


## 当前声部数量，供测试与调试读取。
func get_voice_count() -> int:
	return _voices.size()
