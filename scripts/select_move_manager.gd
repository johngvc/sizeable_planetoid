extends Node2D
## Manages selecting and moving physics objects with the cursor

const SELECTION_RADIUS: float = 20.0

var is_active: bool = false
var selected_body: RigidBody2D = null
var is_dragging: bool = false
var drag_offset: Vector2 = Vector2.ZERO
var original_gravity_scale: float = 1.0
var original_linear_velocity: Vector2 = Vector2.ZERO
var original_angular_velocity: float = 0.0

# Visual feedback
var highlight_color: Color = Color(0.2, 0.8, 0.2, 0.5)


func _ready() -> void:
	# Find cursor mode UI and connect to tool changes
	await get_tree().process_frame
	var cursor_ui = get_tree().get_first_node_in_group("cursor_mode_ui")
	if cursor_ui:
		cursor_ui.tool_changed.connect(_on_tool_changed)
	
	var cursor = get_tree().get_first_node_in_group("cursor")
	if cursor:
		cursor.cursor_mode_changed.connect(_on_cursor_mode_changed)


func _on_cursor_mode_changed(active: bool) -> void:
	if not active:
		# Cursor mode turned off - release any selection
		release_selection()
		is_active = false


func _on_tool_changed(tool_name: String) -> void:
	is_active = (tool_name == "select")
	if not is_active:
		release_selection()


func _process(_delta: float) -> void:
	if not is_active:
		return
	
	var cursor = get_tree().get_first_node_in_group("cursor")
	if cursor == null or not cursor.is_cursor_active():
		return
	
	var cursor_pos = cursor.global_position
	var is_clicking = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or Input.is_key_pressed(KEY_B)
	
	if is_clicking:
		if not is_dragging:
			# Try to select a body
			var body = find_body_at_position(cursor_pos)
			if body != null:
				start_dragging(body, cursor_pos)
		else:
			# Continue dragging
			if selected_body != null and is_instance_valid(selected_body):
				move_selected_body(cursor_pos)
	else:
		if is_dragging:
			release_selection()
	
	queue_redraw()


func find_body_at_position(pos: Vector2) -> RigidBody2D:
	# Find any RigidBody2D that has a collision shape near this position
	var space_state = get_world_2d().direct_space_state
	
	# Create a circle query
	var query = PhysicsPointQueryParameters2D.new()
	query.position = pos
	query.collide_with_bodies = true
	query.collide_with_areas = false
	
	var results = space_state.intersect_point(query, 10)
	
	for result in results:
		var collider = result.collider
		if collider is RigidBody2D:
			return collider
	
	return null


func start_dragging(body: RigidBody2D, cursor_pos: Vector2) -> void:
	selected_body = body
	is_dragging = true
	drag_offset = body.global_position - cursor_pos
	
	# Store original physics state
	original_gravity_scale = body.gravity_scale
	original_linear_velocity = body.linear_velocity
	original_angular_velocity = body.angular_velocity
	
	# Disable gravity and freeze motion while dragging
	body.gravity_scale = 0.0
	body.linear_velocity = Vector2.ZERO
	body.angular_velocity = 0.0
	body.freeze = true


func move_selected_body(cursor_pos: Vector2) -> void:
	if selected_body == null or not is_instance_valid(selected_body):
		return
	
	# Move the body to follow cursor (with offset)
	selected_body.global_position = cursor_pos + drag_offset


func release_selection() -> void:
	if selected_body != null and is_instance_valid(selected_body):
		# Restore physics
		selected_body.freeze = false
		selected_body.gravity_scale = original_gravity_scale
		# Give it a gentle release (no velocity)
		selected_body.linear_velocity = Vector2.ZERO
		selected_body.angular_velocity = 0.0
	
	selected_body = null
	is_dragging = false
	queue_redraw()


func _draw() -> void:
	if not is_active:
		return
	
	# Draw selection highlight around selected body
	if selected_body != null and is_instance_valid(selected_body):
		# Draw a highlight circle at the body's center
		var local_pos = to_local(selected_body.global_position)
		draw_circle(local_pos, 15.0, highlight_color)
		draw_arc(local_pos, 18.0, 0, TAU, 32, Color.GREEN, 2.0)
