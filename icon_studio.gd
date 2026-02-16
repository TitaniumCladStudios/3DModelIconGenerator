extends Node3D
## Icon Studio - 3D Asset to Transparent PNG Icon Generator
##
## Usage: Place 3D objects as children of the ObjectPivot node in the editor,
## then run the scene. Use the UI to zoom, auto-frame, and capture icons.
## Screenshots are saved as transparent PNGs at the resolution you choose.

# Camera defaults
const DEFAULT_PITCH := -25.0
const CAMERA_YAW_DEG := 45.0
const CAMERA_FOV := 30.0
const ZOOM_STEP := 0.3
const SCROLL_ZOOM_STEP := 0.15
const ANGLE_STEP := 5.0
const MIN_DISTANCE := 0.3
const MAX_DISTANCE := 50.0
const MIN_PITCH := -80.0
const MAX_PITCH := -5.0
const AUTO_FRAME_PADDING := 1.4

# Preview background (visible during editing, removed in screenshots)
const BG_COLOR := Color(0.15, 0.15, 0.2, 1.0)

# State
var _camera_distance := 5.0
var _camera_pitch := DEFAULT_PITCH
var _camera_target := Vector3.ZERO
var _screenshot_size := 1024
var _captured_image: Image
var _is_capturing := false

# Nodes
var _camera: Camera3D
var _env: Environment
var _ui_layer: CanvasLayer
var _file_dialog: FileDialog
var _status_label: Label
var _angle_label: Label

@onready var object_pivot: Node3D = $ObjectPivot


func _ready() -> void:
	# Anti-aliasing: MSAA smooths geometry edges, FXAA catches the rest
	get_viewport().msaa_3d = Viewport.MSAA_4X
	get_viewport().screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA

	_build_environment()
	_build_lighting()
	_build_camera()
	_build_ui()
	# Wait one frame so instanced scenes finish initializing
	await get_tree().process_frame
	_auto_frame()


func _input(event: InputEvent) -> void:
	if _is_capturing:
		return
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_EQUAL, KEY_KP_ADD:
				_zoom(-ZOOM_STEP)
			KEY_MINUS, KEY_KP_SUBTRACT:
				_zoom(ZOOM_STEP)
			KEY_UP:
				_adjust_pitch(-ANGLE_STEP)
			KEY_DOWN:
				_adjust_pitch(ANGLE_STEP)
			KEY_F12:
				_take_screenshot()
			KEY_F:
				_auto_frame()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom(-SCROLL_ZOOM_STEP)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom(SCROLL_ZOOM_STEP)


# ==== Environment ====

func _build_environment() -> void:
	_env = Environment.new()
	_env.background_mode = Environment.BG_COLOR
	_env.background_color = BG_COLOR
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = Color(0.35, 0.35, 0.45)
	_env.ambient_light_energy = 0.6
	_env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	_env.ssao_enabled = true
	_env.glow_enabled = true
	_env.glow_intensity = 0.8

	var node := WorldEnvironment.new()
	node.environment = _env
	add_child(node)


# ==== Lighting (3-point) ====

func _build_lighting() -> void:
	# Key light – upper-left-front, warm white
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-45, -45, 0)
	key.light_energy = 1.2
	key.light_color = Color(1.0, 0.98, 0.95)
	key.shadow_enabled = true
	add_child(key)

	# Fill light – right side, cool tint
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, 135, 0)
	fill.light_energy = 0.4
	fill.light_color = Color(0.85, 0.90, 1.0)
	add_child(fill)

	# Rim light – behind, subtle edge highlight
	var rim := DirectionalLight3D.new()
	rim.rotation_degrees = Vector3(-15, 200, 0)
	rim.light_energy = 0.25
	rim.light_color = Color(0.9, 0.95, 1.0)
	add_child(rim)


# ==== Camera ====

func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.current = true
	_camera.fov = CAMERA_FOV
	add_child(_camera)
	_apply_camera()


func _camera_direction() -> Vector3:
	var p := deg_to_rad(_camera_pitch)
	var y := deg_to_rad(CAMERA_YAW_DEG)
	return Vector3(cos(p) * sin(y), -sin(p), cos(p) * cos(y))


func _apply_camera() -> void:
	_camera.position = _camera_target + _camera_direction() * _camera_distance
	_camera.look_at(_camera_target, Vector3.UP)


func _zoom(delta: float) -> void:
	_camera_distance = clampf(_camera_distance + delta, MIN_DISTANCE, MAX_DISTANCE)
	_apply_camera()


func _adjust_pitch(delta: float) -> void:
	_camera_pitch = clampf(_camera_pitch + delta, MIN_PITCH, MAX_PITCH)
	_apply_camera()
	_update_angle_label()


func _auto_frame() -> void:
	var aabb := _gather_aabb()
	if aabb.size == Vector3.ZERO:
		_camera_target = Vector3.ZERO
		_apply_camera()
		return

	_camera_target = aabb.get_center()
	var extent := aabb.size.length()
	var fov_rad := deg_to_rad(_camera.fov)
	_camera_distance = (extent / 2.0) / tan(fov_rad / 2.0) * AUTO_FRAME_PADDING
	_camera_distance = clampf(_camera_distance, MIN_DISTANCE, MAX_DISTANCE)
	_apply_camera()


func _gather_aabb() -> AABB:
	var aabb := AABB()
	var found := false
	for child in object_pivot.get_children():
		for mi in _collect_meshes(child):
			var m_aabb := mi.global_transform * mi.get_aabb()
			if not found:
				aabb = m_aabb
				found = true
			else:
				aabb = aabb.merge(m_aabb)
	return aabb


func _collect_meshes(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node)
	for c in node.get_children():
		out.append_array(_collect_meshes(c))
	return out


# ==== Screenshot ====

func _take_screenshot() -> void:
	if _is_capturing:
		return
	_is_capturing = true
	_set_status("Capturing...")

	# Hide UI so it doesn't appear in the capture
	_ui_layer.visible = false

	# Enable transparent background
	var prev_bg_mode := _env.background_mode
	_env.background_mode = Environment.BG_CLEAR_COLOR
	get_viewport().transparent_bg = true

	# Wait two frames so the renderer produces a clean transparent image
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	# Grab the image
	var image := get_viewport().get_texture().get_image()

	# Restore normal state
	_env.background_mode = prev_bg_mode
	get_viewport().transparent_bg = false
	_ui_layer.visible = true

	# Crop to the largest centered square
	var w := image.get_width()
	var h := image.get_height()
	var side := mini(w, h)
	image = image.get_region(Rect2i((w - side) / 2, (h - side) / 2, side, side))

	# Resize to target icon resolution
	image.resize(_screenshot_size, _screenshot_size, Image.INTERPOLATE_LANCZOS)

	_captured_image = image
	_is_capturing = false
	_set_status("Captured! Choose save location...")

	# Suggest filename from first object name
	var fname := "icon.png"
	if object_pivot.get_child_count() > 0:
		fname = object_pivot.get_child(0).name.to_snake_case() + ".png"
	_file_dialog.current_file = fname
	_file_dialog.popup_centered(Vector2i(800, 600))


func _on_file_selected(path: String) -> void:
	if not _captured_image:
		_set_status("Error: no image to save")
		return
	if not path.ends_with(".png"):
		path += ".png"

	var err := _captured_image.save_png(path)
	if err == OK:
		_set_status("Saved: " + path.get_file())
		print("Icon saved to: ", path)
	else:
		_set_status("Save failed (error %d)" % err)
		push_error("Failed to save icon to: %s (error %d)" % [path, err])


# ==== UI ====

func _build_ui() -> void:
	_ui_layer = CanvasLayer.new()
	_ui_layer.layer = 10
	add_child(_ui_layer)

	var panel := PanelContainer.new()
	panel.position = Vector2(16, 16)
	panel.add_theme_stylebox_override("panel", _panel_style())
	_ui_layer.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	# Title
	var title := Label.new()
	title.text = "Icon Studio"
	title.add_theme_font_size_override("font_size", 22)
	vbox.add_child(title)
	vbox.add_child(HSeparator.new())

	# -- Zoom row --
	var zoom_lbl := Label.new()
	zoom_lbl.text = "Zoom"
	vbox.add_child(zoom_lbl)

	var zoom_row := HBoxContainer.new()
	zoom_row.add_theme_constant_override("separation", 4)
	vbox.add_child(zoom_row)

	_add_button(zoom_row, " + ", Vector2(44, 36), func(): _zoom(-ZOOM_STEP))
	_add_button(zoom_row, " - ", Vector2(44, 36), func(): _zoom(ZOOM_STEP))
	_add_button(zoom_row, "Auto Frame (F)", Vector2.ZERO, _auto_frame)

	vbox.add_child(HSeparator.new())

	# -- Angle section --
	var angle_lbl := Label.new()
	angle_lbl.text = "Camera Angle"
	vbox.add_child(angle_lbl)

	var angle_row := HBoxContainer.new()
	angle_row.add_theme_constant_override("separation", 4)
	vbox.add_child(angle_row)

	_add_button(angle_row, "Flatter", Vector2(70, 36), func(): _adjust_pitch(ANGLE_STEP))
	_add_button(angle_row, "Steeper", Vector2(70, 36), func(): _adjust_pitch(-ANGLE_STEP))
	_add_button(angle_row, "Reset", Vector2(50, 36), func():
		_camera_pitch = DEFAULT_PITCH
		_apply_camera()
		_update_angle_label()
	)

	_angle_label = Label.new()
	_angle_label.add_theme_font_size_override("font_size", 12)
	vbox.add_child(_angle_label)
	_update_angle_label()

	vbox.add_child(HSeparator.new())

	# -- Screenshot section --
	var shot_lbl := Label.new()
	shot_lbl.text = "Screenshot"
	vbox.add_child(shot_lbl)

	var size_row := HBoxContainer.new()
	size_row.add_theme_constant_override("separation", 8)
	vbox.add_child(size_row)

	var sl := Label.new()
	sl.text = "Size:"
	size_row.add_child(sl)

	var sizes := OptionButton.new()
	sizes.add_item("256")
	sizes.add_item("512")
	sizes.add_item("1024")
	sizes.add_item("2048")
	sizes.selected = 2
	sizes.item_selected.connect(func(idx: int):
		_screenshot_size = [256, 512, 1024, 2048][idx]
	)
	size_row.add_child(sizes)

	_add_button(vbox, "Capture Icon (F12)", Vector2(200, 44), _take_screenshot)

	vbox.add_child(HSeparator.new())

	# -- Status --
	_status_label = Label.new()
	_status_label.text = "Ready"
	_status_label.add_theme_font_size_override("font_size", 12)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.custom_minimum_size = Vector2(220, 0)
	vbox.add_child(_status_label)

	# Shortcuts hint
	var hints := Label.new()
	hints.text = "Scroll/+-: Zoom | Up/Down: Angle\nF: Auto Frame | F12: Capture"
	hints.add_theme_font_size_override("font_size", 11)
	hints.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
	vbox.add_child(hints)

	# -- File dialog --
	_file_dialog = FileDialog.new()
	_file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.add_filter("*.png", "PNG Image")
	_file_dialog.title = "Save Icon As..."
	_file_dialog.file_selected.connect(_on_file_selected)
	_ui_layer.add_child(_file_dialog)


func _add_button(parent: Control, text: String, min_size: Vector2, callback: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	if min_size != Vector2.ZERO:
		btn.custom_minimum_size = min_size
	btn.pressed.connect(callback)
	parent.add_child(btn)
	return btn


func _update_angle_label() -> void:
	if _angle_label:
		_angle_label.text = "Pitch: %.0f deg" % _camera_pitch


func _panel_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.12, 0.12, 0.15, 0.92)
	s.border_color = Color(0.3, 0.3, 0.35, 0.8)
	s.set_border_width_all(1)
	s.set_corner_radius_all(6)
	s.set_content_margin_all(14)
	return s


func _set_status(text: String) -> void:
	if _status_label:
		_status_label.text = text
