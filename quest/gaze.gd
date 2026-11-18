extends StartXR
## Glance VR: control your Mac from a Meta Quest by looking at a window and pinching.
##
## Two ways to see the Mac:
##   1. Virtual screen (Quest Desk). Open the Glance app on the Mac; its main display streams here as a
##      floating panel. No calibration, no addresses to type: this app finds the Mac by itself
##      (USB cable via 127.0.0.1 after `adb reverse`, or Wi-Fi by broadcast discovery).
##   2. Real screen through passthrough (fallback when no stream connects). Pinch your right thumb and index finger at
##      the screen's top-left, top-right and bottom-left corners once, so the headset knows where the screen is.
##
## Either way, where you look (eyes on Quest Pro and Meta VR Glasses, head on Quest 3/3S) goes to Glance on the Mac as
## a point 0…1 on the screen, and the Mac pointer moves there, so Glance's glow marks the window you look at.
## Pinch your LEFT thumb and index finger and hold it to talk (the headset's talk key); let go and Glance acts on the
## window you are looking at, with Muse.
## Right pinch (palm away) and hold 2 s: bring the virtual screen in front of you (or calibrate the real screen again).
##
## On the Mac: just open the Glance app. Nothing to configure on either side.

## Optional manual override, only if auto-discovery cannot work on your network.
## Leave empty for normal use: the Mac is found by broadcast (see _poll_discovery).
@export var mac_address := ""
@export var mac_port := 47810            # gaze and talk over UDP (fallback mode only)
@export var hub_port := 47811            # Quest Desk WebSocket default; discovery reply carries the real port
@export var quest_token := ""            # only when the Mac was started with GLANCE_QUEST_TOKEN; empty = no token
@export var screen_width_m := 1.15
@export var screen_distance_m := 1.0

const CORNERS := ["top-left", "top-right", "bottom-left"]
const EYES := "/user/eyes_ext"
const RIGHT_HAND := "/user/hand_tracker/right"
const RIGHT_HAND_AIM := "/user/fbhandaim/right"   # Meta's own pinch detection (XR_FB_hand_tracking_aim)
const LEFT_HAND := "/user/hand_tracker/left"
const LEFT_HAND_AIM := "/user/fbhandaim/left"
const PINCH_ON := 0.025              # without Meta's: thumb and index tips closer than this (m) is a pinch
const PINCH_OFF := 0.04              # ... and it ends once they are this far apart again
const HOLD_TO_CALIBRATE_MS := 2000
const TALK_RELEASE_MS := 250         # the talk key ends only after the pinch has been open this long
const TALK_LOST_HOLD_MS := 1500      # ... and survives the left hand dropping out of tracking for this long
const DOT_IDLE := Color(0.49, 0.36, 1, 1)         # violet: where you point
const DOT_TALK := Color(0.2, 0.85, 0.45, 1)       # green: Glance is listening
const HUB_RETRY_MS := 2000
const HUB_CONNECT_TIMEOUT_MS := 4000
const LABEL_PIXEL_HEAD := 0.0006     # help text size when it floats in front of you
const LABEL_PIXEL_SCREEN := 0.0009   # ... and when it sits under the virtual screen, a little farther away
const HIGHLIGHT_HOLD_MS := 120       # gaze must rest on another panel this long before the highlight moves
const HIGHLIGHT_CLEAR_MS := 500      # ... and the highlight clears only after looking away this long
const GAZE_SEND_MS := 33             # gaze points go to the Mac at most this often (about 30 a second)
const PANEL_HEIGHT_M := 0.40
const PANEL_MAX_WIDTH_M := 0.62

const DISCOVERY_PORT := 47812        # Mac answers GLANCE_DISCOVER broadcasts here (QuestHub.startDiscovery)
const DISCOVERY_RETRY_MS := 2000

var corners: Array[Vector3] = []
var udp := PacketPeerUDP.new()
var udp_all := PacketPeerUDP.new()   # fallback mode: the same packets to the whole Wi-Fi, in case the address is wrong
var discover := PacketPeerUDP.new()
var discovered_host := ""            # Mac address learned from its discovery reply; "" until found
var discover_next_at := 0
var trigger_was_down := false
var pressed_at := -1                 # when the current right press began (ms), -1 otherwise
var pinching := false
var hand_status := ""                # what the headset sees of the right hand, shown while calibrating
var logged_at := 0
var sent := 0
var eyes_seen := false
var left_pinching := false
var left_tracked := false
var left_released_at := -1
var left_lost_at := -1
var talking := false

var hub := WebSocketPeer.new()
var hub_hosts: Array[String] = []
var hub_host_index := 0
var hub_open := false
var hub_error := ""
var hub_started_at := -1             # when the current connection attempt began (ms), -1 when idle
var hub_next_try_at := 0
var hub_closing_since := -1          # when the current connection started closing (ms), -1 otherwise
var frames := 0
var decode_ms := 0.0
var screen: MeshInstance3D
var screen_quad := QuadMesh.new()
var screen_material := StandardMaterial3D.new()
var screen_texture: ImageTexture
var screen_placed := false
var label_home: Transform3D

# Floating windows (protocol 2): one panel per Mac window, keyed by its CGWindowID.
var windows_mode := false
var panels := {}                     # window id (int) -> {root, quad, mat, tex, border, title, size}
var panel_order: Array[int] = []     # roster order: frontmost Mac window first
var panel_root: Node3D
var panels_placed := false
var highlighted_id := -1
var highlight_candidate := -1
var highlight_candidate_at := -1
var highlight_missed_at := -1
var last_gaze_sent_at := 0
var pending_panel_frames := {}       # window id -> latest undecoded JPEG (thumbnails wait their turn)
var registered_mode := false         # panels sit on the real laptop screen, at their windows' real bounds
var display_size := Vector2(1920, 1080)
# Right-pinch interaction on a panel: short = click, gaze move = drag in the window, hand move = grab the panel.
var right_press_panel := -1
var right_press_uv := Vector2.ZERO
var right_press_at := -1
var right_press_pinch := Vector3.ZERO
var right_press_has_pinch := false
var right_panel_start := Vector3.ZERO
var grabbing_panel := false
var dragging_window := false
var last_drag_uv := Vector2.ZERO
var last_drag_sent_at := 0
var resizing_panel := false          # both thumbs+indexes pinched: spread hands to zoom the looked-at panel
var resize_panel_id := -1
var resize_start_dist := 0.0
var resize_start_size := Vector2.ZERO

@onready var origin: XROrigin3D = $XROrigin3D
@onready var head: XRCamera3D = $XROrigin3D/XRCamera3D
@onready var hand: XRController3D = $XROrigin3D/RightController
@onready var tip: Node3D = $XROrigin3D/RightController/Tip
@onready var label: Label3D = $XROrigin3D/XRCamera3D/Help
@onready var dot: MeshInstance3D = $Dot


func _ready() -> void:
	super._ready()
	_make_hand_dots()
	if OS.get_name() == "Android":
		OS.request_permissions()          # eye tracking is asked for at runtime on Quest Pro
	if mac_address != "":
		udp.set_dest_address(mac_address, mac_port)
	udp_all.set_broadcast_enabled(true)
	udp_all.set_dest_address("255.255.255.255", mac_port)
	# Discovery socket: broadcast from this port so the Mac's reply comes back here.
	discover.set_broadcast_enabled(true)
	if discover.bind(DISCOVERY_PORT) != OK:
		print("Glance VR: could not bind discovery port; USB and manual address still work")
	discover.set_dest_address("255.255.255.255", DISCOVERY_PORT)

	screen_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	screen_quad.size = Vector2(screen_width_m, screen_width_m * 0.625)
	screen = MeshInstance3D.new()
	screen.mesh = screen_quad
	screen.material_override = screen_material
	screen.visible = false
	add_child(screen)
	panel_root = Node3D.new()
	panel_root.visible = false
	add_child(panel_root)
	# Candidates are rebuilt on every connect attempt: USB loopback first, then the Mac
	# found by discovery, then a manual mac_address override if one was set.
	_update_hub_hosts()

	label_home = label.transform
	pose_recentered.connect(_on_pose_recentered)
	focus_lost.connect(_on_focus_lost)
	dot.visible = false
	_show_step()


func _using_screen() -> bool:
	return screen != null and screen.visible


func _using_panels() -> bool:
	return windows_mode and panel_root != null and panel_root.visible and not panels.is_empty()


func _show_step() -> void:
	var text := ""
	if _using_panels():
		text = LEGEND
	elif _using_screen():
		text = "Look at a window. Pinch your LEFT thumb and finger, talk, and let go.\n(Right pinch, palm away, hold 2 s: bring the screen in front of you.)"
	elif hub_open:
		text = "Connected to your Mac. Waiting for its screen…"
	elif corners.size() == 0:
		text = "Looking for Glance on your Mac…\nOpen the Glance app on your Mac (same Wi-Fi, or plug in the USB cable). It will appear here by itself.\n(No Mac? Pinch your right thumb and finger at the top-left corner of your real Mac screen to use it through passthrough.)"
	elif corners.size() < CORNERS.size():
		text = "Pinch your right thumb and finger together at the %s corner of your Mac screen." % CORNERS[corners.size()]
	elif eyes_seen:
		text = "Look at a window on your Mac. Pinch your LEFT thumb and finger, talk, and let go.\n(Right pinch and hold 2 s: calibrate again.)"
	else:
		text = "Turn your head to put the dot on a window on your Mac. Pinch your LEFT thumb and finger, talk, and let go.\n(Right pinch and hold 2 s: calibrate again.)"
	if hub_error != "":
		text += "\nMac: " + hub_error
	label.text = text
	# In window mode the help is a small legend that fades after a few seconds; everything else stays readable.
	if _using_panels():
		if legend_shown_at < 0:
			legend_shown_at = Time.get_ticks_msec()
		if label.get_parent() == head:
			label.pixel_size = LEGEND_PIXEL
		label.visible = hub_error != "" or Time.get_ticks_msec() - legend_shown_at < LEGEND_MS
	else:
		if label.get_parent() == head:
			label.pixel_size = LABEL_PIXEL_HEAD
		label.visible = true


func _process(_delta: float) -> void:
	_poll_hub()
	if label.visible and _using_panels() and hub_error == "" and legend_shown_at >= 0 \
			and Time.get_ticks_msec() - legend_shown_at > LEGEND_MS:
		label.visible = false
	_update_hand_dots()

	var pinch_at: Variant = _pinch_point()
	var down := pinch_at != null or hand.is_button_pressed("trigger_click")
	if down and not trigger_was_down:
		if _using_panels():
			_begin_right_press(pinch_at)
		elif not _using_screen() and corners.size() < CORNERS.size():
			corners.append(pinch_at if pinch_at != null else tip.global_position)
			_show_step()
		else:
			pressed_at = Time.get_ticks_msec()
	if down and trigger_was_down and _using_panels():
		_track_right_press(pinch_at)
	if not down and trigger_was_down and _using_panels():
		_finish_right_press()
	if not down:
		pressed_at = -1
	elif pressed_at >= 0 and Time.get_ticks_msec() - pressed_at >= HOLD_TO_CALIBRATE_MS:
		pressed_at = -1
		if _using_panels():
			_toggle_layout()
		elif _using_screen():
			_place_screen()
		else:
			corners.clear()
			dot.visible = false
		_show_step()
	trigger_was_down = down

	if Time.get_ticks_msec() - logged_at >= 1000:
		logged_at = Time.get_ticks_msec()
		print("Glance VR: hub %s, screen %s, frames %d (decode %.1f ms), corners %d, talking %s, sent %d" % [hub_open, _using_screen(), frames, decode_ms, corners.size(), talking, sent])
	if not _using_panels() and not _using_screen() and corners.size() < CORNERS.size():
		_show_step()
		if corners.size() > 0:
			label.text += "\n" + hand_status
		return

	if windows_mode and not panels_placed and not panels.is_empty():
		_layout_current()     # roster may have landed before head tracking: keep trying to place the panels

	_decode_pending_panel_frame()

	if _using_panels():
		_update_phone_zoom(pinch_at)

	var talk_now := _talk_wanted()
	_check_double_pinch()
	_update_left_scroll()
	_update_point_scroll(_delta)
	if not TALK_ENABLED:
		talk_now = false     # voice (AI) is off for now: the left hand clicks, opens and scrolls instead
	if resizing_panel:
		talk_now = false     # both hands are busy sizing a panel; this is not a talk pinch
	if talk_now != talking:
		_set_talking(talk_now)
		var talk_message := {"talk": talking}
		if highlighted_id >= 0:
			talk_message["window"] = highlighted_id
		_send(talk_message)

	var found: Variant = _pointer()
	if found == null:
		return
	var gaze: Transform3D = found
	var start: Vector3 = gaze.origin
	var dir: Vector3 = -gaze.basis.z.normalized()

	if _using_panels():
		var hit: Variant = _current_panel_hit()
		_update_highlight(hit)
		if hit == null:
			dot.visible = false
			return
		var panel_point: Vector2 = hit[1]
		dot.visible = true
		dot.global_position = hit[2]
		if Time.get_ticks_msec() - last_gaze_sent_at >= GAZE_SEND_MS:
			last_gaze_sent_at = Time.get_ticks_msec()
			_send({"x": snappedf(panel_point.x, 0.0001), "y": snappedf(panel_point.y, 0.0001), "talk": talking, "window": int(hit[0])})
			sent += 1
		return

	var result: Variant = _hit_screen(start, dir) if _using_screen() else _hit_corners(start, dir)
	if result == null:
		dot.visible = false      # looking off the screen: no dot; the Mac pointer stays where it was
		return
	var point: Vector2 = result[0]
	dot.visible = true
	dot.global_position = result[1]
	if Time.get_ticks_msec() - last_gaze_sent_at >= GAZE_SEND_MS:
		last_gaze_sent_at = Time.get_ticks_msec()
		_send({"x": snappedf(point.x, 0.0001), "y": snappedf(point.y, 0.0001), "talk": talking})
		sent += 1


func _set_talking(on: bool) -> void:
	talking = on
	var dot_material := dot.get_surface_override_material(0) as StandardMaterial3D
	if dot_material != null:
		dot_material.albedo_color = DOT_TALK if on else DOT_IDLE
	if on:
		label.text = "Listening… say what to do, then let go of the pinch."
	else:
		_show_step()


## The talk key from the left pinch, steadied: it starts only on a tracked pinch, ends 250 ms after the pinch opens,
## and survives up to 1.5 s of the left hand dropping out of tracking mid-sentence.
func _talk_wanted() -> bool:
	var pinch := _left_pinch()
	var now := Time.get_ticks_msec()
	if not talking:
		left_released_at = -1
		left_lost_at = -1
		return pinch and left_tracked
	if not left_tracked:
		if left_lost_at < 0:
			left_lost_at = now
		return now - left_lost_at < TALK_LOST_HOLD_MS
	left_lost_at = -1
	if pinch:
		left_released_at = -1
		return true
	if left_released_at < 0:
		left_released_at = now
	return now - left_released_at < TALK_RELEASE_MS


## Where the gaze ray meets the real screen found by the three corner pinches: [point 0…1, hit in world], or null.
func _hit_corners(start: Vector3, dir: Vector3) -> Variant:
	var top_left := corners[0]
	var across := corners[1] - top_left
	var down_side := corners[2] - top_left
	var normal := across.cross(down_side).normalized()
	var facing := normal.dot(dir)
	if absf(facing) < 0.0001:
		return null
	var distance := normal.dot(top_left - start) / facing
	if distance <= 0.0:
		return null
	var hit := start + dir * distance
	var rel := hit - top_left
	return [Vector2(rel.dot(across) / across.length_squared(), rel.dot(down_side) / down_side.length_squared()), hit]


## Where the gaze ray meets the virtual screen panel: [point 0…1 from its top-left, hit in world], or null when it misses.
func _hit_screen(start: Vector3, dir: Vector3) -> Variant:
	var t := screen.global_transform
	var normal := t.basis.z.normalized()
	var facing := normal.dot(dir)
	if absf(facing) < 0.0001:
		return null
	var distance := normal.dot(t.origin - start) / facing
	if distance <= 0.0:
		return null
	var hit := start + dir * distance
	var local := t.affine_inverse() * hit
	var x := local.x / screen_quad.size.x + 0.5
	var y := 0.5 - local.y / screen_quad.size.y
	if x < -0.05 or x > 1.05 or y < -0.05 or y > 1.05:
		return null
	return [Vector2(x, y), hit + normal * 0.003]


# MARK: - Floating window panels

## Builds or updates one panel per roster window, and removes panels whose window closed.
func _apply_roster(windows: Array) -> void:
	var seen := {}
	panel_order.clear()
	for entry in windows:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var id := int(entry.get("id", -1))
		if id < 0:
			continue
		seen[id] = true
		panel_order.append(id)
		var aspect := clampf(float(entry.get("h", 1)) / maxf(1.0, float(entry.get("w", 1))), 0.3, 2.5)
		# Panel height is fixed; width follows the window's aspect, capped so wide windows stay reachable.
		var size := Vector2(minf(PANEL_MAX_WIDTH_M, PANEL_HEIGHT_M / aspect), PANEL_HEIGHT_M)
		if panels.has(id):
			var existing: Dictionary = panels[id]
			if not bool(existing.get("user_sized", false)):
				existing["arc_size"] = size     # a size the user set by hand is never overwritten by the roster
				if not registered_mode:
					existing["size"] = size
					(existing["quad"] as QuadMesh).size = size
					(existing["border_quad"] as QuadMesh).size = size + Vector2(0.024, 0.024)
			existing["bx"] = float(entry.get("bx", 0))
			existing["by"] = float(entry.get("by", 0))
			existing["bw"] = float(entry.get("bw", entry.get("w", 1)))
			existing["bh"] = float(entry.get("bh", entry.get("h", 1)))
			existing["title"].text = _panel_title(entry)
		else:
			panels[id] = _make_panel(id, entry, size)
	for id in panels.keys().duplicate():
		if not seen.has(id):
			(panels[id]["root"] as Node3D).queue_free()
			panels.erase(id)
			pending_panel_frames.erase(id)
			if highlighted_id == id:
				highlighted_id = -1
	_layout_current()
	panel_root.visible = not panels.is_empty()
	if not panels.is_empty():
		_show_screen(false)
		_dock_label(false)   # panels carry their own titles; the help text stays in front of you
	_show_step()


func _panel_title(entry: Dictionary) -> String:
	var app := str(entry.get("app", "Window"))
	var title := str(entry.get("title", ""))
	return app if title == "" or title == app else app + " — " + title


func _make_panel(id: int, entry: Dictionary, size: Vector2) -> Dictionary:
	var root := Node3D.new()
	root.name = "Window%d" % id
	var border_mat := StandardMaterial3D.new()
	border_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	border_mat.albedo_color = DOT_IDLE
	var border_quad := QuadMesh.new()
	border_quad.size = size + Vector2(0.024, 0.024)
	var border := MeshInstance3D.new()
	border.mesh = border_quad
	border.material_override = border_mat
	border.position.z = -0.002
	border.visible = false
	root.add_child(border)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var quad := QuadMesh.new()
	quad.size = size
	var mesh := MeshInstance3D.new()
	mesh.mesh = quad
	mesh.material_override = mat
	root.add_child(mesh)
	var title := Label3D.new()
	title.text = _panel_title(entry)
	title.pixel_size = 0.0011
	title.font_size = 40
	title.modulate = Color(0.96, 0.95, 1, 1)
	title.outline_size = 8
	title.no_depth_test = true
	title.visible = false
	title.position = Vector3(0, size.y / 2.0 + 0.035, 0.005)
	root.add_child(title)
	panel_root.add_child(root)
	return {"root": root, "quad": quad, "border_quad": border_quad, "mat": mat, "tex": null,
			"border": border, "title": title, "size": size, "arc_size": size,
			"bx": float(entry.get("bx", 0)), "by": float(entry.get("by", 0)),
			"bw": float(entry.get("bw", entry.get("w", 1))), "bh": float(entry.get("bh", entry.get("h", 1))),
			"user_placed": false, "user_sized": false, "placed_once": false}


## Lays panels out in a shallow arc in front of the user. Head-not-tracked safe, like _place_screen.
## Panels the user grabbed keep their place unless `force` is set (the 2 s hold gesture).
func _layout_panels(force: bool = false) -> void:
	if panels.is_empty():
		return
	var head_t := head.global_transform
	if not xr_is_focussed or head_t.origin.is_zero_approx():
		return
	var forward := -head_t.basis.z
	forward.y = 0.0
	if forward.length() < 0.01:
		forward = Vector3(0, 0, -1)
	forward = forward.normalized()
	var centre := head_t.origin + forward * (screen_distance_m + 0.25) + Vector3(0, -0.10, 0)
	var ids: Array = panel_order.filter(func(id: int) -> bool: return panels.has(id))
	if ids.is_empty():
		ids = panels.keys()
	var total := 0.0
	for id in ids:
		total += (panels[id]["arc_size"] as Vector2).x + 0.05
	var cursor_x := -total / 2.0
	var right := Vector3(-forward.z, 0, forward.x).normalized()
	for id in ids:
		var panel: Dictionary = panels[id]
		var size: Vector2 = panel["arc_size"]
		cursor_x += size.x / 2.0
		if force:
			panel["user_placed"] = false
			panel["placed_once"] = false
		# World-locked: a panel placed once (by layout or by hand) never recentres on your head again.
		# Only brand-new panels take a slot; the explicit reset gesture passes force.
		if not bool(panel["user_placed"]) and not bool(panel.get("placed_once", false)):
			panel["size"] = size
			(panel["quad"] as QuadMesh).size = size
			(panel["border_quad"] as QuadMesh).size = size + Vector2(0.024, 0.024)
			var root := panel["root"] as Node3D
			root.global_position = centre + right * cursor_x + forward * (-0.06 * absf(cursor_x))
			root.look_at(head_t.origin, Vector3.UP, true)
			(panel["title"] as Label3D).position = Vector3(0, size.y / 2.0 + 0.035, 0.005)
			panel["placed_once"] = true
		cursor_x += size.x / 2.0 + 0.05
	panels_placed = true
	panel_root.visible = true


## Registered mode: panels sit on the real laptop screen (from the 3-corner calibration), each at its Mac
## window's real bounds, lifted toward you by stacking order. Grabbed panels stay where they were put.
func _layout_registered(force: bool = false) -> void:
	if panels.is_empty() or corners.size() < CORNERS.size():
		return
	var top_left := corners[0]
	var across := corners[1] - top_left
	var down_side := corners[2] - top_left
	var plane_w := across.length()
	var plane_h := down_side.length()
	if plane_w < 0.05 or plane_h < 0.05:
		return
	var x_axis := across.normalized()
	var y_axis := (-down_side).normalized()
	var z_axis := x_axis.cross(y_axis).normalized()
	y_axis = z_axis.cross(x_axis).normalized()
	var head_t := head.global_transform
	if z_axis.dot(head_t.origin - top_left) < 0.0:
		z_axis = -z_axis
		y_axis = z_axis.cross(x_axis).normalized()
	var basis := Basis(x_axis, y_axis, z_axis)
	var ids: Array = panel_order.filter(func(id: int) -> bool: return panels.has(id))
	if ids.is_empty():
		ids = panels.keys()
	for index in ids.size():
		var panel: Dictionary = panels[ids[index]]
		if force:
			panel["user_placed"] = false
		if bool(panel["user_placed"]):
			continue
		var u0 := clampf(float(panel["bx"]) / maxf(1.0, display_size.x), 0.0, 1.0)
		var v0 := clampf(float(panel["by"]) / maxf(1.0, display_size.y), 0.0, 1.0)
		var uw := clampf(float(panel["bw"]) / maxf(1.0, display_size.x), 0.0, 1.0 - u0)
		var vh := clampf(float(panel["bh"]) / maxf(1.0, display_size.y), 0.0, 1.0 - v0)
		var size := Vector2(maxf(0.05, uw * plane_w), maxf(0.05, vh * plane_h))
		panel["size"] = size
		(panel["quad"] as QuadMesh).size = size
		(panel["border_quad"] as QuadMesh).size = size + Vector2(0.024, 0.024)
		(panel["title"] as Label3D).position = Vector3(0, size.y / 2.0 + 0.035, 0.005)
		var centre := top_left + across * (u0 + uw / 2.0) + down_side * (v0 + vh / 2.0)
		var lift := 0.006 + float(ids.size() - index) * 0.004
		(panel["root"] as Node3D).global_transform = Transform3D(basis, centre + z_axis * lift)
	panels_placed = true
	panel_root.visible = true


func _layout_current(force: bool = false) -> void:
	if registered_mode and corners.size() == CORNERS.size():
		_layout_registered(force)
	else:
		_layout_panels(force)


## Where a ray meets the nearest floating panel: [window id, point 0…1, hit in world], or null.
func _hit_panel(start: Vector3, dir: Vector3) -> Variant:
	var best: Variant = null
	var best_distance := INF
	for id in panels:
		var panel: Dictionary = panels[id]
		var root := panel["root"] as Node3D
		if not root.visible:
			continue
		var size: Vector2 = panel["size"]
		var t := root.global_transform
		var normal := t.basis.z.normalized()
		var facing := normal.dot(dir)
		if absf(facing) < 0.0001:
			continue
		var distance := normal.dot(t.origin - start) / facing
		if distance <= 0.0 or distance >= best_distance:
			continue
		var hit := start + dir * distance
		var local := t.affine_inverse() * hit
		var x := local.x / size.x + 0.5
		var y := 0.5 - local.y / size.y
		if x < -0.05 or x > 1.05 or y < -0.05 or y > 1.05:
			continue
		best_distance = distance
		best = [id, Vector2(clampf(x, 0.0, 1.0), clampf(y, 0.0, 1.0)), hit + normal * 0.003]
	return best


## Moves the highlight with a short hold, so eye jitter at a panel edge does not flicker it.
func _update_highlight(hit: Variant) -> void:
	var now := Time.get_ticks_msec()
	if hit == null:
		highlight_candidate = -1
		if highlighted_id >= 0:
			if highlight_missed_at < 0:
				highlight_missed_at = now
			elif now - highlight_missed_at >= HIGHLIGHT_CLEAR_MS:
				_set_highlighted(-1)
		return
	highlight_missed_at = -1
	var id := int(hit[0])
	if id == highlighted_id:
		highlight_candidate = -1
		return
	if highlight_candidate != id:
		highlight_candidate = id
		highlight_candidate_at = now
		return
	if now - highlight_candidate_at >= HIGHLIGHT_HOLD_MS:
		_set_highlighted(id)


func _set_highlighted(id: int) -> void:
	highlighted_id = id
	highlight_candidate = -1
	for pid in panels:
		var panel: Dictionary = panels[pid]
		var on: bool = int(pid) == id
		(panel["border"] as MeshInstance3D).visible = on
		(panel["title"] as Label3D).visible = on
		(panel["mat"] as StandardMaterial3D).albedo_color = Color(1, 1, 1, 1) if on or id < 0 else Color(0.82, 0.82, 0.88, 1)
	if hub_open and windows_mode:
		hub.send_text(JSON.stringify({"type": "highlight", "window": id}))


func _show_panel_frame(id: int, jpg: PackedByteArray) -> void:
	if not panels.has(id):
		return
	var started := Time.get_ticks_usec()
	var image := Image.new()
	if image.load_jpg_from_buffer(jpg) != OK:
		return
	frames += 1
	var panel: Dictionary = panels[id]
	if panel["tex"] == null or Vector2i((panel["tex"] as ImageTexture).get_size()) != image.get_size():
		panel["tex"] = ImageTexture.create_from_image(image)
		(panel["mat"] as StandardMaterial3D).albedo_texture = panel["tex"]
	else:
		(panel["tex"] as ImageTexture).update(image)
	decode_ms = (Time.get_ticks_usec() - started) / 1000.0


## Decodes at most one waiting frame per tick, the highlighted window first; newer frames replace waiting ones.
func _decode_pending_panel_frame() -> void:
	if pending_panel_frames.is_empty():
		return
	var id: int = highlighted_id if pending_panel_frames.has(highlighted_id) else int(pending_panel_frames.keys()[0])
	var jpg: PackedByteArray = pending_panel_frames[id]
	pending_panel_frames.erase(id)
	_show_panel_frame(id, jpg)


## A ray from the right hand (controller aim), for the hand-pointer fallback. Empty when the hand is not tracked.
func _hand_ray() -> Array:
	var t := hand.global_transform
	if t.origin.is_zero_approx():
		return []
	return [t.origin, -t.basis.z.normalized()]


## The point between the left thumb and index tips, in world space; null while the left hand is not tracked.
func _left_pinch_point() -> Variant:
	var joints := XRServer.get_tracker(LEFT_HAND) as XRHandTracker
	if joints == null or not joints.has_tracking_data:
		return null
	var thumb := joints.get_hand_joint_transform(XRHandTracker.HAND_JOINT_THUMB_TIP).origin
	var index := joints.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP).origin
	return origin.global_transform * ((thumb + index) / 2.0)


## Sets a panel's size everywhere it is remembered, so the roster cannot quietly undo it.
func _set_panel_size(panel: Dictionary, size: Vector2) -> void:
	panel["size"] = size
	panel["arc_size"] = size
	(panel["quad"] as QuadMesh).size = size
	(panel["border_quad"] as QuadMesh).size = size + Vector2(0.024, 0.024)
	(panel["title"] as Label3D).position = Vector3(0, size.y / 2.0 + 0.035, 0.005)


## Phone-style pinch zoom: pinch thumb+index on BOTH hands, spread them apart to zoom the looked-at
## window in, bring them together to zoom out. The distance between your two pinch points is the zoom.
func _update_phone_zoom(right_point: Variant) -> void:
	_left_pinch()     # refresh left Tracked/pinching for this frame
	if right_point == null or not pinching or not left_pinching or not left_tracked:
		resizing_panel = false
		resize_panel_id = -1
		return
	var left_point: Variant = _left_pinch_point()
	if left_point == null:
		resizing_panel = false
		resize_panel_id = -1
		return
	var spread := (right_point as Vector3).distance_to(left_point)
	if not resizing_panel:
		var hit: Variant = _current_panel_hit()
		var target := int(hit[0]) if hit != null else highlighted_id
		if target < 0 or not panels.has(target) or spread < 0.03:
			return
		resizing_panel = true
		resize_panel_id = target
		resize_start_dist = spread
		resize_start_size = panels[target]["size"]
		panels[target]["user_placed"] = true
		panels[target]["user_sized"] = true
		_set_highlighted(target)
		return
	if resize_start_dist <= 0.01 or not panels.has(resize_panel_id):
		return
	var factor := clampf(spread / resize_start_dist, 0.4, 2.5)
	var new_size := resize_start_size * factor
	new_size.y = clampf(new_size.y, 0.14, 0.95)
	new_size.x = new_size.y * (resize_start_size.x / maxf(0.01, resize_start_size.y))
	_set_panel_size(panels[resize_panel_id], new_size)


## The panel the user is pointing at now: gaze first, the right hand's aim when gaze rests between panels.
func _current_panel_hit() -> Variant:
	var found: Variant = _pointer()
	if found == null:
		return null
	var gaze: Transform3D = found
	var hit: Variant = _hit_panel(gaze.origin, -gaze.basis.z.normalized())
	if hit == null:
		var hand_ray := _hand_ray()
		if not hand_ray.is_empty():
			hit = _hit_panel(hand_ray[0], hand_ray[1])
	return hit


func _send_action(kind: String, window_id: int, uv: Vector2) -> void:
	if hub_open and windows_mode:
		hub.send_text(JSON.stringify({"type": kind, "window": window_id,
				"x": snappedf(uv.x, 0.0001), "y": snappedf(uv.y, 0.0001)}))


## Right pinch went down in panel mode. On a panel it may become a click, a drag, or a grab; off a panel a
## 2 s hold switches layout (handled by the generic hold path, which needs pressed_at).
func _begin_right_press(pinch_at: Variant) -> void:
	right_press_panel = -1
	grabbing_panel = false
	dragging_window = false
	right_press_at = Time.get_ticks_msec()
	right_press_has_pinch = true
	# The grab point is the pinch when there is one, and the controller tip on a trigger press.
	right_press_pinch = pinch_at if pinch_at != null else tip.global_position
	var hit: Variant = _current_panel_hit()
	if hit == null:
		pressed_at = right_press_at     # empty space: the hold-to-switch-layout gesture
		return
	pressed_at = -1                      # on a panel: never the layout gesture
	right_press_panel = int(hit[0])
	right_press_uv = hit[1]
	last_drag_uv = right_press_uv
	if panels.has(right_press_panel):
		right_panel_start = (panels[right_press_panel]["root"] as Node3D).global_position
	_set_highlighted(right_press_panel)


## While the right pinch is held: a big hand move grabs the panel; a gaze move across it drags inside the window.
func _track_right_press(pinch_at: Variant) -> void:
	if right_press_panel < 0 or not panels.has(right_press_panel):
		return
	var root := panels[right_press_panel]["root"] as Node3D
	var hand_point: Vector3 = pinch_at if pinch_at != null else tip.global_position
	if resizing_panel:
		return     # zoom is driven by _update_phone_zoom; the right hand is one of its two fingers
	if grabbing_panel:
		root.global_position = right_panel_start + (hand_point - right_press_pinch)
		var head_t := head.global_transform
		if not head_t.origin.is_zero_approx():
			root.look_at(head_t.origin, Vector3.UP, true)
		return
	if right_press_has_pinch and hand_point.distance_to(right_press_pinch) > 0.08:
		if dragging_window:
			dragging_window = false
			_send_action("drag_cancel", right_press_panel, last_drag_uv)
		grabbing_panel = true
		panels[right_press_panel]["user_placed"] = true   # ours from the grab start, so relayouts cannot steal it
		return
	var hit: Variant = _current_panel_hit()
	if hit == null or int(hit[0]) != right_press_panel:
		return
	var uv: Vector2 = hit[1]
	if not dragging_window and uv.distance_to(right_press_uv) > 0.03:
		dragging_window = true
		_send_action("drag_start", right_press_panel, right_press_uv)
	if dragging_window and Time.get_ticks_msec() - last_drag_sent_at >= GAZE_SEND_MS:
		last_drag_sent_at = Time.get_ticks_msec()
		last_drag_uv = uv
		_send_action("drag_move", right_press_panel, uv)


func _finish_right_press() -> void:
	if right_press_panel >= 0 and panels.has(right_press_panel):
		if grabbing_panel:
			var panel: Dictionary = panels[right_press_panel]
			panel["user_placed"] = true      # layout memory: roster rebuilds and relayouts keep it here
		elif dragging_window:
			_send_action("drag_end", right_press_panel, last_drag_uv)
		elif resizing_panel:
			pass     # it was a resize, not a click
		elif right_press_at >= 0 and Time.get_ticks_msec() - right_press_at < 400:
			_send_action("click", right_press_panel, right_press_uv)
	right_press_panel = -1
	right_press_at = -1
	grabbing_panel = false
	dragging_window = false
	resizing_panel = false
	resize_panel_id = -1


## 2 s right pinch on empty space: between the arc and (when calibrated) the real laptop screen.
func _toggle_layout() -> void:
	if registered_mode:
		registered_mode = false
		_layout_panels(true)
	elif corners.size() == CORNERS.size():
		registered_mode = true
		_layout_registered(true)
	else:
		_layout_panels(true)


## Puts the virtual screen in front of you, a little below eye height and tilted toward you. Returns false (and does
## nothing) while the head is not tracked yet, so the screen never lands on the floor.
func _place_screen() -> bool:
	var head_t := head.global_transform
	if not xr_is_focussed or head_t.origin.is_zero_approx():
		return false
	var forward := -head_t.basis.z
	forward.y = 0.0
	if forward.length() < 0.01:
		forward = Vector3(0, 0, -1)
	forward = forward.normalized()
	screen.global_position = head_t.origin + forward * screen_distance_m + Vector3(0, -0.12, 0)
	screen.look_at(head_t.origin, Vector3.UP, true)
	screen_placed = true
	return true


func _on_pose_recentered() -> void:
	if screen_placed:
		_place_screen()
	# Panels are not re-laid out here: they are world-locked and stay where they were put.


## The headset was taken off or the Meta menu opened: _process stops, so end the talk key and any drag now.
func _on_focus_lost() -> void:
	if dragging_window and right_press_panel >= 0:
		_send_action("drag_cancel", right_press_panel, last_drag_uv)
	dragging_window = false
	grabbing_panel = false
	resizing_panel = false
	right_press_panel = -1
	if talking:
		_set_talking(false)
		_send({"talk": false})
		if hub_open:
			hub.poll()     # push it out now: nothing polls the WebSocket while the app is paused


func _update_hub_hosts() -> void:
	hub_hosts = ["127.0.0.1"]   # USB cable, after `adb reverse tcp:47811 tcp:47811`
	if discovered_host != "" and discovered_host != "127.0.0.1":
		hub_hosts.append(discovered_host)
	if mac_address != "" and not hub_hosts.has(mac_address):
		hub_hosts.append(mac_address)


## Finds the Mac with no typing: broadcast GLANCE_DISCOVER, the Glance app replies
## {"type":"glance_mac","port":…} and we connect to whoever sent that reply.
func _poll_discovery() -> void:
	while discover.get_available_packet_count() > 0:
		var sender := discover.get_packet_ip()
		var message: Variant = JSON.parse_string(discover.get_packet().get_string_from_utf8())
		if typeof(message) == TYPE_DICTIONARY and message.get("type", "") == "glance_mac" and sender != "":
			if int(message.get("port", 0)) > 0:
				hub_port = int(message["port"])
			if sender != discovered_host:
				discovered_host = sender
				udp.set_dest_address(sender, mac_port)   # fallback gaze follows the found Mac too
				_update_hub_hosts()
				print("Glance VR: found Mac at ", sender)
	if hub_open or Time.get_ticks_msec() < discover_next_at:
		return
	discover_next_at = Time.get_ticks_msec() + DISCOVERY_RETRY_MS
	discover.put_packet("GLANCE_DISCOVER".to_utf8_buffer())


## Keeps one WebSocket to Glance's Quest Desk, trying USB (127.0.0.1) then the discovered Mac in turn.
func _poll_hub() -> void:
	_poll_discovery()
	var now := Time.get_ticks_msec()
	var state := hub.get_ready_state()
	if state == WebSocketPeer.STATE_CLOSING:
		if hub_closing_since < 0:
			hub_closing_since = now
	else:
		hub_closing_since = -1
	var stuck_connecting := state == WebSocketPeer.STATE_CONNECTING and hub_started_at >= 0 and now - hub_started_at > HUB_CONNECT_TIMEOUT_MS
	var stuck_closing := hub_closing_since >= 0 and now - hub_closing_since > HUB_CONNECT_TIMEOUT_MS
	if state == WebSocketPeer.STATE_CLOSED or stuck_connecting or stuck_closing:
		if hub_open:
			hub_open = false
			print("Glance VR: screen stream closed")
			if talking:
				_set_talking(false)
			windows_mode = false
			panels_placed = false     # next connection re-decides arc vs registered from that session's calibration
			panel_root.visible = false
			_show_screen(false)
		if now < hub_next_try_at:
			return
		hub_next_try_at = now + HUB_RETRY_MS
		if hub.get_ready_state() != WebSocketPeer.STATE_CLOSED:
			hub.close()
		hub_closing_since = -1
		_update_hub_hosts()
		var host := hub_hosts[hub_host_index % hub_hosts.size()]
		hub_host_index += 1
		hub = WebSocketPeer.new()
		hub.inbound_buffer_size = 8 * 1024 * 1024
		hub_started_at = now
		if hub.connect_to_url("ws://%s:%d" % [host, hub_port]) != OK:
			hub_started_at = -1
		return
	hub.poll()
	if hub.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	if not hub_open:
		hub_open = true
		hub_started_at = -1
		print("Glance VR: hub stream connected")
		var hello := {"type": "hello", "app": "glance-vr", "proto": 2}
		if quest_token != "":
			hello["token"] = quest_token
		hub.send_text(JSON.stringify(hello))
		# screen_want or windows_want is sent when the Mac's hello reply says whether floating windows are on.
		_show_step()
	var frame := PackedByteArray()
	while hub.get_available_packet_count() > 0:
		var packet := hub.get_packet()
		if hub.was_string_packet():
			_hub_text(packet.get_string_from_utf8())
		elif packet.size() > 5 and packet[0] == 0x57:   # "W": one floating-window frame, next 4 bytes are its id
			var window_id := (int(packet[1]) << 24) | (int(packet[2]) << 16) | (int(packet[3]) << 8) | int(packet[4])
			pending_panel_frames[window_id] = packet.slice(5)   # latest only, highlighted included: no decode backlog
		elif packet.size() > 1 and packet[0] == 0x53:   # "S": one JPEG frame of the Mac screen
			frame = packet
	if frame.size() > 1 and not windows_mode:
		_show_frame(frame.slice(1))


func _hub_text(text: String) -> void:
	var message: Variant = JSON.parse_string(text)
	if typeof(message) != TYPE_DICTIONARY:
		return
	if message.get("type", "") == "hello":
		if bool(message.get("windows", false)):
			windows_mode = true
			hub_error = ""
			hub.send_text(JSON.stringify({"type": "windows_want", "on": true}))
			print("Glance VR: floating windows on")
		else:
			windows_mode = false
			hub.send_text(JSON.stringify({"type": "screen_want", "on": true}))
		_show_step()
		return
	if message.get("type", "") == "windows":
		if windows_mode:
			var disp: Dictionary = message.get("display", {})
			if float(disp.get("w", 0)) > 0 and float(disp.get("h", 0)) > 0:
				display_size = Vector2(float(disp["w"]), float(disp["h"]))
			if corners.size() == CORNERS.size() and not panels_placed:
				registered_mode = true     # calibrated before connecting: start on the real screen
			_apply_roster(message.get("windows", []))
		return
	if message.get("type", "") == "error":
		hub_error = str(message.get("text", ""))
		print("Glance VR: Mac says: ", hub_error)
		if not talking:
			_show_step()


func _show_frame(jpg: PackedByteArray) -> void:
	var started := Time.get_ticks_usec()
	var image := Image.new()
	if image.load_jpg_from_buffer(jpg) != OK:
		return
	frames += 1
	if screen_texture == null or Vector2i(screen_texture.get_size()) != image.get_size():
		screen_texture = ImageTexture.create_from_image(image)
		screen_material.albedo_texture = screen_texture
		screen_quad.size = Vector2(screen_width_m, screen_width_m * float(image.get_height()) / float(image.get_width()))
		_dock_label(_using_screen())
	else:
		screen_texture.update(image)
	decode_ms = (Time.get_ticks_usec() - started) / 1000.0
	if not screen_placed and not _place_screen():
		return      # the head is not tracked yet: show the screen on a later frame
	if not screen.visible:
		hub_error = ""
		_show_screen(true)


func _show_screen(on: bool) -> void:
	screen.visible = on
	dot.visible = false
	_dock_label(on)
	_show_step()


## The help text sits under the virtual screen while it shows (so it never covers the Mac), and floats in front of
## you otherwise.
func _dock_label(on_screen: bool) -> void:
	if on_screen:
		if label.get_parent() != screen:
			label.reparent(screen, false)
		label.pixel_size = LABEL_PIXEL_SCREEN
		label.transform = Transform3D(Basis(), Vector3(0, -screen_quad.size.y / 2.0 - 0.08, 0.01))
	elif label.get_parent() != head:
		label.reparent(head, false)
		label.pixel_size = LABEL_PIXEL_HEAD
		label.transform = label_home


## One message to the Mac: over the Quest Desk WebSocket when it is open (USB cable), otherwise as UDP to its address
## and to the whole Wi-Fi in case that address is wrong. Every gaze message repeats "talk", so a lost one can't leave
## the talk key stuck down.
func _send(message: Dictionary) -> void:
	if hub_open:
		var over_hub := message.duplicate()
		over_hub["type"] = "gaze"
		hub.send_text(JSON.stringify(over_hub))
		return
	var bytes := JSON.stringify(message).to_utf8_buffer()
	udp.put_packet(bytes)
	udp_all.put_packet(bytes)


## The point between the right thumb and index tips while they pinch, in world space; null otherwise.
## Meta's own pinch detection decides when it is a pinch if the headset offers it, the fingertip gap otherwise.
func _pinch_point() -> Variant:
	var joints := XRServer.get_tracker(RIGHT_HAND) as XRHandTracker
	var aim := XRServer.get_tracker(RIGHT_HAND_AIM) as XRPositionalTracker
	var tips_seen := joints != null and joints.has_tracking_data
	var thumb := Vector3.ZERO
	var index := Vector3.ZERO
	if tips_seen:
		thumb = joints.get_hand_joint_transform(XRHandTracker.HAND_JOINT_THUMB_TIP).origin
		index = joints.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP).origin
	var meta_pinch: Variant = aim.get_input("index_pinch") if aim != null else null
	if meta_pinch != null:
		pinching = bool(meta_pinch)
	elif tips_seen:
		pinching = thumb.distance_to(index) < (PINCH_OFF if pinching else PINCH_ON)
	else:
		pinching = false

	if not tips_seen:
		hand_status = "(Right hand not seen: hold it up where the headset can see it.)"
	else:
		hand_status = "(Right hand seen, fingertips %.1f cm apart%s.)" % [thumb.distance_to(index) * 100.0, ": pinch!" if pinching else ""]
	if not pinching or not tips_seen:
		return null
	return origin.global_transform * ((thumb + index) / 2.0)


## True while the left thumb and index finger pinch (Meta's pinch detection when offered, the fingertip gap otherwise).
## Also notes whether the left hand is tracked at all (left_tracked).
func _left_pinch() -> bool:
	var joints := XRServer.get_tracker(LEFT_HAND) as XRHandTracker
	var aim := XRServer.get_tracker(LEFT_HAND_AIM) as XRPositionalTracker
	left_tracked = joints != null and joints.has_tracking_data
	var meta_pinch: Variant = aim.get_input("index_pinch") if aim != null else null
	if meta_pinch != null:
		left_pinching = bool(meta_pinch)
	elif left_tracked:
		var thumb := joints.get_hand_joint_transform(XRHandTracker.HAND_JOINT_THUMB_TIP).origin
		var index := joints.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP).origin
		left_pinching = thumb.distance_to(index) < (PINCH_OFF if left_pinching else PINCH_ON)
	else:
		left_pinching = false
	return left_pinching


## Where you point, in world space: the eyes once the headset has tracked them, otherwise the head.
## Null while the eyes have no data after being seen (a blink), so the pointer stays put instead of jumping to the head.
func _pointer() -> Variant:
	var tracker := XRServer.get_tracker(EYES) as XRPositionalTracker
	if tracker != null:
		for pose_name in ["default", "default_pose"]:
			var pose := tracker.get_pose(pose_name)
			if pose != null and pose.has_tracking_data:
				if not eyes_seen:
					eyes_seen = true
					_show_step()
				return origin.global_transform * pose.get_adjusted_transform()
	if eyes_seen:
		return null
	return head.global_transform



# --- Hand highlight -------------------------------------------------------------------------------------------------
# Small glowing dots on every tracked hand joint, bigger on the thumb and index tips that do the pinching, so you
# always see what the headset sees of your hands (also in recordings, where passthrough can show black).
# Left hand turns green while it holds the talk key.
const HAND_DOT_COLOR := Color(0.62, 0.55, 1.0, 0.85)
const HAND_DOT_TALK := Color(0.2, 0.85, 0.45, 0.95)
var hand_dots := {}                  # tracker path -> Array of MeshInstance3D, one per joint
var hand_dot_materials := {}         # tracker path -> StandardMaterial3D


func _make_hand_dots() -> void:
	var mesh := SphereMesh.new()
	mesh.radius = 0.005
	mesh.height = 0.01
	mesh.radial_segments = 8
	mesh.rings = 4
	for path in [LEFT_HAND, RIGHT_HAND]:
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color = HAND_DOT_COLOR
		hand_dot_materials[path] = material
		var dots: Array = []
		for joint in XRHandTracker.HAND_JOINT_MAX:
			var dot_node := MeshInstance3D.new()
			dot_node.mesh = mesh
			dot_node.material_override = material
			dot_node.visible = false
			if joint == XRHandTracker.HAND_JOINT_THUMB_TIP or joint == XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP:
				dot_node.scale = Vector3.ONE * 2.0
			add_child(dot_node)
			dots.append(dot_node)
		hand_dots[path] = dots


func _update_hand_dots() -> void:
	for path in hand_dots:
		var joints := XRServer.get_tracker(path) as XRHandTracker
		var seen := joints != null and joints.has_tracking_data
		var material: StandardMaterial3D = hand_dot_materials[path]
		var on_page: bool = point_active and point_touching and path == point_path
		material.albedo_color = HAND_DOT_TALK if ((path == LEFT_HAND and talking) or on_page) else HAND_DOT_COLOR
		var dots: Array = hand_dots[path]
		for joint in dots.size():
			var dot_node: MeshInstance3D = dots[joint]
			dot_node.visible = seen
			if seen:
				dot_node.global_position = origin.global_transform * joints.get_hand_joint_transform(joint).origin


# --- Left hand: click, open, scroll -------------------------------------------------------------------------------
# Short left pinch (under 0.3 s) = click where you look. Two quick ones (at most 0.45 s apart) = double-click, to open
# a file. A single click waits out that gap, so a double never also clicks. Long pinch (0.25 s+) and move your hand
# up or down = scroll the window you look at, like dragging a page with your finger.
const TALK_ENABLED := false          # true: a long left pinch is the voice (AI) talk key again, and scroll is off
const DOUBLE_TAP_MAX_PRESS_MS := 300
const DOUBLE_TAP_GAP_MS := 450
const SCROLL_START_MS := 250
const SCROLL_PIXELS_PER_M := 3000.0  # 1 cm of hand travel scrolls 30 px
var left_raw_was := false
var left_raw_down_at := -1
var pending_click_at := -1           # when a single short tap ended and may still become a double (ms)
var pending_click_hit: Variant = null
var scroll_active := false
var scroll_panel := -1
var scroll_uv := Vector2.ZERO
var scroll_last_y := 0.0
var scroll_accum := 0.0


func _check_double_pinch() -> void:
	var now := Time.get_ticks_msec()
	var down := left_pinching and left_tracked and not resizing_panel and not TALK_ENABLED
	if down and not left_raw_was:
		left_raw_down_at = now
	elif not down and left_raw_was:
		var short := left_raw_down_at >= 0 and now - left_raw_down_at <= DOUBLE_TAP_MAX_PRESS_MS
		if short and pending_click_at >= 0 and left_raw_down_at - pending_click_at <= DOUBLE_TAP_GAP_MS:
			var hit: Variant = pending_click_hit
			pending_click_at = -1
			pending_click_hit = null
			_left_action("double_click", hit)
		elif short:
			_flush_pending_click()
			pending_click_at = now
			pending_click_hit = _current_panel_hit()
	left_raw_was = down
	if pending_click_at >= 0 and not down and now - pending_click_at > DOUBLE_TAP_GAP_MS:
		_flush_pending_click()


func _flush_pending_click() -> void:
	if pending_click_at >= 0:
		var hit: Variant = pending_click_hit
		pending_click_at = -1
		pending_click_hit = null
		_left_action("click", hit)


func _left_action(kind: String, hit: Variant) -> void:
	if hit == null or not _using_panels():
		return
	print("Glance VR: left %s on window %d" % [kind, hit[0]])
	_send_action(kind, hit[0], hit[1])


func _update_left_scroll() -> void:
	var down := left_pinching and left_tracked and not resizing_panel and not TALK_ENABLED
	if not down:
		scroll_active = false
		scroll_panel = -1
		return
	var point: Variant = _left_pinch_point()
	if point == null:
		return
	var y: float = (point as Vector3).y
	if not scroll_active:
		if left_raw_down_at < 0 or Time.get_ticks_msec() - left_raw_down_at < SCROLL_START_MS:
			return
		var hit: Variant = _current_panel_hit()
		if hit == null or not _using_panels():
			return
		_flush_pending_click()
		print("Glance VR: long-pinch scroll on window %d" % hit[0])
		scroll_active = true
		scroll_panel = hit[0]
		scroll_uv = hit[1]
		scroll_last_y = y
		scroll_accum = 0.0
		return
	scroll_accum += (y - scroll_last_y) * SCROLL_PIXELS_PER_M
	scroll_last_y = y
	if absf(scroll_accum) >= 3.0 and hub_open and windows_mode:
		var pixels := int(scroll_accum)
		scroll_accum -= pixels
		hub.send_text(JSON.stringify({"type": "scroll", "window": scroll_panel,
				"x": snappedf(scroll_uv.x, 0.0001), "y": snappedf(scroll_uv.y, 0.0001), "dy": pixels}))


# --- Gesture legend ----------------------------------------------------------------------------------------------------
# In window mode the help is this small legend, shown for 12 s, then hidden so nothing covers your windows.
const LEGEND := "LOOK = select      L tap = click      L tap x2 = open      POINT + swipe = scroll (open hand to switch direction)\nR hold + move = move window      L + R pinch, spread / close = zoom in / out      R hold 2 s on empty space = recenter"
const LEGEND_PIXEL := 0.00032
const LEGEND_MS := 12000
var legend_shown_at := -1


# --- Point to scroll, flick to fling ----------------------------------------------------------------------------------
# Make a fist with only the index finger out (either hand) while you look at a window, then swipe up or down, like on
# a phone. The first swipe sets the direction. Moving back the other way is the return, as if the finger were lifted
# off the glass: it never scrolls, so you can swipe again and again. A fast swipe keeps the page going (a fling).
# To scroll the other way, stop pointing for a moment (open your hand) and point again. The pointing hand's dots turn
# green while the finger is "on the page".
const POINT_INDEX_OUT := 0.075       # index tip at least this far from the palm (m): straight
const POINT_FINGER_IN := 0.065       # middle, ring and little tips nearer than this: curled
const POINT_SETTLE_MS := 150         # ignore movement this long after the pose starts (the hand is still being raised)
const POINT_START_PX := 45.0         # first swipe: 1.5 cm one way sets the direction
const POINT_LIFT_PX := 30.0          # 1 cm back from the farthest point = finger lifted (return, no scroll)
const POINT_TOUCH_PX := 30.0         # 1 cm forward again after a return = finger back on the page
const FLING_DECAY := 0.93            # speed kept per frame (at 72 Hz) while a fling coasts
const FLING_MIN_SPEED := 150.0       # px/s: slower than this, a lifted finger just stops
const FLING_PAUSE_MS := 200          # a swipe that stopped longer than this before the lift doesn't fling
var point_active := false
var point_path := ""                 # tracker path of the pointing hand
var point_started_at := 0
var point_panel := -1
var point_uv := Vector2.ZERO
var point_ref_y := 0.0               # where the finger settled when the point started
var point_dir := 0                   # +1 / -1: the swipe direction, set by the first swipe. 0 = not set yet
var point_touching := false          # true: finger "on the page", moves scroll. false: returning, moves are ignored
var point_peak := 0.0                # farthest position reached along the swipe direction (px) while touching
var point_peak_at := 0
var point_valley := 0.0              # farthest position back (px) while returning
var point_accum := 0.0
var point_speed := 0.0               # px/s, smoothed over forward moves, carried into the fling
var fling_panel := -1
var fling_uv := Vector2.ZERO

## World position of the index tip while that hand makes the point pose (index out, other fingers curled), else null.
func _point_tip(path: String) -> Variant:
	var joints := XRServer.get_tracker(path) as XRHandTracker
	if joints == null or not joints.has_tracking_data:
		return null
	var palm := joints.get_hand_joint_transform(XRHandTracker.HAND_JOINT_PALM).origin
	var index_tip := joints.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP).origin
	var thumb_tip := joints.get_hand_joint_transform(XRHandTracker.HAND_JOINT_THUMB_TIP).origin
	if index_tip.distance_to(palm) < POINT_INDEX_OUT or thumb_tip.distance_to(index_tip) < PINCH_OFF:
		return null
	for tip in [XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP, XRHandTracker.HAND_JOINT_RING_FINGER_TIP, XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP]:
		if joints.get_hand_joint_transform(tip).origin.distance_to(palm) > POINT_FINGER_IN:
			return null
	return origin.global_transform * index_tip


func _update_point_scroll(delta: float) -> void:
	var path: String = LEFT_HAND
	var tip: Variant = _point_tip(LEFT_HAND)
	if tip == null:
		path = RIGHT_HAND
		tip = _point_tip(RIGHT_HAND)
	if tip == null or resizing_panel:
		if point_active:
			point_active = false
			if point_touching:
				_start_fling()
			point_touching = false
		_update_fling(delta)
		return
	var y: float = (tip as Vector3).y
	if not point_active:
		var hit: Variant = _current_panel_hit()
		if hit == null or not _using_panels():
			_update_fling(delta)
			return
		print("Glance VR: point scroll on window %d" % hit[0])
		point_active = true
		point_path = path
		point_started_at = Time.get_ticks_msec()
		point_panel = hit[0]
		point_uv = hit[1]
		point_ref_y = y
		point_dir = 0
		point_touching = false
		point_accum = 0.0
		point_speed = 0.0
		fling_panel = -1
		return
	var now := Time.get_ticks_msec()
	if now - point_started_at < POINT_SETTLE_MS:
		point_ref_y = y      # the hand is still being raised: measure from where it settles
		return
	if point_dir == 0:
		# First swipe: whichever way the finger goes 1.5 cm first. Those 1.5 cm scroll too, so it doesn't feel late.
		var travel := (y - point_ref_y) * SCROLL_PIXELS_PER_M
		if absf(travel) >= POINT_START_PX:
			point_dir = 1 if travel > 0.0 else -1
			point_touching = true
			point_peak = travel * point_dir
			point_peak_at = now
			point_accum += travel
			_flush_scroll(point_panel, point_uv)
		return
	# Finger position along the swipe direction, in px from where the point started.
	var pos := (y - point_ref_y) * SCROLL_PIXELS_PER_M * point_dir
	if point_touching:
		if pos > point_peak:
			# Scroll only past the farthest point reached, so hand shake never adds up to a scroll.
			var advance := pos - point_peak
			point_peak = pos
			point_peak_at = now
			point_accum += advance * point_dir
			if delta > 0.0:
				point_speed = lerpf(point_speed, advance * point_dir / delta, 0.3)
			_flush_scroll(point_panel, point_uv)
		elif point_peak - pos >= POINT_LIFT_PX:
			point_touching = false     # 1 cm back: the finger is lifted for the return
			point_valley = pos
			_start_fling()
		return
	# Returning (finger lifted): a running fling coasts on. 1 cm forward again puts the finger back on the page,
	# and it catches the fling, like touching a moving list on a phone.
	_update_fling(delta)
	point_valley = minf(point_valley, pos)
	if pos - point_valley >= POINT_TOUCH_PX:
		point_touching = true
		point_peak = pos
		point_peak_at = now
		point_speed = 0.0
		fling_panel = -1


## The finger left the page: keep the page moving if the swipe was fast enough.
func _start_fling() -> void:
	if absf(point_speed) > FLING_MIN_SPEED and Time.get_ticks_msec() - point_peak_at <= FLING_PAUSE_MS:
		fling_panel = point_panel
		fling_uv = point_uv
	else:
		point_speed = 0.0


func _update_fling(delta: float) -> void:
	if fling_panel < 0:
		return
	point_speed *= pow(FLING_DECAY, delta * 72.0)
	if absf(point_speed) < FLING_MIN_SPEED * 0.5:
		fling_panel = -1
		point_speed = 0.0
		return
	point_accum += point_speed * delta
	_flush_scroll(fling_panel, fling_uv)


func _flush_scroll(window_id: int, uv: Vector2) -> void:
	if absf(point_accum) < 3.0 or not hub_open or not windows_mode:
		return
	var pixels := int(point_accum)
	point_accum -= pixels
	hub.send_text(JSON.stringify({"type": "scroll", "window": window_id,
			"x": snappedf(uv.x, 0.0001), "y": snappedf(uv.y, 0.0001), "dy": pixels}))

