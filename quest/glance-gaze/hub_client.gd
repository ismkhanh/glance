class_name HubClient
extends Node
## Quest Desk link to the Mac: one WebSocket for terminals, voice and the screen stream.
## Text packets are JSON. Binary packets starting with "A" are voice going to the Mac
## (24 kHz mono 16 bit PCM from the microphone bus); packets starting with "S" are screen
## JPEG frames coming back. While a pinch is held, microphone frames are mixed to mono,
## resampled to 24 kHz and streamed, so the Mac hears you as you speak.

signal connected
signal disconnected
signal term_list(terms: Array)
signal term_output(id: String, title: String, text: String)
signal term_closed(id: String)
signal heard(id: String, text: String)
signal voice_partial(id: String, text: String)
signal error_message(text: String)
signal screen_frame(image: Image)
signal windows_list(windows: Array, more: int, display: Dictionary)
signal window_frame(id: int, image: Image)

var _windows_ok := false

var url := ""
var token := ""

var _socket := WebSocketPeer.new()
var _state := WebSocketPeer.STATE_CLOSED
var _retry_in := 0.0
var _greeted := false

var _mic_player: AudioStreamPlayer
var _capture: AudioEffectCapture
var _recording := false
var _resample_at := 0.0
var _pending: PackedVector2Array = []
var _out := PackedByteArray()

const OUT_RATE := 24000.0


func _ready() -> void:
	_mic_player = AudioStreamPlayer.new()
	_mic_player.stream = AudioStreamMicrophone.new()
	_mic_player.bus = &"Record"
	add_child(_mic_player)
	var idx := AudioServer.get_bus_index("Record")
	if idx >= 0 and AudioServer.get_bus_effect_count(idx) > 0:
		_capture = AudioServer.get_bus_effect(idx, 0) as AudioEffectCapture


func connect_to_mac(mac_address: String, port: int, quest_token: String) -> void:
	token = quest_token
	url = "ws://%s:%d" % [mac_address, port]
	_open()


func _open() -> void:
	if _state == WebSocketPeer.STATE_OPEN or _state == WebSocketPeer.STATE_CONNECTING:
		return
	var err := _socket.connect_to_url(url)
	if err != OK:
		push_warning("Quest Desk: could not connect to %s (%s)" % [url, error_string(err)])
		_retry_in = 3.0


func _process(delta: float) -> void:
	if url.is_empty():
		return
	_socket.poll()
	_state = _socket.get_ready_state()
	match _state:
		WebSocketPeer.STATE_OPEN:
			if not _greeted:
				_greeted = true
				send_json({"type": "hello", "app": "Glance Gaze Quest Desk", "token": token, "proto": 2})
				send_json({"type": "screen_want", "on": true})
				connected.emit()
			while _socket.get_available_packet_count() > 0:
				var packet := _socket.get_packet()
				if _socket.was_string_packet():
					_handle_text(packet.get_string_from_utf8())
				elif packet.size() > 1 and packet[0] == 0x53: # "S": screen frame
					var image := Image.new()
					if image.load_jpg_from_buffer(packet.slice(1)) == OK:
						screen_frame.emit(image)
				elif packet.size() > 5 and packet[0] == 0x57: # "W": one floating-window frame
					var wid := (int(packet[1]) << 24) | (int(packet[2]) << 16) | (int(packet[3]) << 8) | int(packet[4])
					var image := Image.new()
					if image.load_jpg_from_buffer(packet.slice(5)) == OK:
						window_frame.emit(wid, image)
		WebSocketPeer.STATE_CLOSED:
			if _greeted:
				_greeted = false
				disconnected.emit()
			_retry_in -= delta
			if _retry_in <= 0.0:
				_retry_in = 3.0
				_socket = WebSocketPeer.new()
				_open()
	if _recording:
		_pump_mic()


func _handle_text(text: String) -> void:
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var msg: Dictionary = parsed
	match String(msg.get("type", "")):
		"hello":
			_windows_ok = bool(msg.get("windows", false))
			if _windows_ok:
				send_json({"type": "windows_want", "on": true})
		"windows":
			windows_list.emit(msg.get("windows", []), int(msg.get("more", 0)), msg.get("display", {}))
		"term_list":
			term_list.emit(msg.get("terms", []))
		"term_output":
			term_output.emit(String(msg.get("id", "")), String(msg.get("title", "")), String(msg.get("text", "")))
		"term_closed":
			term_closed.emit(String(msg.get("id", "")))
		"heard":
			heard.emit(String(msg.get("id", "")), String(msg.get("text", "")))
		"voice_partial":
			voice_partial.emit(String(msg.get("id", "")), String(msg.get("text", "")))
		"error":
			error_message.emit(String(msg.get("text", "Something went wrong on the Mac.")))


func send_json(msg: Dictionary) -> void:
	if _state == WebSocketPeer.STATE_OPEN:
		_socket.send_text(JSON.stringify(msg))


## Floating windows: gaze on a panel, which panel is live, and pinch actions inside it.
func send_highlight(id: int) -> void:
	send_json({"type": "highlight", "window": id})


func send_gaze_window(id: int, x: float, y: float, talk: bool) -> void:
	send_json({"type": "gaze", "window": id, "x": snappedf(x, 0.0001), "y": snappedf(y, 0.0001), "talk": talk})


func send_action(kind: String, id: int, x: float, y: float) -> void:
	send_json({"type": kind, "window": id, "x": snappedf(x, 0.0001), "y": snappedf(y, 0.0001)})


func create_terminal() -> void:
	send_json({"type": "term_create"})


func close_terminal(id: String) -> void:
	send_json({"type": "term_close", "id": id})


func send_input(id: String, text: String) -> void:
	send_json({"type": "term_input", "id": id, "text": text})


## Pinch went down on a terminal: start streaming the microphone to the Mac.
func start_voice(id: String) -> void:
	if _capture == null:
		error_message.emit("No microphone capture bus on the Quest. Check the Record bus.")
		return
	send_json({"type": "voice_begin", "id": id, "rate": int(OUT_RATE)})
	_capture.clear_buffer()
	_pending.clear()
	_out.clear()
	_resample_at = 0.0
	_recording = true
	_mic_player.play()


## Pinch let go after speaking: the Mac transcribes and runs the words in that terminal.
func stop_voice(id: String) -> void:
	_pump_mic()
	_flush_audio()
	_recording = false
	_mic_player.stop()
	send_json({"type": "voice_end", "id": id})


## A short tap is not speech: drop the take so nothing is transcribed or typed.
func cancel_voice(id: String) -> void:
	_recording = false
	_mic_player.stop()
	_out.clear()
	send_json({"type": "voice_cancel", "id": id})


func _pump_mic() -> void:
	if _capture == null:
		return
	var available := _capture.get_frames_available()
	if available <= 0:
		return
	_pending.append_array(_capture.get_buffer(available))
	var in_rate := AudioServer.get_mix_rate()
	var step := in_rate / OUT_RATE
	while _resample_at + 1.0 < _pending.size():
		var at := int(_resample_at)
		var frame := _pending[at]
		var mono := clampf((frame.x + frame.y) * 0.5, -1.0, 1.0)
		var sample := int(mono * 32767.0)
		_out.append(sample & 0xff)
		_out.append((sample >> 8) & 0xff)
		_resample_at += step
		if _out.size() >= 4800: # 100 ms of audio
			_flush_audio()
	var drop := int(_resample_at)
	if drop > 0:
		_pending = _pending.slice(drop)
		_resample_at -= drop


func _flush_audio() -> void:
	if _out.is_empty() or _state != WebSocketPeer.STATE_OPEN:
		return
	var packet := PackedByteArray([0x41]) # "A"
	packet.append_array(_out)
	_socket.send(packet, WebSocketPeer.WRITE_MODE_BINARY)
	_out.clear()
