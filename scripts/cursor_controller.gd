extends Node2D
## Cursor controller - toggles with C key, moves with arrow keys or mouse

signal cursor_mode_changed(active: bool)
signal toolbox_mode_changed(active: bool)

@export var cursor_speed: float = 200.0
@export var cursor_color: Color = Color(0.2, 0.5, 1.0, 0.8)
@export var cursor_radius: float = 10.0

var is_active: bool = false
var is_toolbox_mode: bool = false
var cursor_position: Vector2 = Vector2.ZERO
var camera: Camera2D = null
var use_mouse: bool = true  # Enable mouse control
var player: CharacterBody2D = null

# Brush shape preview
var current_brush_shape: String = "circle"
var current_tool: String = "draw_dynamic"
var brush_preview_size: float = 16.0  # Matches DRAW_SIZE in draw_manager
var brush_preview_color: Color = Color(1.0, 1.0, 1.0, 0.3)

# Camera edge dragging
@export var drag_border_thickness: float = 40.0  # Pixels from edge to trigger drag
@export var drag_frame_inset: float = 30.0  # Inner frame distance from viewport edge (pixels) where dragging starts
@export var drag_speed: float = 400.0


func _ready() -> void:
	visible = false
	# Find camera and player
	await get_tree().process_frame
	camera = get_tree().get_first_node_in_group("main_camera")
	if camera == null:
		camera = get_viewport().get_camera_2d()
	
	player = get_tree().get_first_node_in_group("player")
	
	# Connect to cursor mode UI for brush shape and tool changes
	var cursor_ui = get_tree().get_first_node_in_group("cursor_mode_ui")
	if cursor_ui:
		cursor_ui.brush_shape_changed.connect(_on_brush_shape_changed)
		cursor_ui.tool_changed.connect(_on_tool_changed)
		# Get initial values
		current_brush_shape = cursor_ui.get_current_brush_shape()
		current_tool = cursor_ui.get_current_tool()


func _on_brush_shape_changed(shape: String) -> void:
	current_brush_shape = shape
	queue_redraw()


func _on_tool_changed(tool_name: String) -> void:
	current_tool = tool_name
	
	# Handle toolbox mode
	var is_toolbox = (tool_name == "toolbox")
	if is_toolbox != is_toolbox_mode:
		is_toolbox_mode = is_toolbox
		toolbox_mode_changed.emit(is_toolbox_mode)
	
	queue_redraw()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_C:
		toggle_cursor()
	
	# Track mouse movement when cursor is active
	if is_active and event is InputEventMouseMotion:
		update_cursor_from_mouse()
	
	# Handle clicks in toolbox mode
	if is_active and is_toolbox_mode and event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_on_toolbox_click()


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
	else:
		# When deactivating cursor, also deactivate toolbox mode
		if is_toolbox_mode:
			is_toolbox_mode = false
			toolbox_mode_changed.emit(false)
	
	cursor_mode_changed.emit(is_active)


func _on_toolbox_click() -> void:
	"""Handle clicks in toolbox mode"""
	var bolt_tool = get_tree().get_first_node_in_group("bolt_tool")
	if bolt_tool:
		bolt_tool.place_bolt(global_position)


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
	if not is_active and not is_toolbox_mode:
		return
	
	# Update cursor from mouse to keep it synced during camera movement
	if use_mouse:
		update_cursor_from_mouse()
	
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
	
	# Check for camera edge dragging in fly mode
	if is_active and player and camera:
		_handle_camera_edge_dragging(delta)


func _draw() -> void:
	if is_toolbox_mode:
		# Draw toolbox cursor (different visual)
		draw_circle(Vector2.ZERO, cursor_radius, Color(1.0, 0.6, 0.2, 0.8))
		draw_arc(Vector2.ZERO, cursor_radius, 0, TAU, 32, Color.WHITE, 2.0)
		# Draw crosshair for precision
		draw_line(Vector2(-cursor_radius * 1.5, 0), Vector2(cursor_radius * 1.5, 0), Color.WHITE, 1.5)
		draw_line(Vector2(0, -cursor_radius * 1.5), Vector2(0, cursor_radius * 1.5), Color.WHITE, 1.5)
	else:
		# Draw blue circle cursor
		draw_circle(Vector2.ZERO, cursor_radius, cursor_color)
		# Draw outline for visibility
		draw_arc(Vector2.ZERO, cursor_radius, 0, TAU, 32, Color.WHITE, 2.0)
		
		# Draw brush shape preview when in draw mode
		if is_drawing_tool():
			var half_size = brush_preview_size / 2.0
			if current_brush_shape == "circle":
				draw_circle(Vector2.ZERO, half_size, brush_preview_color)
				draw_arc(Vector2.ZERO, half_size, 0, TAU, 32, Color(1.0, 1.0, 1.0, 0.5), 1.0)
			elif current_brush_shape == "square":
				var rect = Rect2(-half_size, -half_size, brush_preview_size, brush_preview_size)
				draw_rect(rect, brush_preview_color)
				draw_rect(rect, Color(1.0, 1.0, 1.0, 0.5), false, 1.0)


func is_drawing_tool() -> bool:
	return current_tool == "draw_dynamic" or current_tool == "draw_static"


func is_cursor_active() -> bool:
	return is_active


func _handle_camera_edge_dragging(_delta: float) -> void:
	"""Drag player when cursor is near camera viewport edges in fly mode"""
	# Only drag if player is in fly mode
	if not player.has_method("set_drag_velocity"):
		return
	
	# Get cursor position in screen space
	var viewport_size = get_viewport().get_visible_rect().size
	var zoom = camera.zoom
	
	# Convert cursor world position to screen position
	var cursor_world_pos = global_position
	var cam_pos = camera.global_position
	var cursor_offset_from_cam = cursor_world_pos - cam_pos
	var screen_offset = cursor_offset_from_cam * zoom
	var cursor_screen_pos = (viewport_size / 2.0) + screen_offset
	
	# Define the inner frame boundaries where dragging begins
	var frame_left = drag_frame_inset
	var frame_right = viewport_size.x - drag_frame_inset
	var frame_top = drag_frame_inset
	var frame_bottom = viewport_size.y - drag_frame_inset
	
	# Check distance from frame edges
	var drag_vector := Vector2.ZERO
	
	# Left edge
	if cursor_screen_pos.x < frame_left:
		var distance_into_frame = frame_left - cursor_screen_pos.x
		var intensity = min(distance_into_frame / drag_border_thickness, 1.0)
		drag_vector.x -= intensity
	
	# Right edge
	elif cursor_screen_pos.x > frame_right:
		var distance_into_frame = cursor_screen_pos.x - frame_right
		var intensity = min(distance_into_frame / drag_border_thickness, 1.0)
		drag_vector.x += intensity
	
	# Top edge
	if cursor_screen_pos.y < frame_top:
		var distance_into_frame = frame_top - cursor_screen_pos.y
		var intensity = min(distance_into_frame / drag_border_thickness, 1.0)
		drag_vector.y -= intensity
	
	# Bottom edge
	elif cursor_screen_pos.y > frame_bottom:
		var distance_into_frame = cursor_screen_pos.y - frame_bottom
		var intensity = min(distance_into_frame / drag_border_thickness, 1.0)
		drag_vector.y += intensity
	
	# Apply drag velocity to player
	if drag_vector != Vector2.ZERO:
		drag_vector = drag_vector.normalized()
		player.set_drag_velocity(drag_vector * drag_speed)
	else:
		player.set_drag_velocity(Vector2.ZERO)
