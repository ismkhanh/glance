extends StartXR
## Glance Gaze for Quest Pro: your eyes point at your Mac's screen, seen through passthrough, and the point you
## look at goes to Glance on the Mac over Wi-Fi, where it moves the pointer. Everything that follows the pointer
## (the glow, "this", the talk key) then follows your eyes.
##
## Calibrate once: touch the right controller's tip to the screen's top-left, top-right and bottom-left corners and
## pull the trigger at each. That puts the screen in the room; then the gaze ray meets that plane 60 times a second.
## Pull the trigger again any time to calibrate again.
##
## On the Mac:  swift run -c release Glance --gaze 47810

@export var mac_address := "192.168.1.50"
@export var mac_port := 47810

const CORNERS := ["top-left", "top-right", "bottom-left"]
const EYES := "/user/eyes_ext"

var corners: Array[Vector3] = []
var udp := PacketPeerUDP.new()
var trigger_was_down := false
var sent := 0

@onready var origin: XROrigin3D = $XROrigin3D
@onready var hand: XRController3D = $XROrigin3D/RightController
@onready var tip: Node3D = $XROrigin3D/RightController/Tip
@onready var label: Label3D = $XROrigin3D/XRCamera3D/Help
@onready var dot: MeshInstance3D = $Dot


func _ready() -> void:
	super._ready()
	if OS.get_name() == "Android":
		OS.request_permissions()          # eye tracking is asked for at runtime on Quest Pro
	udp.set_dest_address(mac_address, mac_port)
	dot.visible = false
	_show_step()


func _show_step() -> void:
	if corners.size() < CORNERS.size():
		label.text = "Touch the controller tip to the %s corner of your Mac screen, then pull the trigger." % CORNERS[corners.size()]
	else:
		label.text = "Look at a window on your Mac, hold Option and talk.\n(Trigger: calibrate again.)"


func _process(_delta: float) -> void:
	var down := hand.is_button_pressed("trigger_click")
	if down and not trigger_was_down:
		if corners.size() >= CORNERS.size():
			corners.clear()
		else:
			corners.append(tip.global_position)
		_show_step()
	trigger_was_down = down
	if corners.size() < CORNERS.size():
		return

	var found: Variant = _gaze()
	if found == null:
		label.text = "No eye tracking: turn it on in Settings > Movement tracking > Eye tracking."
		return
	var gaze: Transform3D = found
	var top_left := corners[0]
	var across := corners[1] - top_left
	var down_side := corners[2] - top_left
	var normal := across.cross(down_side).normalized()
	var start: Vector3 = gaze.origin
	var dir: Vector3 = -gaze.basis.z.normalized()
	var facing := normal.dot(dir)
	if absf(facing) < 0.0001:
		return
	var distance := normal.dot(top_left - start) / facing
	if distance <= 0.0:
		return
	var hit := start + dir * distance
	var rel := hit - top_left
	var x := rel.dot(across) / across.length_squared()
	var y := rel.dot(down_side) / down_side.length_squared()
	dot.visible = true
	dot.global_position = hit
	udp.put_packet(JSON.stringify({"x": snappedf(x, 0.0001), "y": snappedf(y, 0.0001)}).to_utf8_buffer())
	sent += 1


## Where the eyes look, in world space (null without eye tracking data).
func _gaze() -> Variant:
	var tracker := XRServer.get_tracker(EYES) as XRPositionalTracker
	if tracker == null:
		return null
	for pose_name in ["default", "default_pose"]:
		var pose := tracker.get_pose(pose_name)
		if pose != null and pose.has_tracking_data:
			return origin.global_transform * pose.get_adjusted_transform()
	return null
