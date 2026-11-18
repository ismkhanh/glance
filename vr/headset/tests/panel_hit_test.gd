extends SceneTree
## Headless checks for floating-panel hit testing and highlight hold:
##   Godot --headless --path headset -s res://tests/panel_hit_test.gd
## Exits 0 on pass, 1 on failure. No XR needed: panels are placed by hand.

var failures := 0


func _init() -> void:
	call_deferred("_run")


func _check(name: String, ok: bool) -> void:
	if ok:
		print("PASS ", name)
	else:
		failures += 1
		printerr("FAIL ", name)


func _run() -> void:
	var script: GDScript = load("res://gaze.gd")
	var g = script.new()
	var container := Node3D.new()
	root.add_child(container)
	g.panel_root = container

	var panel: Dictionary = g._make_panel(42, {"app": "Test", "title": "", "w": 800, "h": 640}, Vector2(0.5, 0.4))
	var panel_root_node := panel["root"] as Node3D
	panel_root_node.global_position = Vector3(0, 0, -1)
	panel_root_node.look_at(Vector3.ZERO, Vector3.UP, true)
	g.panels[42] = panel

	var centre: Variant = g._hit_panel(Vector3.ZERO, Vector3(0, 0, -1))
	_check("centre hit finds window 42", centre != null and int(centre[0]) == 42)
	if centre != null:
		var p: Vector2 = centre[1]
		_check("centre hit is panel middle", absf(p.x - 0.5) < 0.06 and absf(p.y - 0.5) < 0.06)

	var right: Variant = g._hit_panel(Vector3.ZERO, Vector3(0.2, 0, -1).normalized())
	_check("right hit lands right of middle", right != null and (right[1] as Vector2).x > 0.6)

	var miss: Variant = g._hit_panel(Vector3.ZERO, Vector3(0, 1, -0.2).normalized())
	_check("upward ray misses", miss == null)

	# Highlight must wait out the hold before moving, then apply.
	g._update_highlight(centre)
	_check("highlight waits for hold", g.highlighted_id == -1)
	OS.delay_msec(150)
	g._update_highlight(centre)
	_check("highlight applies after hold", g.highlighted_id == 42)
	_check("border shows on highlight", (panel["border"] as MeshInstance3D).visible)

	# Looking away does not clear it at once.
	g._update_highlight(null)
	_check("highlight survives a glance away", g.highlighted_id == 42)

	# Registered mode: a full-display window lands centred on the calibrated real screen, lifted toward you.
	var cam := XRCamera3D.new()
	root.add_child(cam)
	g.head = cam
	g.xr_is_focussed = true
	g.display_size = Vector2(1920, 1080)
	g.corners = [Vector3(-0.5, 0.3, -1), Vector3(0.5, 0.3, -1), Vector3(-0.5, -0.3, -1)]
	panel["bx"] = 0.0
	panel["by"] = 0.0
	panel["bw"] = 1920.0
	panel["bh"] = 1080.0
	g.panel_order = [42]
	g._layout_registered()
	var placed := (panel["root"] as Node3D).global_position
	_check("registered centre on real screen", absf(placed.x) < 0.02 and absf(placed.y) < 0.02 and placed.z > -1.0 and placed.z < -0.97)

	# Layout memory: a grabbed (user-placed) panel is not moved by relayouts.
	panel["user_placed"] = true
	(panel["root"] as Node3D).global_position = Vector3(3, 2, -4)
	g._layout_registered()
	g._layout_panels()
	_check("user-placed panel keeps its place", ((panel["root"] as Node3D).global_position - Vector3(3, 2, -4)).length() < 0.001)

	# World lock: even a layout-placed panel never recentres on the head again.
	panel["user_placed"] = false
	panel["placed_once"] = true
	(panel["root"] as Node3D).global_position = Vector3(-2, 1, -3)
	g._layout_panels()
	_check("placed panel does not recentre", ((panel["root"] as Node3D).global_position - Vector3(-2, 1, -3)).length() < 0.001)

	# Resize writes the size everywhere the roster could restore it from.
	g._set_panel_size(panel, Vector2(0.9, 0.72))
	_check("resized size sticks", (panel["arc_size"] as Vector2) == Vector2(0.9, 0.72)
			and ((panel["quad"] as QuadMesh).size == Vector2(0.9, 0.72)))

	print("RESULT failures=%d" % failures)
	quit(1 if failures > 0 else 0)
