extends Node2D
## Manages selecting and moving physics objects and brush strokes with the cursor

const SELECTION_RADIUS: float = 20.0

# Transform mode enum
enum TransformMode { MOVE, RESIZE, ROTATE }
var current_transform_mode: TransformMode = TransformMode.MOVE

# Sensitivity settings (lower = less sensitive for fine control)
const MOVE_SENSITIVITY: float = 0.5
const RESIZE_SENSITIVITY: float = 0.003  # Very low for gradual scaling
const ROTATE_SENSITIVITY: float = 0.002  # Very low for gradual rotation

# For resize/rotate - track original state
var original_scale: Vector2 = Vector2.ONE
var original_rotation: float = 0.0
var original_position: Vector2 = Vector2.ZERO
var transform_pivot: Vector2 = Vector2.ZERO  # The click point - origin for transforms
var accumulated_mouse_delta: Vector2 = Vector2.ZERO
var last_mouse_position: Vector2 = Vector2.ZERO
var click_local_offset: Vector2 = Vector2.ZERO  # Where on the body the user clicked (local coords)

# For physics body resizing - store original collision shape sizes
var original_collision_shapes: Dictionary = {}  # child -> original size/radius

var is_active: bool = false

# ============================================================================
# TRANSFORM CALCULATION HELPERS - Single source of truth for transform math
# ============================================================================

func calculate_scale_from_mouse_delta(mouse_delta: Vector2) -> float:
	## Calculate uniform scale factor from diagonal mouse movement
	## Moving right-up increases, left-down decreases
	var diagonal_delta = (mouse_delta.x - mouse_delta.y) * RESIZE_SENSITIVITY
	var scale_factor = 1.0 + diagonal_delta
	return clamp(scale_factor, 0.1, 5.0)


func calculate_rotation_from_mouse_delta(mouse_delta: Vector2) -> float:
	## Calculate rotation angle from horizontal mouse movement
	## Moving right rotates clockwise
	return mouse_delta.x * ROTATE_SENSITIVITY


func calculate_pivot_adjusted_position_for_scale(
	original_pos: Vector2, 
	pivot: Vector2, 
	orig_scale: Vector2, 
	new_scale: Vector2
) -> Vector2:
	## Calculate new position when scaling around a pivot point
	## Returns the position that keeps the pivot point stationary
	var pivot_local = pivot - original_pos
	var scale_ratio = new_scale / orig_scale
	var scaled_pivot = pivot_local * scale_ratio
	var position_offset = pivot_local - scaled_pivot
	return original_pos + position_offset


func calculate_pivot_adjusted_position_for_rotation(
	original_pos: Vector2, 
	pivot: Vector2, 
	rotation_delta: float
) -> Vector2:
	## Calculate new position when rotating around a pivot point
	## Returns the position that keeps the pivot point stationary
	var pivot_to_node = original_pos - pivot
	var rotated_offset = pivot_to_node.rotated(rotation_delta)
	return pivot + rotated_offset


func bake_transform_to_points(points: Array, node_transform: Transform2D) -> Array:
	## Apply a Transform2D to an array of points
	## This is the single source of truth for baking transforms into point data
	var transformed_points: Array = []
	for point in points:
		transformed_points.append(node_transform * point)
	return transformed_points

# ============================================================================

# Physics body selection (works for both RigidBody2D and StaticBody2D)
var selected_body: PhysicsBody2D = null  # Can be RigidBody2D or StaticBody2D
var selected_is_static: bool = false  # Track if selected body is static
var is_dragging: bool = false
var drag_offset: Vector2 = Vector2.ZERO
var original_gravity_scale: float = 1.0
var original_linear_velocity: Vector2 = Vector2.ZERO
var original_angular_velocity: float = 0.0

# Brush stroke selection
var selected_stroke_index: int = -1  # Index into draw_manager.all_strokes
var selected_preview_node: Node2D = null  # The preview node being dragged (Line2D or container)
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
	var was_active = is_active
	is_active = (tool_name == "select")
	
	# Update UI label visibility
	var cursor_ui = get_tree().get_first_node_in_group("cursor_mode_ui")
	if cursor_ui and cursor_ui.has_method("show_transform_mode_label"):
		cursor_ui.show_transform_mode_label(is_active)
	
	if not is_active:
		release_selection()
		# Reset to Move mode when leaving select tool
		current_transform_mode = TransformMode.MOVE
	else:
		# Entering select tool - update label to show Move mode
		if cursor_ui and cursor_ui.has_method("update_transform_mode_label"):
			cursor_ui.update_transform_mode_label("Move")


func _unhandled_input(event: InputEvent) -> void:
	if not is_active:
		return
	
	# Q key cycles through transform modes
	if event is InputEventKey and event.pressed and event.keycode == KEY_Q:
		cycle_transform_mode()
		get_viewport().set_input_as_handled()


func cycle_transform_mode() -> void:
	# Cycle: MOVE -> RESIZE -> ROTATE -> MOVE
	var old_mode = get_mode_name()
	match current_transform_mode:
		TransformMode.MOVE:
			current_transform_mode = TransformMode.RESIZE
		TransformMode.RESIZE:
			current_transform_mode = TransformMode.ROTATE
		TransformMode.ROTATE:
			current_transform_mode = TransformMode.MOVE
	
	# If currently dragging, reset transform state for the new mode
	if is_dragging:
		var cursor = get_tree().get_first_node_in_group("cursor")
		if cursor:
			var cursor_pos = cursor.global_position
			# Sync last_mouse_position to avoid spurious delta on next frame
			last_mouse_position = cursor_pos
			# Update original state based on current body position for resize/rotate
			if selected_body != null and is_instance_valid(selected_body):
				# Recalculate drag_offset for move mode based on current position
				drag_offset = selected_body.global_position - cursor_pos
				original_position = selected_body.global_position
				original_rotation = selected_body.rotation
				transform_pivot = cursor_pos
				accumulated_mouse_delta = Vector2.ZERO
				# Re-store collision shape sizes at their current state
				original_collision_shapes.clear()
				for child in selected_body.get_children():
					if child is CollisionShape2D:
						if child.shape is CircleShape2D:
							original_collision_shapes[child] = {
								"type": "circle",
								"radius": child.shape.radius,
								"position": child.position
							}
						elif child.shape is RectangleShape2D:
							original_collision_shapes[child] = {
								"type": "rectangle",
								"size": child.shape.size,
								"position": child.position
							}
					elif child is Line2D:
						original_collision_shapes[child] = {
							"type": "line2d",
							"width": child.width,
							"points": child.points.duplicate()
						}
					elif child is ColorRect:
						original_collision_shapes[child] = {
							"type": "colorrect",
							"size": child.size,
							"position": child.position
						}
					elif child is Node2D:
						var child_data = {"type": "container", "children": {}}
						for subchild in child.get_children():
							if subchild is ColorRect:
								child_data["children"][subchild] = {
									"size": subchild.size,
									"position": subchild.position
								}
						original_collision_shapes[child] = child_data
			elif selected_preview_node != null and is_instance_valid(selected_preview_node):
				original_position = selected_preview_node.global_position
				original_rotation = selected_preview_node.rotation
				original_scale = selected_preview_node.scale
				transform_pivot = cursor_pos
				accumulated_mouse_delta = Vector2.ZERO
	
	# Update UI label
	var cursor_ui = get_tree().get_first_node_in_group("cursor_mode_ui")
	if cursor_ui and cursor_ui.has_method("update_transform_mode_label"):
		cursor_ui.update_transform_mode_label(get_mode_name())
	
	queue_redraw()


func get_mode_name() -> String:
	match current_transform_mode:
		TransformMode.MOVE:
			return "Move"
		TransformMode.RESIZE:
			return "Resize"
		TransformMode.ROTATE:
			return "Rotate"
	return "Unknown"


func _process(_delta: float) -> void:
	if not is_active:
		return
	
	var cursor = get_tree().get_first_node_in_group("cursor")
	if cursor == null or not cursor.is_cursor_active():
		return
	
	# Use cursor position directly - it's updated from mouse
	var cursor_pos = cursor.global_position
	
	# Check if mouse is over UI - don't select if so
	var is_mouse_over_ui = is_mouse_over_gui()
	var is_clicking = Input.is_key_pressed(KEY_B) or (Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and not is_mouse_over_ui)
	
	if is_clicking:
		if not is_dragging:
			# Try to select a body first (RigidBody2D or StaticBody2D)
			var body = find_body_at_position(cursor_pos)
			if body != null:
				start_dragging_body(body, cursor_pos)
			else:
				# Try to select a brush stroke
				var stroke_info = find_stroke_at_position(cursor_pos)
				if stroke_info["index"] >= 0:
					start_dragging_stroke(stroke_info["index"], stroke_info["node"], cursor_pos)
		else:
			# Continue dragging - apply transform based on current mode
			var mouse_delta = cursor_pos - last_mouse_position
			last_mouse_position = cursor_pos
			
			if selected_body != null and is_instance_valid(selected_body):
				apply_transform_to_body(cursor_pos, mouse_delta)
			elif selected_stroke_index >= 0:
				apply_transform_to_stroke(cursor_pos, mouse_delta)
	else:
		if is_dragging:
			release_selection()
		last_mouse_position = cursor_pos  # Track mouse even when not dragging
	
	queue_redraw()


func find_body_at_position(pos: Vector2) -> PhysicsBody2D:
	# Find any RigidBody2D or StaticBody2D that has a collision shape near this position
	var space_state = get_world_2d().direct_space_state
	
	# Create a circle query
	var query = PhysicsPointQueryParameters2D.new()
	query.position = pos
	query.collide_with_bodies = true
	query.collide_with_areas = false
	
	var results = space_state.intersect_point(query, 10)
	
	for result in results:
		var collider = result.collider
		if collider is RigidBody2D or collider is StaticBody2D:
			return collider
	
	return null


func find_stroke_at_position(pos: Vector2) -> Dictionary:
	# Find a brush stroke (preview node) near this position
	# Returns { "index": stroke_index, "node": Node2D } or { "index": -1, "node": null }
	
	if draw_manager == null:
		return { "index": -1, "node": null }
	
	# Check finished strokes (preview_nodes array corresponds to all_strokes)
	if draw_manager.preview_nodes.size() > 0 and draw_manager.all_strokes.size() > 0:
		for i in range(draw_manager.preview_nodes.size()):
			var node = draw_manager.preview_nodes[i]
			if is_instance_valid(node) and is_point_near_preview_node(pos, node):
				return { "index": i, "node": node }
	
	return { "index": -1, "node": null }


func is_point_near_preview_node(pos: Vector2, node: Node2D) -> bool:
	# Check if pos is within SELECTION_RADIUS of any point on the preview node
	if node is Line2D:
		var line = node as Line2D
		for i in range(line.get_point_count()):
			var line_point = line.get_point_position(i)
			var global_point = line.to_global(line_point)
			if pos.distance_to(global_point) <= SELECTION_RADIUS:
				return true
	else:
		# It's a container with ColorRects
		for child in node.get_children():
			if child is ColorRect:
				var center = child.position + child.size / 2.0
				var global_point = node.to_global(center)
				if pos.distance_to(global_point) <= SELECTION_RADIUS:
					return true
	return false


func start_dragging_body(body: PhysicsBody2D, cursor_pos: Vector2) -> void:
	selected_body = body
	is_dragging = true
	# Calculate drag offset - the difference between body position and where we clicked
	# This ensures the object follows the mouse from the click point, not its center
	drag_offset = body.global_position - cursor_pos
	# Also store click position in local body coordinates for consistent tracking after transforms
	click_local_offset = body.to_local(cursor_pos)
	selected_is_static = body is StaticBody2D
	last_mouse_position = cursor_pos
	accumulated_mouse_delta = Vector2.ZERO
	
	# Store original transform state and pivot point (click position)
	original_scale = body.scale
	original_rotation = body.rotation
	original_position = body.global_position
	# For move mode, the pivot is the body position so it follows directly
	# For resize/rotate, the pivot is the click position
	transform_pivot = cursor_pos
	
	# Store original collision shape sizes and visual sizes for proper resizing
	original_collision_shapes.clear()
	for child in body.get_children():
		if child is CollisionShape2D:
			if child.shape is CircleShape2D:
				original_collision_shapes[child] = {
					"type": "circle",
					"radius": child.shape.radius,
					"position": child.position
				}
			elif child.shape is RectangleShape2D:
				original_collision_shapes[child] = {
					"type": "rectangle",
					"size": child.shape.size,
					"position": child.position
				}
		elif child is Line2D:
			original_collision_shapes[child] = {
				"type": "line2d",
				"width": child.width,
				"points": child.points.duplicate()
			}
		elif child is ColorRect:
			original_collision_shapes[child] = {
				"type": "colorrect",
				"size": child.size,
				"position": child.position
			}
		elif child is Node2D:
			# Container node with ColorRects
			var child_data = {"type": "container", "children": {}}
			for subchild in child.get_children():
				if subchild is ColorRect:
					child_data["children"][subchild] = {
						"size": subchild.size,
						"position": subchild.position
					}
			original_collision_shapes[child] = child_data
	
	if body is RigidBody2D:
		var rigid_body = body as RigidBody2D
		# Store original physics state
		original_gravity_scale = rigid_body.gravity_scale
		original_linear_velocity = rigid_body.linear_velocity
		original_angular_velocity = rigid_body.angular_velocity
		
		# Disable gravity and freeze motion while dragging
		rigid_body.gravity_scale = 0.0
		rigid_body.linear_velocity = Vector2.ZERO
		rigid_body.angular_velocity = 0.0
		rigid_body.freeze_mode = RigidBody2D.FREEZE_MODE_STATIC
		rigid_body.freeze = true
	# StaticBody2D doesn't need any special handling - it's already static


func start_dragging_stroke(stroke_index: int, node: Node2D, cursor_pos: Vector2) -> void:
	selected_stroke_index = stroke_index
	selected_preview_node = node
	is_dragging = true
	drag_start_pos = cursor_pos
	last_mouse_position = cursor_pos
	accumulated_mouse_delta = Vector2.ZERO
	
	# Calculate drag_offset for strokes too - same approach as bodies
	drag_offset = node.global_position - cursor_pos
	
	# Store original transform state for stroke and pivot point
	original_scale = node.scale
	original_rotation = node.rotation
	original_position = node.global_position
	transform_pivot = cursor_pos  # Click point is the origin for transforms


func apply_transform_to_body(cursor_pos: Vector2, mouse_delta: Vector2) -> void:
	if selected_body == null or not is_instance_valid(selected_body):
		return
	
	# Accumulate mouse delta for resize/rotate operations
	accumulated_mouse_delta += mouse_delta
	
	match current_transform_mode:
		TransformMode.MOVE:
			# Move the body directly following the cursor
			selected_body.global_position = cursor_pos + drag_offset
		
		TransformMode.RESIZE:
			# Calculate scale using shared helper
			var scale_factor = calculate_scale_from_mouse_delta(accumulated_mouse_delta)
			
			# Scale collision shapes and visuals directly around body center
			for child in original_collision_shapes:
				if not is_instance_valid(child):
					continue
				var data = original_collision_shapes[child]
				
				if child is CollisionShape2D:
					# Scale position relative to body center
					child.position = data["position"] * scale_factor
					
					# Scale the shape itself
					if data["type"] == "circle":
						child.shape.radius = data["radius"] * scale_factor
					elif data["type"] == "rectangle":
						child.shape.size = data["size"] * scale_factor
				
				elif child is Line2D:
					# Scale line width and points
					child.width = data["width"] * scale_factor
					var orig_points = data["points"]
					for i in range(orig_points.size()):
						child.set_point_position(i, orig_points[i] * scale_factor)
				
				elif child is ColorRect:
					# Scale ColorRect size and position
					child.size = data["size"] * scale_factor
					child.position = data["position"] * scale_factor - child.size / 2.0 + data["size"] / 2.0 * scale_factor
				
				elif data["type"] == "container":
					# Scale children inside container
					for subchild in data["children"]:
						if is_instance_valid(subchild) and subchild is ColorRect:
							var subdata = data["children"][subchild]
							subchild.size = subdata["size"] * scale_factor
							var orig_center = subdata["position"] + subdata["size"] / 2.0
							var new_center = orig_center * scale_factor
							subchild.position = new_center - subchild.size / 2.0
		
		TransformMode.ROTATE:
			# Calculate rotation using shared helper
			var rotation_delta = calculate_rotation_from_mouse_delta(accumulated_mouse_delta)
			var new_rotation = original_rotation + rotation_delta
			
			# Rotate around body center
			selected_body.rotation = new_rotation


func move_selected_body(cursor_pos: Vector2) -> void:
	# Legacy function - now handled by apply_transform_to_body
	if selected_body == null or not is_instance_valid(selected_body):
		return
	selected_body.global_position = cursor_pos + drag_offset


func apply_transform_to_stroke(cursor_pos: Vector2, mouse_delta: Vector2) -> void:
	if draw_manager == null or selected_stroke_index < 0:
		return
	if selected_stroke_index >= draw_manager.all_strokes.size():
		return
	if selected_preview_node == null or not is_instance_valid(selected_preview_node):
		return
	
	# Accumulate mouse delta for resize/rotate operations
	accumulated_mouse_delta += mouse_delta
	
	match current_transform_mode:
		TransformMode.MOVE:
			# Move the stroke node using global offset - same approach as physics bodies
			selected_preview_node.global_position = cursor_pos + drag_offset
		
		TransformMode.RESIZE:
			# Calculate scale using shared helper
			var scale_factor = calculate_scale_from_mouse_delta(accumulated_mouse_delta)
			var new_scale = original_scale * scale_factor
			
			# Calculate pivot-adjusted position using shared helper
			var new_pos = calculate_pivot_adjusted_position_for_scale(
				original_position, transform_pivot, original_scale, new_scale
			)
			
			selected_preview_node.scale = new_scale
			selected_preview_node.global_position = new_pos
		
		TransformMode.ROTATE:
			# Calculate rotation using shared helper
			var rotation_delta = calculate_rotation_from_mouse_delta(accumulated_mouse_delta)
			var new_rotation = original_rotation + rotation_delta
			
			# Calculate pivot-adjusted position using shared helper
			var new_pos = calculate_pivot_adjusted_position_for_rotation(
				original_position, transform_pivot, rotation_delta
			)
			
			selected_preview_node.rotation = new_rotation
			selected_preview_node.global_position = new_pos


func move_selected_stroke(cursor_pos: Vector2) -> void:
	# Legacy function for compatibility
	if draw_manager == null or selected_stroke_index < 0:
		return
	if selected_stroke_index >= draw_manager.all_strokes.size():
		return
	if selected_preview_node == null or not is_instance_valid(selected_preview_node):
		return
	
	var delta = cursor_pos - drag_start_pos
	drag_start_pos = cursor_pos
	
	var stroke_data = draw_manager.all_strokes[selected_stroke_index]
	var points = stroke_data["points"]
	for i in range(points.size()):
		points[i] += delta
	
	if selected_preview_node is Line2D:
		var line = selected_preview_node as Line2D
		for i in range(line.get_point_count()):
			var old_pos = line.get_point_position(i)
			line.set_point_position(i, old_pos + delta)
	else:
		for child in selected_preview_node.get_children():
			if child is ColorRect:
				child.position += delta


func release_selection() -> void:
	# Update stroke data if we were transforming a preview stroke
	if selected_stroke_index >= 0 and selected_preview_node != null and is_instance_valid(selected_preview_node):
		update_stroke_data_from_transform()
	
	if selected_body != null and is_instance_valid(selected_body):
		if selected_body is RigidBody2D:
			var rigid_body = selected_body as RigidBody2D
			# Check if physics is paused - if so, keep frozen
			var cursor_ui = get_tree().get_first_node_in_group("cursor_mode_ui")
			var physics_paused = cursor_ui != null and cursor_ui.is_paused()
			
			if physics_paused:
				# Keep frozen but restore gravity scale for when unpaused
				rigid_body.gravity_scale = original_gravity_scale
			else:
				# Restore physics
				rigid_body.freeze = false
				rigid_body.freeze_mode = RigidBody2D.FREEZE_MODE_KINEMATIC
				rigid_body.gravity_scale = original_gravity_scale
				# Give it a gentle release (no velocity)
				rigid_body.linear_velocity = Vector2.ZERO
				rigid_body.angular_velocity = 0.0
		# StaticBody2D doesn't need any restoration
	
	selected_body = null
	selected_is_static = false
	selected_stroke_index = -1
	selected_preview_node = null
	is_dragging = false
	queue_redraw()


func update_stroke_data_from_transform() -> void:
	## Updates the stroke data in all_strokes to reflect the preview node's transform
	## This ensures the physics conversion uses the transformed points
	if draw_manager == null or selected_stroke_index < 0:
		return
	if selected_stroke_index >= draw_manager.all_strokes.size():
		return
	if selected_preview_node == null or not is_instance_valid(selected_preview_node):
		return
	
	var stroke_data = draw_manager.all_strokes[selected_stroke_index]
	var original_points = stroke_data["points"]
	
	# Get the node's transform - this is what Godot uses to render the Line2D/ColorRects
	var node_transform = selected_preview_node.get_global_transform()
	
	# Use shared helper to bake transform into points
	var transformed_points = bake_transform_to_points(original_points, node_transform)
	
	# Get the scale factor to apply to line width and other size properties
	var scale_factor = selected_preview_node.scale.x  # Uniform scale
	
	# Get the current brush_scale and accumulate the new scale factor
	var current_brush_scale = stroke_data.get("brush_scale", 1.0)
	var new_brush_scale = current_brush_scale * scale_factor
	
	# Update the stroke data with transformed points and accumulated brush scale
	stroke_data["points"] = transformed_points
	stroke_data["brush_scale"] = new_brush_scale
	
	# Reset the preview node's transform since the points are now in world space
	selected_preview_node.global_position = Vector2.ZERO
	selected_preview_node.scale = Vector2.ONE
	selected_preview_node.rotation = 0.0
	
	# Update the visual representation to match the new points, including scaled line width
	update_preview_visuals_from_points(selected_preview_node, transformed_points, stroke_data, scale_factor)


func update_preview_visuals_from_points(node: Node2D, points: Array, stroke_data: Dictionary, scale_factor: float = 1.0) -> void:
	## Updates the visual elements of a preview node to match new world-space points
	## scale_factor is used to scale line width and square sizes
	var brush_shape = stroke_data.get("brush_shape", "circle")
	
	if brush_shape == "circle":
		# Node is a Line2D
		if node is Line2D:
			# Scale the line width to match the baked scale
			node.width = node.width * scale_factor
			node.clear_points()
			for point in points:
				node.add_point(point)
	else:
		# Node is a container with ColorRect children (square brush)
		# Remove old squares and create new ones
		for child in node.get_children():
			if child is ColorRect:
				child.queue_free()
		
		# Scale the square size by the scale factor
		var scaled_size = draw_manager.DRAW_SIZE * scale_factor
		var half_size = scaled_size / 2.0
		var shader_mat = stroke_data.get("shader_material", null)
		for point in points:
			var square = ColorRect.new()
			square.size = Vector2(scaled_size, scaled_size)
			square.position = point - Vector2(half_size, half_size)
			square.color = Color.WHITE
			if shader_mat:
				square.material = shader_mat
			node.add_child(square)


func _draw() -> void:
	if not is_active:
		return
	
	# Draw current transform mode indicator at top of screen
	var mode_text = get_mode_name()
	var mode_color = Color.WHITE
	match current_transform_mode:
		TransformMode.MOVE:
			mode_color = Color(0.2, 0.8, 0.2)  # Green
		TransformMode.RESIZE:
			mode_color = Color(0.2, 0.6, 1.0)  # Blue
		TransformMode.ROTATE:
			mode_color = Color(1.0, 0.6, 0.2)  # Orange
	
	# Draw mode indicator circle near selected object
	if selected_body != null and is_instance_valid(selected_body):
		var indicator_pos = to_local(selected_body.global_position) + Vector2(0, -40)
		draw_circle(indicator_pos, 8.0, mode_color)
		# Draw mode-specific icon
		match current_transform_mode:
			TransformMode.MOVE:
				# Draw arrows
				draw_line(indicator_pos + Vector2(-6, 0), indicator_pos + Vector2(6, 0), Color.WHITE, 2.0)
				draw_line(indicator_pos + Vector2(0, -6), indicator_pos + Vector2(0, 6), Color.WHITE, 2.0)
			TransformMode.RESIZE:
				# Draw diagonal arrows
				draw_line(indicator_pos + Vector2(-5, 5), indicator_pos + Vector2(5, -5), Color.WHITE, 2.0)
			TransformMode.ROTATE:
				# Draw arc
				draw_arc(indicator_pos, 5.0, 0, PI * 1.5, 8, Color.WHITE, 2.0)
	
	# Draw selection highlight around selected body
	if selected_body != null and is_instance_valid(selected_body):
		# Draw a highlight circle at the body's center
		var local_pos = to_local(selected_body.global_position)
		var ring_color = Color.GREEN if not selected_is_static else Color(0.2, 0.8, 0.5)  # Teal for static
		draw_circle(local_pos, 15.0, highlight_color)
		draw_arc(local_pos, 18.0, 0, TAU, 32, ring_color, 2.0)
		if selected_is_static:
			# Extra ring for static bodies
			draw_arc(local_pos, 22.0, 0, TAU, 32, ring_color, 1.0)
	
	# Draw selection highlight around selected stroke
	if selected_preview_node != null and is_instance_valid(selected_preview_node):
		# Draw highlight around the stroke's bounding area
		if selected_preview_node is Line2D:
			var line = selected_preview_node as Line2D
			for i in range(line.get_point_count()):
				var point = line.get_point_position(i)
				var global_point = line.to_global(point)
				var local_point = to_local(global_point)
				draw_circle(local_point, 10.0, highlight_color)
		else:
			# Container with ColorRects
			for child in selected_preview_node.get_children():
				if child is ColorRect:
					var center = child.position + child.size / 2.0
					var global_point = selected_preview_node.to_global(center)
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
