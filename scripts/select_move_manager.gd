extends Node2D
## Manages selecting and moving physics objects and brush strokes with the cursor

const SELECTION_RADIUS: float = 20.0

var is_active: bool = false

# Physics body selection
var selected_body: RigidBody2D = null
var is_dragging: bool = false
var drag_offset: Vector2 = Vector2.ZERO
var original_gravity_scale: float = 1.0
var original_linear_velocity: Vector2 = Vector2.ZERO
var original_angular_velocity: float = 0.0

# Brush stroke selection
var selected_stroke_index: int = -1  # Index into draw_manager.all_strokes
var selected_preview_line: Line2D = null  # The Line2D being dragged
var drag_start_pos: Vector2 = Vector2.ZERO

# Reference to draw manager
var draw_manager: Node2D = null

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
	
	# Find draw manager
	draw_manager = get_tree().get_first_node_in_group("draw_manager")
	if draw_manager == null:
		# Try to find it by type
		for node in get_tree().get_nodes_in_group(""):
			if node.has_method("convert_strokes_to_physics"):
				draw_manager = node
				break


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
	
	# Check if mouse is over UI - don't select if so
	var is_mouse_over_ui = is_mouse_over_gui()
	var is_clicking = Input.is_key_pressed(KEY_B) or (Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and not is_mouse_over_ui)
	
	if is_clicking:
		if not is_dragging:
			# Try to select a body first
			var body = find_body_at_position(cursor_pos)
			if body != null:
				start_dragging_body(body, cursor_pos)
			else:
				# Try to select a brush stroke
				var stroke_info = find_stroke_at_position(cursor_pos)
				if stroke_info["index"] >= 0:
					start_dragging_stroke(stroke_info["index"], stroke_info["line"], cursor_pos)
		else:
			# Continue dragging
			if selected_body != null and is_instance_valid(selected_body):
				move_selected_body(cursor_pos)
			elif selected_stroke_index >= 0:
				move_selected_stroke(cursor_pos)
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


func find_stroke_at_position(pos: Vector2) -> Dictionary:
	# Find a brush stroke (preview line) near this position
	# Returns { "index": stroke_index, "line": Line2D } or { "index": -1, "line": null }
	
	if draw_manager == null:
		return { "index": -1, "line": null }
	
	# Check finished strokes (preview_lines array corresponds to all_strokes)
	if draw_manager.preview_lines.size() > 0 and draw_manager.all_strokes.size() > 0:
		for i in range(draw_manager.preview_lines.size()):
			var line = draw_manager.preview_lines[i]
			if is_instance_valid(line) and is_point_near_line(pos, line):
				return { "index": i, "line": line }
	
	return { "index": -1, "line": null }


func is_point_near_line(pos: Vector2, line: Line2D) -> bool:
	# Check if pos is within SELECTION_RADIUS of any point on the line
	for i in range(line.get_point_count()):
		var line_point = line.get_point_position(i)
		# Line2D points are in the line's local space, convert to global
		var global_point = line.to_global(line_point)
		if pos.distance_to(global_point) <= SELECTION_RADIUS:
			return true
	return false


func start_dragging_body(body: RigidBody2D, cursor_pos: Vector2) -> void:
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


func start_dragging_stroke(stroke_index: int, line: Line2D, cursor_pos: Vector2) -> void:
	selected_stroke_index = stroke_index
	selected_preview_line = line
	is_dragging = true
	drag_start_pos = cursor_pos


func move_selected_body(cursor_pos: Vector2) -> void:
	if selected_body == null or not is_instance_valid(selected_body):
		return
	
	# Move the body to follow cursor (with offset)
	selected_body.global_position = cursor_pos + drag_offset


func move_selected_stroke(cursor_pos: Vector2) -> void:
	if draw_manager == null or selected_stroke_index < 0:
		return
	if selected_stroke_index >= draw_manager.all_strokes.size():
		return
	if selected_preview_line == null or not is_instance_valid(selected_preview_line):
		return
	
	# Calculate movement delta
	var delta = cursor_pos - drag_start_pos
	drag_start_pos = cursor_pos
	
	# Update the stroke data points
	var stroke_data = draw_manager.all_strokes[selected_stroke_index]
	var points = stroke_data["points"]
	for i in range(points.size()):
		points[i] += delta
	
	# Update the Line2D visual
	for i in range(selected_preview_line.get_point_count()):
		var old_pos = selected_preview_line.get_point_position(i)
		selected_preview_line.set_point_position(i, old_pos + delta)


func release_selection() -> void:
	if selected_body != null and is_instance_valid(selected_body):
		# Restore physics
		selected_body.freeze = false
		selected_body.gravity_scale = original_gravity_scale
		# Give it a gentle release (no velocity)
		selected_body.linear_velocity = Vector2.ZERO
		selected_body.angular_velocity = 0.0
	
	selected_body = null
	selected_stroke_index = -1
	selected_preview_line = null
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
	
	# Draw selection highlight around selected stroke
	if selected_preview_line != null and is_instance_valid(selected_preview_line):
		# Draw highlight around the stroke's bounding area
		for i in range(selected_preview_line.get_point_count()):
			var point = selected_preview_line.get_point_position(i)
			var global_point = selected_preview_line.to_global(point)
			var local_point = to_local(global_point)
			draw_circle(local_point, 10.0, highlight_color)


func is_mouse_over_gui() -> bool:
	# Check if the mouse is currently over any GUI control
	var mouse_pos = get_viewport().get_mouse_position()
	
	# Get all Control nodes and check if mouse is over any of them
	var controls = get_tree().get_nodes_in_group("cursor_mode_ui")
	for node in controls:
		if node is CanvasLayer:
			for child in node.get_children():
				if child is Control and child.visible:
					if is_control_hovered(child, mouse_pos):
						return true
	
	return false


func is_control_hovered(control: Control, mouse_pos: Vector2) -> bool:
	# Check if this control or any of its children are hovered
	if control.get_global_rect().has_point(mouse_pos):
		return true
	
	for child in control.get_children():
		if child is Control and child.visible:
			if is_control_hovered(child, mouse_pos):
				return true
	
	return false
