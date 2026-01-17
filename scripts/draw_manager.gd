extends Node2D
## Manages drawing objects with the cursor and converting them to physics objects
## Uses proximity-based merging - any strokes with points close together merge into one body

const DRAW_SIZE: float = 16.0  # Size/width of the brush stroke
const MIN_DRAW_DISTANCE: float = 4.0  # Distance between draw points for smooth brush
const MERGE_DISTANCE: float = 24.0  # Distance threshold for merging strokes

@export var wood_texture: Texture2D

# Shader for world-space UV mapping
var world_uv_shader: Shader = null
var wood_material: ShaderMaterial = null

# All drawn points (flat list - we group them at conversion time)
var all_points: Array[Vector2] = []
var last_draw_position: Vector2 = Vector2.ZERO
var brush_line: Line2D = null  # Single Line2D for all preview
var is_currently_drawing: bool = false


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
		return
	
	# Check if B is pressed or mouse left button is pressed for drawing
	var is_drawing = Input.is_key_pressed(KEY_B) or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	
	if is_drawing:
		var draw_pos = cursor.global_position
		
		if not is_currently_drawing:
			# Starting to draw
			is_currently_drawing = true
			add_brush_point(draw_pos)
			last_draw_position = draw_pos
		else:
			# Continue drawing
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
			is_currently_drawing = false


func add_brush_point(pos: Vector2) -> void:
	all_points.append(pos)
	update_preview_line()


func update_preview_line() -> void:
	if brush_line == null:
		brush_line = Line2D.new()
		brush_line.width = DRAW_SIZE
		brush_line.default_color = Color(1.0, 1.0, 1.0, 1.0)  # White - shader handles color
		brush_line.joint_mode = Line2D.LINE_JOINT_ROUND
		brush_line.begin_cap_mode = Line2D.LINE_CAP_ROUND
		brush_line.end_cap_mode = Line2D.LINE_CAP_ROUND
		brush_line.antialiased = true
		# Use world-space UV shader material
		brush_line.material = wood_material
		get_parent().add_child(brush_line)
	
	# Clear and rebuild - simple approach for preview
	brush_line.clear_points()
	for point in all_points:
		brush_line.add_point(point)


func _on_cursor_mode_changed(active: bool) -> void:
	if not active:
		is_currently_drawing = false
		
		if all_points.size() > 0:
			convert_points_to_physics()


func convert_points_to_physics() -> void:
	# Remove preview line
	if brush_line:
		brush_line.queue_free()
		brush_line = null
	
	if all_points.is_empty():
		return
	
	# Group points by proximity using union-find
	var groups = group_points_by_proximity()
	
	# Create a physics body for each group
	for group in groups:
		if group.size() > 0:
			create_physics_body_for_points(group)
	
	all_points.clear()


func group_points_by_proximity() -> Array:
	# Union-Find to group points that are within MERGE_DISTANCE of each other
	var n = all_points.size()
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
			if all_points[i].distance_to(all_points[j]) <= MERGE_DISTANCE:
				unite.call(i, j)
	
	# Collect groups
	var group_map: Dictionary = {}
	for i in range(n):
		var root = find.call(i)
		if not group_map.has(root):
			group_map[root] = []
		group_map[root].append(all_points[i])
	
	return group_map.values()


func create_physics_body_for_points(points: Array) -> void:
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
	
	# Create circle collision for each point
	for point in points:
		var collision = CollisionShape2D.new()
		var shape = CircleShape2D.new()
		shape.radius = DRAW_SIZE / 2.0
		collision.shape = shape
		collision.position = point - center
		physics_body.add_child(collision)
	
	# Create visual using Line2D with world-space UV shader
	var visual_line = Line2D.new()
	visual_line.width = DRAW_SIZE
	visual_line.default_color = Color(1.0, 1.0, 1.0, 1.0)  # White - shader handles color
	visual_line.joint_mode = Line2D.LINE_JOINT_ROUND
	visual_line.begin_cap_mode = Line2D.LINE_CAP_ROUND
	visual_line.end_cap_mode = Line2D.LINE_CAP_ROUND
	visual_line.antialiased = true
	
	# Use world-space UV shader - texture aligns across all drawn objects
	visual_line.material = wood_material
	
	# Add points relative to center
	for point in points:
		visual_line.add_point(point - center)
	
	physics_body.add_child(visual_line)
	get_parent().add_child(physics_body)
	get_parent().add_child(physics_body)
