extends StartXR
## Glance Quest Desk: your Mac, floating in the room.
##
## A big panel streams your Mac screen. Below it, terminal panels are real shells on the Mac
## (started by Glance there, `--quest`). Turn your head to face a terminal: it lights up.
## Hold an index pinch (or a controller trigger), speak, and let go: the Mac transcribes
## your words and runs them in that shell. A quick tap on the "+ New terminal" tile opens
## another shell. Your eyes still move the Mac pointer when you look at the screen panel.
##
## Floating windows (protocol 2, needs GLANCE_QUEST_TOKEN on both ends): each Mac window is
## its own panel, placed where the window sits on the streamed screen. Look at a panel and:
## pinch its bottom-right corner and drag to zoom it (aspect locked; the Mac window itself
## does not resize), or pinch the bar at the bottom-centre and drag to move the panel in the
## room. Left pinch elsewhere on a panel talks to that window; right pinch clicks, and a held
## right pinch drags inside it.
##
## On the Mac:  launch Glance (Glance.command, or `swift run -c release Glance`). Then open
## this app: it finds the Mac by itself on the same Wi-Fi. No address or token to type.
## The exports below are only an override for development: set mac_address to skip discovery.

@export var mac_address := ""
@export var mac_port := 47811
@export var gaze_port := 47810
@export var quest_token := ""

const DISCOVERY_PORT := 47812

const EYES := "/user/eyes_ext"
const SCREEN_SIZE := Vector2(1.7, 0.96)
const TERM_SIZE := Vector2(1.06, 0.62)
const NEW_ID := "__new__"

var hub
var udp := PacketPeerUDP.new()

var screen_panel: Dictionary = {}
var screen_texture := ImageTexture.new()
var panels: Array[Dictionary] = [] # each: root, back, label, title, id, size
var new_panel: Dictionary = {}

var focused: Dictionary = {}
var pinch_down := false
var pinch_at := 0.0
var pinch_panel: Dictionary = {}
var talking := false
var status_until := 0.0

# Floating windows: one panel per Mac window, plus the grab state for resize/move.
var window_panels: Array[Dictionary] = [] # each: panel dict + win_id, aspect, texture
var gaze_window_hit: Dictionary = {}      # {panel, uv, world} under the eyes this frame
var highlighted_id := -1
var grab: Dictionary = {}                 # {mode, panel, hand, plane_point, plane_normal, anchor, offset}
var grab_hand_ref: XRController3D
var left_down := false
var right_down := false
var mac_drag: Dictionary = {}             # right pinch inside a panel: {panel, uv, at, started}
var talk_window_id := -1                  # left pinch held on a panel (talk to that window)
var last_gaze_sent := 0.0

const MIN_PANEL_WIDTH := 0.28
const MAX_PANEL_WIDTH := 2.4

@onready var origin: XROrigin3D = $XROrigin3D
@onready var camera: XRCamera3D = $XROrigin3D/XRCamera3D
@onready var right_hand: XRController3D = $XROrigin3D/RightController
@onready var left_hand: XRController3D = $XROrigin3D/LeftController
@onready var label: Label3D = $XROrigin3D/XRCamera3D/Help
@onready var dot: MeshInstance3D = $Dot


func _ready() -> void:
	super._ready()
	if OS.get_name() == "Android":
		OS.request_permissions() # eye tracking and the microphone are asked for at runtime
	dot.visible = false

	hub = preload("res://hub_client.gd").new()
	add_child(hub)
	hub.connected.connect(_on_connected)
	hub.disconnected.connect(func() -> void: _status("Lost the Mac. Trying again…"))
	hub.term_list.connect(_on_term_list)
	hub.term_output.connect(_on_term_output)
	hub.term_closed.connect(_on_term_closed)
	hub.heard.connect(func(_id: String, text: String) -> void: _status("Heard: %s" % text, 4.0))
	hub.voice_partial.connect(func(_id: String, text: String) -> void: _status("Hearing: %s" % text, 1.0))
	hub.error_message.connect(func(text: String) -> void: _status(text, 5.0))
	hub.screen_frame.connect(_on_screen_frame)
	hub.windows_list.connect(_on_windows_list)
	hub.window_frame.connect(_on_window_frame)
	if mac_address.is_empty():
		_discover_and_connect()
	else:
		_connect_to(mac_address, mac_port)

	screen_panel = _make_panel("Your Mac", SCREEN_SIZE, Vector3(0, 1.62, -1.8))
	screen_panel["is_screen"] = true
	new_panel = _make_panel("+ New terminal", Vector2(0.52, TERM_SIZE.y), Vector3.ZERO)
	new_panel["id"] = NEW_ID
	new_panel["label"].text = "Tap with a quick pinch\nto open a shell on your Mac"
	new_panel["label"].font_size = 30
	_layout_panels()
	_status("Connecting to your Mac…")


func _connect_to(ip: String, port: int) -> void:
	udp.set_dest_address(ip, gaze_port)
	hub.connect_to_mac(ip, port, quest_token)
	_status("Connecting to your Mac…")


## Broadcast "GLANCE_DISCOVER" until a Mac answers with its port, then connect to the sender.
## This is the whole setup on the headset: same Wi-Fi, open the app.
func _discover_and_connect() -> void:
	_status("Looking for your Mac…")
	var peer := PacketPeerUDP.new()
	peer.set_broadcast_enabled(true)
	if peer.bind(0) != OK:
		_status("Could not look for your Mac. Reopen the app.", 6.0)
		return
	peer.set_dest_address("255.255.255.255", DISCOVERY_PORT)
	var deadline := Time.get_ticks_msec() / 1000.0 + 20.0
	var next_send := 0.0
	while Time.get_ticks_msec() / 1000.0 < deadline:
		var now := Time.get_ticks_msec() / 1000.0
		if now >= next_send:
			peer.put_packet("GLANCE_DISCOVER".to_utf8_buffer())
			next_send = now + 1.0
		while peer.get_available_packet_count() > 0:
			var ip := peer.get_packet_ip()
			var parsed: Variant = JSON.parse_string(peer.get_packet().get_string_from_utf8())
			var port := mac_port
			if typeof(parsed) == TYPE_DICTIONARY:
				port = int((parsed as Dictionary).get("port", mac_port))
			peer.close()
			_connect_to(ip, port)
			return
		await get_tree().process_frame
	peer.close()
	_status("No Mac found. Launch Glance on your Mac (same Wi-Fi), then reopen this app.", 8.0)


func _make_panel(title: String, size: Vector2, pos: Vector3) -> Dictionary:
	var root := Node3D.new()
	root.position = pos
	add_child(root)

	var back := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = size + Vector2(0.03, 0.03)
	back.mesh = quad
	var back_mat := StandardMaterial3D.new()
	back_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	back_mat.albedo_color = Color(0.16, 0.16, 0.22)
	back.material_override = back_mat
	root.add_child(back)

	var face := MeshInstance3D.new()
	var face_quad := QuadMesh.new()
	face_quad.size = size
	face.mesh = face_quad
	face.position.z = 0.002
	var face_mat := StandardMaterial3D.new()
	face_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	face_mat.albedo_color = Color(0.03, 0.03, 0.05, 0.92)
	face.material_override = face_mat
	root.add_child(face)

	var title_label := Label3D.new()
	title_label.text = title
	title_label.font_size = 34
	title_label.pixel_size = 0.0011
	title_label.modulate = Color(0.75, 0.85, 1)
	title_label.position = Vector3(-size.x * 0.48, size.y * 0.5 + 0.035, 0.004)
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	root.add_child(title_label)

	var body := Label3D.new()
	body.font_size = 26
	body.pixel_size = 0.00105
	body.modulate = Color(0.9, 0.95, 0.9)
	body.position = Vector3(-size.x * 0.48, size.y * 0.44, 0.004)
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	body.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	body.width = 980.0
	body.autowrap_mode = TextServer.AUTOWRAP_OFF
	root.add_child(body)

	return {"root": root, "back": back, "face": face, "label": body, "title": title_label,
			"id": "", "size": size, "face_mat": face_mat, "back_mat": back_mat,
			"back_quad": quad, "face_quad": face_quad}


## Re-aim a panel's quads, labels and grab handles at its current size (after a zoom).
func _layout_panel_parts(p: Dictionary) -> void:
	var size: Vector2 = p["size"]
	(p["back_quad"] as QuadMesh).size = size + Vector2(0.03, 0.03)
	(p["face_quad"] as QuadMesh).size = size
	(p["title"] as Label3D).position = Vector3(-size.x * 0.48, size.y * 0.5 + 0.035, 0.004)
	(p["label"] as Label3D).position = Vector3(-size.x * 0.48, size.y * 0.44, 0.004)
	if p.has("grip"):
		(p["grip"] as MeshInstance3D).position = Vector3(size.x * 0.5 - 0.045, -size.y * 0.5 + 0.045, 0.005)
		(p["bar"] as MeshInstance3D).position = Vector3(0, -size.y * 0.5 + 0.028, 0.005)


func _handle_mesh(size: Vector2, color: Color) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = size
	mesh.mesh = quad
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mesh.material_override = mat
	mesh.set_meta("mat", mat)
	return mesh


## A floating window panel: a _make_panel plus a corner grip (zoom) and a bottom bar (move).
func _make_window_panel(win_id: int, title: String, size: Vector2, pos: Vector3, aspect: float) -> Dictionary:
	var p := _make_panel(title, size, pos)
	p["win_id"] = win_id
	p["aspect"] = aspect
	p["label"].text = ""
	var grip := _handle_mesh(Vector2(0.07, 0.07), Color(1, 0.62, 0.25, 0.9))
	var bar := _handle_mesh(Vector2(0.28, 0.035), Color(0.45, 0.6, 0.9, 0.85))
	(p["root"] as Node3D).add_child(grip)
	(p["root"] as Node3D).add_child(bar)
	p["grip"] = grip
	p["bar"] = bar
	_layout_panel_parts(p)
	return p


## Which grab a point on a panel starts: uv is 0..1 from the top-left, as gaze sends it.
## Thresholds carry 0.001 of slack: 0.82 as a float is fractionally under itself, and a
## gaze point computed through a ray hit should still land in the zone it names.
static func grab_zone(uv: Vector2) -> String:
	if uv.x >= 0.819 and uv.y >= 0.819:
		return "resize" # bottom-right corner wins over the bottom edge
	if uv.y >= 0.879 and uv.x >= 0.319 and uv.x <= 0.681:
		return "move"
	return ""


## Panel size while corner-dragging: width follows the corner, height follows the aspect.
static func resized_size(_start_size: Vector2, aspect: float, from_top_left: Vector2) -> Vector2:
	var safe_aspect := maxf(aspect, 0.2)
	var width := clampf(maxf(from_top_left.x, from_top_left.y * safe_aspect), MIN_PANEL_WIDTH, MAX_PANEL_WIDTH)
	return Vector2(width, width / safe_aspect)


func _window_panel(win_id: int) -> Dictionary:
	for p in window_panels:
		if int(p.get("win_id", -1)) == win_id:
			return p
	return {}


func _on_windows_list(windows: Array, more: int, display: Dictionary) -> void:
	var dw := maxf(float(display.get("w", 1920)), 1.0)
	var dh := maxf(float(display.get("h", 1080)), 1.0)
	var wanted: Array[int] = []
	for w in windows:
		var wd: Dictionary = w
		var win_id := int(wd.get("id", 0))
		wanted.append(win_id)
		var bw := maxf(float(wd.get("bw", 400)), 1.0)
		var bh := maxf(float(wd.get("bh", 300)), 1.0)
		var aspect := bw / bh
		var title := String(wd.get("title", ""))
		var app := String(wd.get("app", "Window"))
		var p := _window_panel(win_id)
		if p.is_empty():
			# First sight: mirror the window's place and size on the streamed screen.
			var metres := SCREEN_SIZE.x / dw
			var size := Vector2(clampf(bw * metres, MIN_PANEL_WIDTH, 1.7), 0.0)
			size.y = size.x / aspect
			var centre := Vector3(
				(float(wd.get("bx", 0)) + bw * 0.5) / dw - 0.5,
				0.5 - (float(wd.get("by", 0)) + bh * 0.5) / dh, 0.0)
			var pos := Vector3(centre.x * SCREEN_SIZE.x, 1.62 + centre.y * SCREEN_SIZE.y,
				-1.8 + 0.04 + float(windows.size() - int(wd.get("z", 0))) * 0.004)
			p = _make_window_panel(win_id, app, size, pos, aspect)
			window_panels.append(p)
		else:
			# Keep any place/size the user grabbed; only the shape follows the Mac window.
			p["aspect"] = aspect
			if grab.is_empty() or grab.get("panel") != p:
				var size: Vector2 = p["size"]
				p["size"] = Vector2(size.x, size.x / aspect)
				_layout_panel_parts(p)
		p["title"].text = app if title.is_empty() else "%s — %s" % [app, title]
	for p in window_panels.duplicate():
		if not wanted.has(int(p.get("win_id", -1))):
			(p["root"] as Node3D).queue_free()
			window_panels.erase(p)
	if more > 0:
		_status("%d more windows on the Mac than panels here." % more, 3.0)


func _on_window_frame(win_id: int, image: Image) -> void:
	var p := _window_panel(win_id)
	if p.is_empty():
		return
	if not p.has("texture"):
		p["texture"] = ImageTexture.create_from_image(image)
		p["face_mat"].albedo_texture = p["texture"]
		p["label"].text = ""
	elif (p["texture"] as ImageTexture).get_width() != image.get_width() or (p["texture"] as ImageTexture).get_height() != image.get_height():
		p["texture"] = ImageTexture.create_from_image(image)
		p["face_mat"].albedo_texture = p["texture"]
	else:
		(p["texture"] as ImageTexture).update(image)


func _layout_panels() -> void:
	# Terminals in an arc under the screen; the new terminal tile closes the row.
	var all: Array[Dictionary] = []
	all.append_array(panels)
	all.append(new_panel)
	var total := all.size()
	for i in total:
		var p: Dictionary = all[i]
		var spread := (float(i) - float(total - 1) / 2.0)
		p["root"].position = Vector3(spread * 1.18, 0.82, -1.65 + absf(spread) * 0.12)
		p["root"].rotation.y = -spread * 0.18


func _status(text: String, seconds: float = 3.0) -> void:
	label.text = text
	status_until = Time.get_ticks_msec() / 1000.0 + seconds


func _default_status() -> void:
	if focused.is_empty():
		label.text = "Turn your head to a terminal, hold a pinch, and speak.\nQuick tap on + opens another. Trigger works too."
	elif String(focused.get("id", "")) == NEW_ID:
		label.text = "Quick pinch tap: open a new terminal on your Mac."
	elif focused.has("win_id"):
		label.text = "Facing %s. Left pinch: talk. Right pinch: click/drag. Corner grip: zoom. Bottom bar: move." % String(focused["title"].text)
	else:
		label.text = "Facing %s. Hold a pinch and speak; let go to run it." % String(focused["title"].text)


func _process(_delta: float) -> void:
	_update_gaze() # first, so pinch starts know which panel and zone the eyes are on
	_update_focus()
	_update_pinch()
	if Time.get_ticks_msec() / 1000.0 > status_until and not talking:
		_default_status()


## Head direction chooses the terminal. Eyes keep their old job: the Mac pointer.
func _update_focus() -> void:
	var from := camera.global_position
	var dir := -camera.global_transform.basis.z.normalized()
	var best: Dictionary = {}
	var best_dist := INF
	var candidates: Array[Dictionary] = []
	candidates.append_array(panels)
	candidates.append(new_panel)
	candidates.append_array(window_panels)
	for p in candidates:
		var hit := _ray_hit(p, from, dir)
		if hit.x >= 0.0 and hit.y < best_dist:
			best_dist = hit.y
			best = p
	if best != focused:
		focused = best
		for p in candidates:
			var on: bool = p == focused
			p["back_mat"].albedo_color = Color(0.55, 0.75, 1) if on else Color(0.16, 0.16, 0.22)


## Returns (inside 0 or -1, distance) for a ray against a panel plane.
func _ray_hit(p: Dictionary, from: Vector3, dir: Vector3) -> Vector2:
	var root: Node3D = p["root"]
	var size: Vector2 = p["size"]
	var normal := root.global_transform.basis.z.normalized()
	var facing := normal.dot(dir)
	if absf(facing) < 0.0001:
		return Vector2(-1, INF)
	var dist := normal.dot(root.global_position - from) / facing
	if dist <= 0.0:
		return Vector2(-1, INF)
	var hit := from + dir * dist
	var local := root.global_transform.affine_inverse() * hit
	if absf(local.x) <= size.x / 2.0 and absf(local.y) <= size.y / 2.0:
		return Vector2(0, dist)
	return Vector2(-1, INF)


## Ray against one panel: {panel, uv (0..1 top-left), local (metres from centre), world, dist} or {}.
func _panel_hit(p: Dictionary, from: Vector3, dir: Vector3) -> Dictionary:
	var root: Node3D = p["root"]
	var size: Vector2 = p["size"]
	var normal := root.global_transform.basis.z.normalized()
	var facing := normal.dot(dir)
	if absf(facing) < 0.0001:
		return {}
	var dist := normal.dot(root.global_position - from) / facing
	if dist <= 0.0:
		return {}
	var hit := from + dir * dist
	var local3 := root.global_transform.affine_inverse() * hit
	if absf(local3.x) > size.x / 2.0 or absf(local3.y) > size.y / 2.0:
		return {}
	return {"panel": p, "uv": Vector2(local3.x / size.x + 0.5, 0.5 - local3.y / size.y),
			"local": Vector2(local3.x, local3.y), "world": hit, "dist": dist}


## Point where a ray meets a fixed plane (a grabbed panel stays in its starting plane).
static func _plane_point(from: Vector3, dir: Vector3, point: Vector3, normal: Vector3) -> Variant:
	var facing := normal.dot(dir)
	if absf(facing) < 0.0001:
		return null
	var dist := normal.dot(point - from) / facing
	if dist <= 0.0:
		return null
	return from + dir * dist


func _hand_value(hand: XRController3D) -> float:
	if hand == null:
		return 0.0
	var value := hand.get_float("trigger")
	if hand.is_button_pressed("trigger_click"):
		value = 1.0
	return value


func _pinch_value() -> float:
	return maxf(_hand_value(right_hand), _hand_value(left_hand))


func _try_grab(hand: XRController3D) -> bool:
	if gaze_window_hit.is_empty():
		return false
	var zone := grab_zone(gaze_window_hit["uv"])
	if zone.is_empty():
		return false
	var p: Dictionary = gaze_window_hit["panel"]
	var root: Node3D = p["root"]
	grab = {"mode": zone, "panel": p, "hand": hand,
			"plane_point": root.global_position,
			"plane_normal": root.global_transform.basis.z.normalized(),
			"right": root.global_transform.basis.x.normalized(),
			"up": root.global_transform.basis.y.normalized(),
			"top_left": root.global_transform * Vector3(-(p["size"] as Vector2).x * 0.5, (p["size"] as Vector2).y * 0.5, 0.0),
			"offset": root.global_position - (gaze_window_hit["world"] as Vector3),
			"start_size": p["size"]}
	grab_hand_ref = hand
	_status("Zoom: drag the corner, let go to set." if zone == "resize" else "Move: drag, let go to drop.", 2.0)
	return true


func _update_grab() -> void:
	var found: Variant = _gaze_transform()
	var from: Vector3
	var dir: Vector3
	if found != null:
		var gaze: Transform3D = found
		from = gaze.origin
		dir = -gaze.basis.z.normalized()
	else: # no eye tracking this frame: fall back to where the head faces
		from = camera.global_position
		dir = -camera.global_transform.basis.z.normalized()
	var hit: Variant = _plane_point(from, dir, grab["plane_point"], grab["plane_normal"])
	if hit == null:
		return
	var p: Dictionary = grab["panel"]
	var root: Node3D = p["root"]
	if String(grab["mode"]) == "move":
		root.global_position = (hit as Vector3) + (grab["offset"] as Vector3)
	else:
		var rel := (hit as Vector3) - (grab["top_left"] as Vector3)
		var from_top_left := Vector2(rel.dot(grab["right"]), -rel.dot(grab["up"]))
		var size := resized_size(grab["start_size"], float(p.get("aspect", 1.6)), from_top_left)
		p["size"] = size
		root.global_position = (grab["top_left"] as Vector3) \
			+ (grab["right"] as Vector3) * (size.x * 0.5) - (grab["up"] as Vector3) * (size.y * 0.5)
		_layout_panel_parts(p)


func _update_pinch() -> void:
	var left := _hand_value(left_hand) > 0.85
	var right := _hand_value(right_hand) > 0.85
	var now := Time.get_ticks_msec() / 1000.0

	# An active grab owns its hand until the pinch opens.
	if not grab.is_empty():
		var held := right if grab_hand_ref == right_hand else left
		if held:
			_update_grab()
		else:
			grab = {}
			_status("Panel set.", 1.5)
		left_down = left
		right_down = right
		pinch_down = left or right
		return

	# Pinch starts on a floating window: corner/bar grabs beat every other meaning.
	if right and not right_down and _try_grab(right_hand):
		right_down = true
		pinch_down = true
		return
	if left and not left_down and _try_grab(left_hand):
		left_down = true
		pinch_down = true
		return

	# Right pinch inside a panel: a tap clicks on the Mac; holding it drags there.
	if right and not right_down and not gaze_window_hit.is_empty():
		mac_drag = {"panel": gaze_window_hit["panel"], "uv": gaze_window_hit["uv"], "at": now, "started": false}
	if not mac_drag.is_empty():
		var p: Dictionary = mac_drag["panel"]
		var win_id := int(p.get("win_id", -1))
		if right:
			if not gaze_window_hit.is_empty() and gaze_window_hit["panel"] == p:
				if not bool(mac_drag["started"]) and (now - float(mac_drag["at"]) > 0.25 \
						or (gaze_window_hit["uv"] as Vector2).distance_to(mac_drag["uv"]) > 0.02):
					mac_drag["started"] = true
					hub.send_action("drag_start", win_id, (mac_drag["uv"] as Vector2).x, (mac_drag["uv"] as Vector2).y)
				if bool(mac_drag["started"]):
					hub.send_action("drag_move", win_id, (gaze_window_hit["uv"] as Vector2).x, (gaze_window_hit["uv"] as Vector2).y)
		else:
			if bool(mac_drag["started"]):
				hub.send_action("drag_end", win_id, (mac_drag["uv"] as Vector2).x, (mac_drag["uv"] as Vector2).y)
			else:
				hub.send_action("click", win_id, (mac_drag["uv"] as Vector2).x, (mac_drag["uv"] as Vector2).y)
			mac_drag = {}

	# Left pinch on a panel talks to that Mac window (the Mac's gaze talk key).
	if left and not left_down and not gaze_window_hit.is_empty():
		talk_window_id = int((gaze_window_hit["panel"] as Dictionary).get("win_id", -1))
		if talk_window_id >= 0:
			hub.send_gaze_window(talk_window_id, (gaze_window_hit["uv"] as Vector2).x, (gaze_window_hit["uv"] as Vector2).y, true)
	if not left and talk_window_id >= 0:
		hub.send_gaze_window(talk_window_id, 0.5, 0.5, false)
		talk_window_id = -1

	left_down = left
	right_down = right

	# A pinch already owned by a window or a terminal keeps its meaning until it opens,
	# even if the eyes wander off its panel mid-pinch.
	if talking:
		_update_terminal_pinch(left or right)
		return
	if not mac_drag.is_empty() or talk_window_id >= 0:
		pinch_down = left or right
		return

	# Terminals keep the original any-hand pinch-to-talk, when the eyes are not on a window panel.
	if not gaze_window_hit.is_empty():
		pinch_down = left or right
		return
	_update_terminal_pinch(left or right)


func _update_terminal_pinch(down: bool) -> void:
	if down and not pinch_down:
		pinch_at = Time.get_ticks_msec() / 1000.0
		pinch_panel = focused
		if not focused.is_empty() and String(focused.get("id", "")) != NEW_ID and not focused.has("win_id"):
			talking = true
			hub.start_voice(String(focused["id"]))
			_status("Listening… let go to run it in %s." % focused["title"].text, 30.0)
	elif not down and pinch_down:
		var held := Time.get_ticks_msec() / 1000.0 - pinch_at
		if talking:
			talking = false
			if held < 0.35:
				hub.cancel_voice(String(pinch_panel.get("id", "")))
				_status("Too short to hear. Hold the pinch while you speak.", 3.0)
			else:
				hub.stop_voice(String(pinch_panel.get("id", "")))
				_status("Heard you. Working on it…", 4.0)
		elif not pinch_panel.is_empty() and String(pinch_panel.get("id", "")) == NEW_ID and held < 0.6:
			hub.create_terminal()
			_status("Opening a terminal on your Mac…", 3.0)
		pinch_panel = {}
	pinch_down = down


func _update_gaze() -> void:
	gaze_window_hit = {}
	var found: Variant = _gaze_transform()
	dot.visible = false
	if found == null or screen_panel.is_empty():
		_set_highlight(-1)
		return
	var gaze: Transform3D = found
	var from: Vector3 = gaze.origin
	var dir := -gaze.basis.z.normalized()
	# Floating windows first: the nearest panel under the eyes owns the point.
	var best: Dictionary = {}
	for p in window_panels:
		var hit := _panel_hit(p, from, dir)
		if not hit.is_empty() and (best.is_empty() or float(hit["dist"]) < float(best["dist"])):
			best = hit
	if not best.is_empty():
		gaze_window_hit = best
		var p: Dictionary = best["panel"]
		var win_id := int(p.get("win_id", -1))
		dot.visible = true
		dot.global_position = best["world"]
		_set_highlight(win_id)
		_update_handles(p, best["uv"])
		var now := Time.get_ticks_msec() / 1000.0
		if now - last_gaze_sent > 0.05 or talk_window_id == win_id:
			last_gaze_sent = now
			hub.send_gaze_window(win_id, (best["uv"] as Vector2).x, (best["uv"] as Vector2).y, talk_window_id == win_id)
		return
	_set_highlight(-1)
	var hit := _ray_hit(screen_panel, from, dir)
	if hit.x < 0.0:
		return
	var root: Node3D = screen_panel["root"]
	var local := root.global_transform.affine_inverse() * (from + dir * hit.y)
	var size: Vector2 = screen_panel["size"]
	var x := clampf(local.x / size.x + 0.5, 0.0, 1.0)
	var y := clampf(0.5 - local.y / size.y, 0.0, 1.0)
	dot.visible = true
	dot.global_position = from + dir * hit.y
	udp.put_packet(JSON.stringify({"x": snappedf(x, 0.0001), "y": snappedf(y, 0.0001)}).to_utf8_buffer())


func _set_highlight(win_id: int) -> void:
	if win_id == highlighted_id:
		return
	highlighted_id = win_id
	if hub != null:
		hub.send_highlight(win_id)


## Light the grip/bar when the eyes are on them, so the grab zones are discoverable.
func _update_handles(p: Dictionary, uv: Vector2) -> void:
	if not p.has("grip"):
		return
	var zone := grab_zone(uv)
	((p["grip"] as MeshInstance3D).material_override as StandardMaterial3D).albedo_color = \
		Color(1, 0.85, 0.3) if zone == "resize" else Color(1, 0.62, 0.25, 0.9)
	((p["bar"] as MeshInstance3D).material_override as StandardMaterial3D).albedo_color = \
		Color(0.7, 0.85, 1) if zone == "move" else Color(0.45, 0.6, 0.9, 0.85)


func _gaze_transform() -> Variant:
	var tracker := XRServer.get_tracker(EYES) as XRPositionalTracker
	if tracker == null:
		return null
	for pose_name in ["default", "default_pose"]:
		var pose := tracker.get_pose(pose_name)
		if pose != null and pose.has_tracking_data:
			return origin.global_transform * pose.get_adjusted_transform()
	return null


func _on_connected() -> void:
	_status("Connected to your Mac.", 3.0)
	if panels.is_empty():
		hub.create_terminal()


func _on_term_list(terms: Array) -> void:
	var wanted: Array[String] = []
	for t in terms:
		var td: Dictionary = t
		wanted.append(String(td.get("id", "")))
	for p in panels.duplicate():
		if not wanted.has(String(p["id"])):
			p["root"].queue_free()
			panels.erase(p)
	for t in terms:
		var td: Dictionary = t
		var id := String(td.get("id", ""))
		if _panel(id).is_empty():
			var p := _make_panel(String(td.get("title", "Terminal")), TERM_SIZE, Vector3.ZERO)
			p["id"] = id
			panels.append(p)
	_layout_panels()


func _panel(id: String) -> Dictionary:
	for p in panels:
		if String(p["id"]) == id:
			return p
	return {}


func _on_term_output(id: String, title: String, text: String) -> void:
	var p := _panel(id)
	if p.is_empty():
		_on_term_list([{"id": id, "title": title}])
		p = _panel(id)
	if p.is_empty():
		return
	p["title"].text = title
	p["label"].text = text


func _on_term_closed(id: String) -> void:
	var p := _panel(id)
	if not p.is_empty():
		p["root"].queue_free()
		panels.erase(p)
		_layout_panels()


func _on_screen_frame(image: Image) -> void:
	if screen_panel.is_empty():
		return
	if screen_texture.get_width() != image.get_width() or screen_texture.get_height() != image.get_height():
		screen_texture = ImageTexture.create_from_image(image)
		screen_panel["face_mat"].albedo_texture = screen_texture
		screen_panel["label"].text = ""
	else:
		screen_texture.update(image)
