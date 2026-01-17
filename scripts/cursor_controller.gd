extends Node2D
## Cursor controller - toggles with C key, moves with arrow keys or mouse

signal cursor_mode_changed(active: bool)

@export var cursor_speed: float = 200.0
@export var cursor_color: Color = Color(0.2, 0.5, 1.0, 0.8)
@export var cursor_radius: float = 10.0

var is_active: bool = false
var cursor_position: Vector2 = Vector2.ZERO
var camera: Camera2D = null
var use_mouse: bool = true  # Enable mouse control


func _ready() -> void:
	visible = false
	# Find camera
	await get_tree().process_frame
	camera = get_tree().get_first_node_in_group("main_camera")
	if camera == null:
		camera = get_viewport().get_camera_2d()
	
	# Auto-start cursor mode
	toggle_cursor()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_C:
		toggle_cursor()
	
	# Track mouse movement when cursor is active
	if is_active and event is InputEventMouseMotion:
		update_cursor_from_mouse()


func toggle_cursor() -> void:
	is_active = not is_active
	visible = is_active
	
	if is_active:
		# Start cursor at mouse position if available, otherwise camera center
		if use_mouse:
			update_cursor_from_mouse()
		elif camera:
			cursor_position = camera.global_position
		else:
			cursor_position = get_viewport().get_visible_rect().size / 2
		global_position = cursor_position
	
	cursor_mode_changed.emit(is_active)


func update_cursor_from_mouse() -> void:
	# Convert mouse screen position to world position
	var mouse_screen_pos = get_viewport().get_mouse_position()
	
	if camera:
		var viewport_size = get_viewport().get_visible_rect().size
		var zoom = camera.zoom
		
		# Calculate world position from screen position
		var screen_center = viewport_size / 2.0
		var offset_from_center = (mouse_screen_pos - screen_center) / zoom
		cursor_position = camera.global_position + offset_from_center
		
		# Clamp to viewport bounds
		var half_view = viewport_size / (2.0 * zoom)
		var cam_pos = camera.global_position
		cursor_position.x = clamp(cursor_position.x, cam_pos.x - half_view.x + cursor_radius, cam_pos.x + half_view.x - cursor_radius)
		cursor_position.y = clamp(cursor_position.y, cam_pos.y - half_view.y + cursor_radius, cam_pos.y + half_view.y - cursor_radius)
	else:
		cursor_position = mouse_screen_pos
	
	global_position = cursor_position


func _process(delta: float) -> void:
	if not is_active:
		return
	
	# Keyboard movement (in addition to mouse)
	var direction := Vector2.ZERO
	direction.x = Input.get_axis("ui_left", "ui_right")
	direction.y = Input.get_axis("ui_up", "ui_down")
	
	if direction != Vector2.ZERO:
		# If using keyboard, move cursor
		cursor_position += direction * cursor_speed * delta
		
		# Clamp cursor to camera viewport bounds
		if camera:
			var viewport_size = get_viewport().get_visible_rect().size
			var zoom = camera.zoom
			var half_view = viewport_size / (2.0 * zoom)
			var cam_pos = camera.global_position
			
			cursor_position.x = clamp(cursor_position.x, cam_pos.x - half_view.x + cursor_radius, cam_pos.x + half_view.x - cursor_radius)
			cursor_position.y = clamp(cursor_position.y, cam_pos.y - half_view.y + cursor_radius, cam_pos.y + half_view.y - cursor_radius)
		
		global_position = cursor_position


func _draw() -> void:
	# Draw blue circle cursor
	draw_circle(Vector2.ZERO, cursor_radius, cursor_color)
	# Draw outline for visibility
	draw_arc(Vector2.ZERO, cursor_radius, 0, TAU, 32, Color.WHITE, 2.0)


func is_cursor_active() -> bool:
	return is_active
