extends Node2D
## Manages drawing objects with the cursor and converting them to physics objects
## Uses proximity-based merging - any strokes with points close together merge into one body
## Supports merging new strokes with existing physics objects

const DRAW_SIZE: float = 16.0  # Size/width of the brush stroke
const MIN_DRAW_DISTANCE: float = 4.0  # Distance between draw points for smooth brush
const MERGE_DISTANCE: float = 24.0  # Distance threshold for merging strokes

@export var wood_texture: Texture2D

# Shader for world-space UV mapping
var world_uv_shader: Shader = null
var wood_material: ShaderMaterial = null

# Strokes - each stroke is a separate continuous line
var all_strokes: Array = []  # Array of Array[Vector2] - each inner array is one stroke
var current_stroke: Array[Vector2] = []  # The stroke currently being drawn
var last_draw_position: Vector2 = Vector2.ZERO
var preview_lines: Array[Line2D] = []  # One Line2D per stroke for preview
var current_preview_line: Line2D = null  # Line2D for the current stroke being drawn
var is_currently_drawing: bool = false

# Track all existing drawn physics bodies for merging
var existing_drawn_bodies: Array[RigidBody2D] = []


func _ready() -> void:
	# Load wood texture
	wood_texture = load("res://assets/Textures/SBS - Tiny Texture Pack 2 - 256x256/256x256/Wood/Wood_01-256x256.png")
	
	# Load and setup world-space UV shader
	world_uv_shader = load("res://shaders/world_uv_line.gdshader")
	wood_material = ShaderMaterial.new()
	wood_material.shader = world_uv_shader
	wood_material.set_shader_parameter("wood_texture", wood_texture)
	wood_material.set_shader_parameter("texture_scale", 0.02)  # Adjust for texture size
	wood_material.set_shader_parameter("tint_color", Color(1.0, 1.0, 1.0, 1.0))
	
	# Find cursor and connect to its signal
	await get_tree().process_frame
	var cursor = get_tree().get_first_node_in_group("cursor")
	if cursor:
		cursor.cursor_mode_changed.connect(_on_cursor_mode_changed)


func _process(_delta: float) -> void:
	var cursor = get_tree().get_first_node_in_group("cursor")
	if cursor == null or not cursor.is_cursor_active():
		# Clear any merge highlights when cursor is inactive
		clear_merge_highlights()
		return
	
	# Update merge preview highlights
	update_merge_highlights()
	
	# Check if B is pressed or mouse left button is pressed for drawing
	var is_drawing = Input.is_key_pressed(KEY_B) or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	
	if is_drawing:
		var draw_pos = cursor.global_position
		
		if not is_currently_drawing:
			# Starting a new stroke
			is_currently_drawing = true
			current_stroke = []
			start_new_stroke_preview()
			add_brush_point(draw_pos)
			last_draw_position = draw_pos
		else:
			# Continue drawing current stroke
			var distance = draw_pos.distance_to(last_draw_position)
			if distance >= MIN_DRAW_DISTANCE:
				var steps = max(1, int(distance / MIN_DRAW_DISTANCE))
				for i in range(1, steps + 1):
					var t = float(i) / float(steps)
					var interp_pos = last_draw_position.lerp(draw_pos, t)
					add_brush_point(interp_pos)
				last_draw_position = draw_pos
	else:
		if is_currently_drawing:
			# Finished this stroke - save it
			if current_stroke.size() > 0:
				all_strokes.append(current_stroke.duplicate())
				# Keep the preview line for this finished stroke
				if current_preview_line != null:
					preview_lines.append(current_preview_line)
					current_preview_line = null
			current_stroke = []
			is_currently_drawing = false


func start_new_stroke_preview() -> void:
	current_preview_line = Line2D.new()
	current_preview_line.width = DRAW_SIZE
	current_preview_line.default_color = Color(1.0, 1.0, 1.0, 1.0)
	current_preview_line.joint_mode = Line2D.LINE_JOINT_ROUND
	current_preview_line.begin_cap_mode = Line2D.LINE_CAP_ROUND
	current_preview_line.end_cap_mode = Line2D.LINE_CAP_ROUND
	current_preview_line.antialiased = true
	current_preview_line.material = wood_material
	get_parent().add_child(current_preview_line)


func add_brush_point(pos: Vector2) -> void:
	current_stroke.append(pos)
	update_current_preview_line()


func update_current_preview_line() -> void:
	if current_preview_line == null:
		return
	
	# Add the latest point to the current stroke's preview line
	if current_stroke.size() > 0:
		var last_point = current_stroke[current_stroke.size() - 1]
		current_preview_line.add_point(last_point)


func _on_cursor_mode_changed(active: bool) -> void:
	if not active:
		# Finish current stroke if drawing
		if is_currently_drawing and current_stroke.size() > 0:
			all_strokes.append(current_stroke.duplicate())
		is_currently_drawing = false
		current_stroke = []
		
		if all_strokes.size() > 0:
			convert_strokes_to_physics()


func convert_strokes_to_physics() -> void:
	# Remove all preview lines
	for line in preview_lines:
		if is_instance_valid(line):
			line.queue_free()
	preview_lines.clear()
	
	if current_preview_line != null:
		current_preview_line.queue_free()
		current_preview_line = null
	
	if all_strokes.is_empty():
		return
	
	# Clean up any freed bodies from the tracking list
	existing_drawn_bodies = existing_drawn_bodies.filter(func(body): return is_instance_valid(body))
	
	# Determine which WHOLE strokes should merge with which bodies
	# If ANY point in a stroke is near a body, the ENTIRE stroke merges with it
	var strokes_to_merge_with_bodies: Dictionary = {}  # body -> Array of strokes
	var remaining_strokes: Array = []
	
	for stroke in all_strokes:
		var target_body: RigidBody2D = null
		
		# Check if any point in this stroke is near an existing body
		for point in stroke:
			for body in existing_drawn_bodies:
				if not is_instance_valid(body):
					continue
				if is_point_near_body(point, body):
					target_body = body
					break
			if target_body != null:
				break
		
		if target_body != null:
			# This entire stroke merges with the body
			if not strokes_to_merge_with_bodies.has(target_body):
				strokes_to_merge_with_bodies[target_body] = []
			strokes_to_merge_with_bodies[target_body].append(stroke)
		else:
			# This stroke doesn't merge with any existing body
			remaining_strokes.append(stroke)
	
	# Merge whole strokes into existing bodies
	for body in strokes_to_merge_with_bodies:
		merge_strokes_into_body(strokes_to_merge_with_bodies[body], body)
	
	# For remaining strokes, group by proximity and create new bodies
	if remaining_strokes.size() > 0:
		# Flatten remaining strokes into points for proximity grouping
		var remaining_points: Array[Vector2] = []
		for stroke in remaining_strokes:
			for point in stroke:
				remaining_points.append(point)
		
		# Group remaining points by proximity using union-find
		var groups = group_points_by_proximity(remaining_points)
		
		# Create a physics body for each group
		for group in groups:
			if group.size() > 0:
				create_physics_body_for_points(group, remaining_strokes)
	
	all_strokes.clear()


func is_point_near_body(point: Vector2, body: RigidBody2D) -> bool:
	# Check if point is within MERGE_DISTANCE of any collision shape center
	# Use to_global() to properly account for body rotation
	for child in body.get_children():
		if child is CollisionShape2D:
			var shape_world_pos = body.to_global(child.position)
			if point.distance_to(shape_world_pos) <= MERGE_DISTANCE:
				return true
	return false


func merge_strokes_into_body(strokes: Array, body: RigidBody2D) -> void:
	# Merge complete strokes into an existing body
	if strokes.is_empty() or not is_instance_valid(body):
		return
	
	for stroke in strokes:
		if stroke.is_empty():
			continue
		
		# Add collision shapes for all points in the stroke
		for point in stroke:
			var collision = CollisionShape2D.new()
			var shape = CircleShape2D.new()
			shape.radius = DRAW_SIZE / 2.0
			collision.shape = shape
			collision.position = body.to_local(point)
			body.add_child(collision)
		
		# Add a Line2D visual for this entire stroke
		var visual_line = Line2D.new()
		visual_line.width = DRAW_SIZE
		visual_line.default_color = Color(1.0, 1.0, 1.0, 1.0)
		visual_line.joint_mode = Line2D.LINE_JOINT_ROUND
		visual_line.begin_cap_mode = Line2D.LINE_CAP_ROUND
		visual_line.end_cap_mode = Line2D.LINE_CAP_ROUND
		visual_line.antialiased = true
		visual_line.material = wood_material
		
		# Add all points in stroke order, converted to body's local space
		for point in stroke:
			visual_line.add_point(body.to_local(point))
		
		body.add_child(visual_line)
	
	# Update mass based on total collision count
	var collision_count = 0
	for child in body.get_children():
		if child is CollisionShape2D:
			collision_count += 1
	body.mass = max(1.0, collision_count * 0.1)


func group_points_by_proximity(points: Array[Vector2]) -> Array:
	# Union-Find to group points that are within MERGE_DISTANCE of each other
	var n = points.size()
	if n == 0:
		return []
	
	var parent: Array[int] = []
	parent.resize(n)
	for i in range(n):
		parent[i] = i
	
	# Find with path compression
	var find = func(x: int) -> int:
		var root = x
		while parent[root] != root:
			root = parent[root]
		# Path compression
		while parent[x] != root:
			var next = parent[x]
			parent[x] = root
			x = next
		return root
	
	# Union
	var unite = func(a: int, b: int) -> void:
		var ra = find.call(a)
		var rb = find.call(b)
		if ra != rb:
			parent[ra] = rb
	
	# Group points that are close to each other
	for i in range(n):
		for j in range(i + 1, n):
			if points[i].distance_to(points[j]) <= MERGE_DISTANCE:
				unite.call(i, j)
	
	# Collect groups
	var group_map: Dictionary = {}
	for i in range(n):
		var root = find.call(i)
		if not group_map.has(root):
			group_map[root] = []
		group_map[root].append(points[i])
	
	return group_map.values()


func create_physics_body_for_points(points: Array, strokes: Array) -> void:
	if points.is_empty():
		return
	
	# Create a single RigidBody2D
	var physics_body = RigidBody2D.new()
	physics_body.gravity_scale = 1.0
	physics_body.mass = max(1.0, points.size() * 0.1)
	
	# Calculate center of mass
	var center = Vector2.ZERO
	for point in points:
		center += point
	center /= points.size()
	
	physics_body.global_position = center
	
	# Build a set of points for quick lookup
	var points_set = {}
	for p in points:
		points_set[p] = true
	
	# Create circle collision for each point
	for point in points:
		var collision = CollisionShape2D.new()
		var shape = CircleShape2D.new()
		shape.radius = DRAW_SIZE / 2.0
		collision.shape = shape
		collision.position = point - center
		physics_body.add_child(collision)
	
	# Create separate Line2D for each stroke that has points in this group
	for stroke in strokes:
		var stroke_points_in_group: Array[Vector2] = []
		for point in stroke:
			if points_set.has(point):
				stroke_points_in_group.append(point)
		
		if stroke_points_in_group.size() > 0:
			var visual_line = Line2D.new()
			visual_line.width = DRAW_SIZE
			visual_line.default_color = Color(1.0, 1.0, 1.0, 1.0)
			visual_line.joint_mode = Line2D.LINE_JOINT_ROUND
			visual_line.begin_cap_mode = Line2D.LINE_CAP_ROUND
			visual_line.end_cap_mode = Line2D.LINE_CAP_ROUND
			visual_line.antialiased = true
			visual_line.material = wood_material
			
			# Add points in stroke order
			for point in stroke_points_in_group:
				visual_line.add_point(point - center)
			
			physics_body.add_child(visual_line)
	
	get_parent().add_child(physics_body)
	
	# Track this body for future merging
	existing_drawn_bodies.append(physics_body)


func update_merge_highlights() -> void:
	# Clean up invalid bodies
	existing_drawn_bodies = existing_drawn_bodies.filter(func(body): return is_instance_valid(body))
	
	# Gather all current drawing points (current stroke + finished strokes)
	var all_drawing_points: Array[Vector2] = []
	for point in current_stroke:
		all_drawing_points.append(point)
	for stroke in all_strokes:
		for point in stroke:
			all_drawing_points.append(point)
	
	# Find bodies that could be merged with current drawing
	var bodies_in_range: Array[RigidBody2D] = []
	
	for point in all_drawing_points:
		for body in existing_drawn_bodies:
			if is_point_near_body(point, body) and body not in bodies_in_range:
				bodies_in_range.append(body)
	
	# Update visual highlighting on all bodies (all Line2D children)
	for body in existing_drawn_bodies:
		for child in body.get_children():
			if child is Line2D:
				if body in bodies_in_range:
					# Highlight with a green tint to indicate merge target
					child.default_color = Color(0.7, 1.0, 0.7, 1.0)
				else:
					# Normal white color
					child.default_color = Color(1.0, 1.0, 1.0, 1.0)


func clear_merge_highlights() -> void:
	# Reset all bodies to normal color (all Line2D children)
	for body in existing_drawn_bodies:
		if not is_instance_valid(body):
			continue
		for child in body.get_children():
			if child is Line2D:
				child.default_color = Color(1.0, 1.0, 1.0, 1.0)