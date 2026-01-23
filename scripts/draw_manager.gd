extends Node2D
## Manages drawing objects with the cursor and converting them to physics objects
## Uses LittleBigPlanet-style polygon Boolean operations (merge_polygons, clip_polygons)
## Polygons stored as PackedVector2Array and converted to RigidBody2D with Polygon2D and CollisionPolygon2D

const DRAW_SIZE: float = 16.0  # Size/width of the brush stroke (radius for circle, half-size for square)
const MIN_DRAW_DISTANCE: float = 4.0  # Distance threshold before applying merge (5% of brush diameter)
const MERGE_DISTANCE: float = 12.0  # Distance threshold for merging objects (deprecated - will use polygon overlap instead)
const MIN_POLYGON_AREA: float = 100.0  # Minimum area (in pixels²) for a polygon to be kept - filters out tiny fragments

# Shader for world-space UV mapping
var world_uv_shader: Shader = null

# Current drawing material
var current_draw_material: DrawMaterial = null

# Drawing state - using polygon-based approach
# Each drawn object is a polygon that grows via Boolean merge operations
var current_polygon: PackedVector2Array = PackedVector2Array()  # Currently drawn polygon
var current_polygon_material: DrawMaterial = null  # Material for current polygon
var current_polygon_shader: ShaderMaterial = null  # Shader for current polygon
var current_polygon_is_static: bool = false  # Whether current polygon is static
var current_polygon_brush_shape: String = "circle"  # Brush shape for current polygon
var last_draw_position: Vector2 = Vector2.ZERO
var last_merge_position: Vector2 = Vector2.ZERO  # Last position where we did a merge
var is_currently_drawing: bool = false

# Preview for current polygon being drawn
var current_preview_polygon: Polygon2D = null  # Visual preview of polygon being drawn
var merge_count: int = 0  # Counter for periodic vertex simplification

# Track all existing drawn physics bodies for merging
var existing_drawn_bodies: Array[RigidBody2D] = []  # Dynamic bodies
var existing_static_bodies: Array[StaticBody2D] = []  # Static bodies

# Tool state - only draw when draw tool is active
var is_draw_tool_active: bool = true
var is_draw_static_mode: bool = false  # false = dynamic (RigidBody2D), true = static (StaticBody2D)
var is_eraser_tool_active: bool = false  # true when eraser tool is selected

# Eraser state
var current_eraser_polygon: PackedVector2Array = PackedVector2Array()  # Current eraser polygon
var is_currently_erasing: bool = false

# Brush shape state
var current_brush_shape: String = "circle"  # "circle" or "square"

# Layer system
var current_layer: int = 1  # Current active layer (1 = front, 2 = back)
var show_other_layers: bool = true  # Whether to show other layers
const LAYER_1_COLLISION_BIT: int = 0  # Collision layer bit for layer 1
const LAYER_2_COLLISION_BIT: int = 1  # Collision layer bit for layer 2
const GROUND_COLLISION_BIT: int = 2  # Collision layer bit for ground

# Debug visualization
var debug_draw_collisions: bool = false

# Physics pause state
var is_physics_paused: bool = false
var frozen_bodies_state: Dictionary = {}  # body -> { gravity_scale, linear_velocity, angular_velocity }


func _ready() -> void:
	# Add to group so other nodes can find us
	add_to_group("draw_manager")
	
	# Load world-space UV shader
	world_uv_shader = load("res://shaders/world_uv_line.gdshader")
	
	# Find cursor and connect to its signal
	await get_tree().process_frame
	var cursor = get_tree().get_first_node_in_group("cursor")
	if cursor:
		cursor.cursor_mode_changed.connect(_on_cursor_mode_changed)
	
	# Connect to tool UI
	var cursor_ui = get_tree().get_first_node_in_group("cursor_mode_ui")
	if cursor_ui:
		cursor_ui.tool_changed.connect(_on_tool_changed)
		cursor_ui.material_changed.connect(_on_material_changed)
		cursor_ui.physics_paused.connect(_on_physics_paused)
		cursor_ui.brush_shape_changed.connect(_on_brush_shape_changed)
		cursor_ui.layer_changed.connect(_on_layer_changed)
		cursor_ui.show_other_layers_changed.connect(_on_show_other_layers_changed)
		# Get initial values
		if cursor_ui.get_current_material() != null:
			_on_material_changed(cursor_ui.get_current_material())
		current_brush_shape = cursor_ui.get_current_brush_shape()
		current_layer = cursor_ui.get_current_layer()


func _on_physics_paused(paused: bool) -> void:
	is_physics_paused = paused
	
	# Clean up invalid bodies first
	existing_drawn_bodies = existing_drawn_bodies.filter(func(body): return is_instance_valid(body))
	
	if paused:
		# Freeze all dynamic bodies - store their state including transform
		frozen_bodies_state.clear()
		for body in existing_drawn_bodies:
			if is_instance_valid(body):
				frozen_bodies_state[body] = {
					"gravity_scale": body.gravity_scale,
					"linear_velocity": body.linear_velocity,
					"angular_velocity": body.angular_velocity,
					"scale": body.scale,
					"rotation": body.rotation,
					"position": body.global_position
				}
				body.freeze_mode = RigidBody2D.FREEZE_MODE_STATIC
				body.freeze = true
	else:
		# Unfreeze all dynamic bodies - restore their state
		for body in existing_drawn_bodies:
			if is_instance_valid(body) and frozen_bodies_state.has(body):
				var state = frozen_bodies_state[body]
				# Store current transform (may have been modified while paused)
				var current_scale = body.scale
				var current_rotation = body.rotation
				var current_position = body.global_position
				
				body.freeze = false
				body.freeze_mode = RigidBody2D.FREEZE_MODE_KINEMATIC
				body.gravity_scale = state["gravity_scale"]
				# Restore velocities for continuity
				body.linear_velocity = state["linear_velocity"]
				body.angular_velocity = state["angular_velocity"]
				
				# Preserve the current transform (don't reset to original)
				body.scale = current_scale
				body.rotation = current_rotation
				body.global_position = current_position
			# Also unfreeze bodies that weren't in frozen state (created while paused)
			elif is_instance_valid(body) and body.freeze:
				body.freeze = false
				body.freeze_mode = RigidBody2D.FREEZE_MODE_KINEMATIC
		frozen_bodies_state.clear()


func _on_material_changed(material: DrawMaterial) -> void:
	current_draw_material = material


func _on_brush_shape_changed(shape: String) -> void:
	current_brush_shape = shape


func _on_layer_changed(layer_number: int) -> void:
	current_layer = layer_number
	update_layer_visibility()


func _on_show_other_layers_changed(show_layers: bool) -> void:
	show_other_layers = show_layers
	update_layer_visibility()


func update_layer_visibility() -> void:
	"""Update visibility/transparency of all layers based on current settings"""
	# Update preview polygon if currently drawing
	if current_preview_polygon != null and is_instance_valid(current_preview_polygon):
		apply_layer_modulation(current_preview_polygon, current_layer)
	
	# Update physics bodies
	for body in existing_drawn_bodies:
		if is_instance_valid(body):
			var body_layer = body.get_meta("layer", 1)
			apply_layer_modulation(body, body_layer)
	
	for body in existing_static_bodies:
		if is_instance_valid(body):
			var body_layer = body.get_meta("layer", 1)
			apply_layer_modulation(body, body_layer)


func apply_layer_modulation(node: Node, layer: int) -> void:
	"""Apply visual modulation based on layer and visibility settings"""
	var base_modulate = Color.WHITE
	
	# Layer 2 (back) gets darker tint
	if layer == 2:
		base_modulate = Color(0.6, 0.6, 0.6, 1.0)
	
	# If not showing other layers, make non-active layers transparent
	if not show_other_layers and layer != current_layer:
		base_modulate.a = 0.25
	
	# Apply to the node itself
	if node is CanvasItem:
		node.modulate = base_modulate
	
	# Apply to Polygon2D children
	for child in node.get_children():
		if child is Polygon2D:
			var polygon = child as Polygon2D
			polygon.modulate = base_modulate
			# If it has a shader material, update the tint parameter
			if polygon.material is ShaderMaterial:
				var shader_mat = polygon.material as ShaderMaterial
				shader_mat.set_shader_parameter("tint_color", base_modulate)
		# Legacy support for Line2D and ColorRect (from old system)
		elif child is Line2D:
			var line = child as Line2D
			line.modulate = base_modulate
			if line.material is ShaderMaterial:
				var shader_mat = line.material as ShaderMaterial
				shader_mat.set_shader_parameter("tint_color", base_modulate)
		elif child is ColorRect:
			var rect = child as ColorRect
			rect.modulate = base_modulate
			if rect.material is ShaderMaterial:
				var shader_mat = rect.material as ShaderMaterial
				shader_mat.set_shader_parameter("tint_color", base_modulate)


func create_shader_material_for(material: DrawMaterial, layer: int = 1) -> ShaderMaterial:
	# Create a NEW shader material instance for the given material
	var shader_mat = ShaderMaterial.new()
	shader_mat.shader = world_uv_shader
	if material != null and material.texture != null:
		shader_mat.set_shader_parameter("wood_texture", material.texture)
	shader_mat.set_shader_parameter("texture_scale", 0.02)
	
	# Calculate tint based on material and layer
	var base_tint = Color.WHITE
	if material != null:
		base_tint = material.tint
	
	# Apply layer tint (Layer 2 gets darker)
	if layer == 2:
		base_tint = base_tint * Color(0.6, 0.6, 0.6, 1.0)
	
	shader_mat.set_shader_parameter("tint_color", base_tint)
	return shader_mat


func _on_tool_changed(tool_name: String) -> void:
	is_draw_tool_active = (tool_name == "draw_dynamic" or tool_name == "draw_static")
	is_draw_static_mode = (tool_name == "draw_static")
	is_eraser_tool_active = (tool_name == "eraser")
	
	# If switching away from draw tool mid-drawing, finish the polygon
	if not is_draw_tool_active and is_currently_drawing:
		finish_current_polygon()
		is_currently_drawing = false


func create_brush_polygon(center: Vector2, brush_shape: String) -> PackedVector2Array:
	"""Creates a brush polygon (circle or square) at the given position"""
	var polygon = PackedVector2Array()
	var radius = DRAW_SIZE / 2.0
	
	if brush_shape == "square":
		# Create axis-aligned square
		polygon.append(center + Vector2(-radius, -radius))
		polygon.append(center + Vector2(radius, -radius))
		polygon.append(center + Vector2(radius, radius))
		polygon.append(center + Vector2(-radius, radius))
	else:  # circle
		# Create circle approximation with 96 vertices for ultra-smooth blending
		var segments = 96
		for i in range(segments):
			var angle = (float(i) / segments) * TAU
			polygon.append(center + Vector2(cos(angle), sin(angle)) * radius)
	
	return polygon


func merge_brush_into_polygon(polygon: PackedVector2Array, brush_pos: Vector2, brush_shape: String) -> PackedVector2Array:
	"""Merges a brush polygon into the existing polygon using Geometry2D.merge_polygons"""
	if polygon.size() == 0:
		# First brush - just return the brush polygon
		return create_brush_polygon(brush_pos, brush_shape)
	
	var brush_polygon = create_brush_polygon(brush_pos, brush_shape)
	var merged = Geometry2D.merge_polygons(polygon, brush_polygon)
	
	# merge_polygons returns an array of polygons - take the first (largest) one
	if merged.size() > 0:
		return merged[0]
	
	return polygon


func clip_brush_from_polygon(polygon: PackedVector2Array, brush_pos: Vector2, brush_shape: String) -> Array:
	"""Clips a brush polygon from the existing polygon using Geometry2D.clip_polygons"""
	if polygon.size() == 0:
		return []
	
	var brush_polygon = create_brush_polygon(brush_pos, brush_shape)
	var clipped = Geometry2D.clip_polygons(polygon, brush_polygon)
	
	# clip_polygons returns an array of remaining polygons after subtraction
	return clipped


func simplify_polygon(polygon: PackedVector2Array) -> PackedVector2Array:
	"""Simplifies a polygon by removing redundant vertices using Ramer-Douglas-Peucker algorithm"""
	if polygon.size() < 4:
		return polygon
	
	# Use epsilon for simplification tolerance (in pixels)
	var epsilon = 0.5  # Higher = more simplification, lower = more accurate
	
	return ramer_douglas_peucker(polygon, epsilon)


func ramer_douglas_peucker(points: PackedVector2Array, epsilon: float) -> PackedVector2Array:
	"""Implements the Ramer-Douglas-Peucker algorithm for polygon simplification"""
	if points.size() < 3:
		return points
	
	# Find the point with maximum distance from line between first and last
	var dmax = 0.0
	var index = 0
	var end = points.size() - 1
	
	for i in range(1, end):
		var d = perpendicular_distance(points[i], points[0], points[end])
		if d > dmax:
			index = i
			dmax = d
	
	# If max distance is greater than epsilon, recursively simplify
	if dmax > epsilon:
		# Recursive call
		var rec_results1 = ramer_douglas_peucker(points.slice(0, index + 1), epsilon)
		var rec_results2 = ramer_douglas_peucker(points.slice(index), epsilon)
		
		# Build result list
		var result = PackedVector2Array()
		for i in range(rec_results1.size() - 1):
			result.append(rec_results1[i])
		for i in range(rec_results2.size()):
			result.append(rec_results2[i])
		
		return result
	else:
		# All points between first and last can be discarded
		return PackedVector2Array([points[0], points[end]])


func perpendicular_distance(point: Vector2, line_start: Vector2, line_end: Vector2) -> float:
	"""Calculates the perpendicular distance from a point to a line"""
	var dx = line_end.x - line_start.x
	var dy = line_end.y - line_start.y
	
	# Handle degenerate case where line_start == line_end
	if dx == 0 and dy == 0:
		return point.distance_to(line_start)
	
	# Calculate distance using the cross product formula
	var numerator = abs(dy * point.x - dx * point.y + line_end.x * line_start.y - line_end.y * line_start.x)
	var denominator = sqrt(dx * dx + dy * dy)
	
	return numerator / denominator


func _process(_delta: float) -> void:
	var cursor = get_tree().get_first_node_in_group("cursor")
	if cursor == null or not cursor.is_cursor_active():
		# Clear any merge highlights when cursor is inactive
		clear_merge_highlights()
		# Still update debug draw
		if debug_draw_collisions:
			queue_redraw()
		return
	
	# Check if mouse is over UI
	var is_mouse_over_ui = is_mouse_over_gui()
	
	# Check if B is pressed or mouse left button is pressed
	var is_action_pressed = Input.is_key_pressed(KEY_B) or (Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and not is_mouse_over_ui)
	
	# Handle eraser tool
	if is_eraser_tool_active:
		process_eraser_polygon(cursor, is_action_pressed)
		if debug_draw_collisions:
			queue_redraw()
		return
	
	# Only process drawing when draw tool is active
	if not is_draw_tool_active:
		clear_merge_highlights()
		# Still update debug draw
		if debug_draw_collisions:
			queue_redraw()
		return
	
	# Update merge preview highlights
	update_merge_highlights()
	
	if is_action_pressed:
		var draw_pos = cursor.global_position
		
		if not is_currently_drawing:
			# Starting a new polygon - capture current material and static mode
			is_currently_drawing = true
			current_polygon = PackedVector2Array()
			current_polygon_material = current_draw_material
			current_polygon_shader = create_shader_material_for(current_draw_material, current_layer)
			current_polygon_is_static = is_draw_static_mode
			current_polygon_brush_shape = current_brush_shape
			last_draw_position = draw_pos
			last_merge_position = draw_pos
			merge_count = 0
			start_new_polygon_preview()
			
			# Create initial brush polygon
			current_polygon = create_brush_polygon(draw_pos, current_polygon_brush_shape)
			update_polygon_preview()
		else:
			# Continue drawing current polygon
			var distance_since_last_merge = draw_pos.distance_to(last_merge_position)
			var merge_threshold = DRAW_SIZE * 0.15  # 15% of brush diameter for ultra-smooth strokes
			
			if distance_since_last_merge >= merge_threshold:
				# Calculate how many steps needed to ensure continuous coverage
				# Use brush diameter * 0.35 as max step for maximum overlap and smoothness
				var max_step = DRAW_SIZE * 0.35
				var steps = max(1, int(ceil(distance_since_last_merge / max_step)))
				
				# Interpolate and merge at each step to prevent gaps
				for i in range(1, steps + 1):
					var t = float(i) / float(steps)
					var interp_pos = last_merge_position.lerp(draw_pos, t)
					current_polygon = merge_brush_into_polygon(current_polygon, interp_pos, current_polygon_brush_shape)
					merge_count += 1
				
				last_merge_position = draw_pos
				
				# Simplify every 50 merges to reduce vertex count while preserving smoothness
				if merge_count % 50 == 0:
					current_polygon = simplify_polygon(current_polygon)
				
				update_polygon_preview()
			
			last_draw_position = draw_pos
	else:
		if is_currently_drawing:
			# Finished drawing this polygon
			finish_current_polygon()
			is_currently_drawing = false
	
	# Update debug draw
	if debug_draw_collisions:
		queue_redraw()


func process_eraser_polygon(cursor: Node, is_action_pressed: bool) -> void:
	"""Process eraser tool - uses clip_polygons to remove intersecting parts"""
	var draw_pos = cursor.get_global_position()
	
	if is_action_pressed:
		if not is_currently_erasing:
			is_currently_erasing = true
			last_draw_position = draw_pos
		
		# Apply eraser at current position
		var distance = last_draw_position.distance_to(draw_pos)
		if distance >= MIN_DRAW_DISTANCE:
			erase_at_point_polygon(draw_pos)
			last_draw_position = draw_pos
	else:
		if is_currently_erasing:
			is_currently_erasing = false


func erase_at_point_polygon(erase_pos: Vector2) -> void:
	"""Erase objects at a specific point using polygon clipping"""
	var erase_brush = create_brush_polygon(erase_pos, current_brush_shape)
	
	# Erase from physics bodies on the current layer
	var bodies_to_check = []
	
	for body in existing_drawn_bodies:
		if is_instance_valid(body):
			var body_layer = body.get_meta("layer", 1)
			if body_layer == current_layer:
				bodies_to_check.append(body)
	
	for body in existing_static_bodies:
		if is_instance_valid(body):
			var body_layer = body.get_meta("layer", 1)
			if body_layer == current_layer:
				bodies_to_check.append(body)
	
	for body in bodies_to_check:
		erase_from_body_polygon(body, erase_brush)


func erase_from_body_polygon(body: Node2D, erase_brush: PackedVector2Array) -> void:
	"""Clips the erase brush from the body's polygon"""
	# Find the Polygon2D and CollisionPolygon2D
	var visual_polygon: Polygon2D = null
	var collision_polygon: CollisionPolygon2D = null
	
	for child in body.get_children():
		if child is Polygon2D:
			visual_polygon = child
		elif child is CollisionPolygon2D:
			collision_polygon = child
	
	if visual_polygon == null or collision_polygon == null:
		return
	
	# Convert erase brush to body's local space
	var local_erase_brush = PackedVector2Array()
	for point in erase_brush:
		local_erase_brush.append(body.to_local(point))
	
	# Clip the erase brush from the body's polygon
	var current_polygon = visual_polygon.polygon
	var clipped = Geometry2D.clip_polygons(current_polygon, local_erase_brush)
	
	if clipped.size() == 0:
		# Entire body was erased
		body.queue_free()
		if body in existing_drawn_bodies:
			existing_drawn_bodies.erase(body)
		if body in existing_static_bodies:
			existing_static_bodies.erase(body)
	elif clipped.size() == 1:
		# Single polygon remains - update it
		var new_polygon = clipped[0]
		if new_polygon.size() >= 3:
			# Keep polygon as-is without recentering
			visual_polygon.polygon = new_polygon
			
			# Remove all existing collision polygons and recreate with convex decomposition
			for child in body.get_children():
				if child is CollisionPolygon2D:
					child.queue_free()
			
			# Create collision polygons with convex decomposition (no simplification for smooth shapes)
			var convex_polygons = Geometry2D.decompose_polygon_in_convex(new_polygon)
			# Allow more pieces for smooth circular shapes
			if convex_polygons.size() > 24:
				# Too complex - use original polygon as single piece
				var simple_collision = CollisionPolygon2D.new()
				simple_collision.polygon = new_polygon
				simple_collision.build_mode = CollisionPolygon2D.BUILD_SOLIDS
				body.add_child(simple_collision)
			elif convex_polygons.size() > 0:
				for convex_poly in convex_polygons:
					var convex_collision = CollisionPolygon2D.new()
					convex_collision.polygon = convex_poly
					convex_collision.build_mode = CollisionPolygon2D.BUILD_SOLIDS
					body.add_child(convex_collision)
			else:
				# Fallback to original polygon if decomposition fails
				var fallback_collision = CollisionPolygon2D.new()
				fallback_collision.polygon = new_polygon
				fallback_collision.build_mode = CollisionPolygon2D.BUILD_SOLIDS
				body.add_child(fallback_collision)
			
			# Update debug Line2D if it exists
			for child in body.get_children():
				if child is Line2D and child.default_color == Color(1.0, 0.0, 0.0, 1.0):
					child.clear_points()
					for point in new_polygon:
						child.add_point(point)
					child.add_point(new_polygon[0])  # Close the shape
					break
			
			# Update mass if it's a RigidBody2D
			if body is RigidBody2D:
				var area = calculate_polygon_area(new_polygon)
				body.mass = max(5.0, area * 0.02)  # Use updated mass parameters
		else:
			# Polygon too small, remove body
			body.queue_free()
			if body in existing_drawn_bodies:
				existing_drawn_bodies.erase(body)
			if body in existing_static_bodies:
				existing_static_bodies.erase(body)
	else:
		# Multiple polygons remain - keep first in original body, create new bodies for others
		# Get properties from original body
		var body_layer = body.get_meta("layer", 1)
		var body_material = visual_polygon.material
		var is_static = body is StaticBody2D
		
		# Sort polygons by area (largest first)
		var polygon_data = []
		for poly in clipped:
			if poly.size() >= 3:
				var area = calculate_polygon_area(poly)
				# Only keep polygons that meet minimum area threshold
				if area >= MIN_POLYGON_AREA:
					polygon_data.append({"polygon": poly, "area": area})
		
		polygon_data.sort_custom(func(a, b): return a["area"] > b["area"])
		
		if polygon_data.size() > 0:
			# Keep largest piece in original body without recentering
			var largest = polygon_data[0]
			visual_polygon.polygon = largest["polygon"]
			
			# Remove all existing collision polygons and recreate with convex decomposition
			for child in body.get_children():
				if child is CollisionPolygon2D:
					child.queue_free()
			
			# Create collision polygons with convex decomposition (no simplification for smooth shapes)
			var convex_polygons = Geometry2D.decompose_polygon_in_convex(largest["polygon"])
			# Allow more pieces for smooth circular shapes
			if convex_polygons.size() > 24:
				# Too complex - use original polygon as single piece
				var simple_collision = CollisionPolygon2D.new()
				simple_collision.polygon = largest["polygon"]
				simple_collision.build_mode = CollisionPolygon2D.BUILD_SOLIDS
				body.add_child(simple_collision)
			elif convex_polygons.size() > 0:
				for convex_poly in convex_polygons:
					var convex_collision = CollisionPolygon2D.new()
					convex_collision.polygon = convex_poly
					convex_collision.build_mode = CollisionPolygon2D.BUILD_SOLIDS
					body.add_child(convex_collision)
			else:
				# Fallback to original polygon if decomposition fails
				var fallback_collision = CollisionPolygon2D.new()
				fallback_collision.polygon = largest["polygon"]
				fallback_collision.build_mode = CollisionPolygon2D.BUILD_SOLIDS
				body.add_child(fallback_collision)
			
			# Update debug Line2D if it exists
			for child in body.get_children():
				if child is Line2D and child.default_color == Color(1.0, 0.0, 0.0, 1.0):
					child.clear_points()
					for point in largest["polygon"]:
						child.add_point(point)
					child.add_point(largest["polygon"][0])  # Close the shape
					break
			
			# Update mass if it's a RigidBody2D
			if body is RigidBody2D:
				var area = calculate_polygon_area(largest["polygon"])
				body.mass = max(5.0, area * 0.02)  # Use updated mass parameters
			
			# Create new bodies for remaining pieces
			for i in range(1, polygon_data.size()):
				var piece_polygon = polygon_data[i]["polygon"]
				
				# Convert to world space
				var world_polygon = PackedVector2Array()
				for point in piece_polygon:
					world_polygon.append(body.to_global(point))
				
				# Extract material properties
				var piece_material = null
				if body is RigidBody2D and body.physics_material_override != null:
					var phys_mat = body.physics_material_override
					piece_material = DrawMaterial.new()
					piece_material.friction = phys_mat.friction
					piece_material.bounce = phys_mat.bounce
					piece_material.density = body.mass / max(0.1, calculate_polygon_area(visual_polygon.polygon))
				
				create_physics_body_from_polygon(world_polygon, piece_material, body_material, is_static, body_layer)
		else:
			# All pieces too small, remove body
			body.queue_free()
			if body in existing_drawn_bodies:
				existing_drawn_bodies.erase(body)
			if body in existing_static_bodies:
				existing_static_bodies.erase(body)


func start_new_polygon_preview() -> void:
	"""Creates a Polygon2D preview for the polygon being drawn"""
	current_preview_polygon = Polygon2D.new()
	current_preview_polygon.color = Color(1.0, 1.0, 1.0, 0.5)  # Semi-transparent for debugging
	current_preview_polygon.material = current_polygon_shader
	# Set z_index based on layer (Layer 1 = front, Layer 2 = back)
	current_preview_polygon.z_index = 10 if current_layer == 1 else 5
	apply_layer_modulation(current_preview_polygon, current_layer)
	get_parent().add_child(current_preview_polygon)


func update_polygon_preview() -> void:
	"""Updates the preview Polygon2D with the current polygon"""
	if current_preview_polygon != null and current_polygon.size() >= 3:
		current_preview_polygon.polygon = current_polygon


func finish_current_polygon() -> void:
	"""Converts the current polygon to a physics body"""
	if current_polygon.size() < 3:
		# Polygon too small, discard
		if current_preview_polygon != null:
			current_preview_polygon.queue_free()
			current_preview_polygon = null
		current_polygon = PackedVector2Array()
		current_polygon_material = null
		current_polygon_shader = null
		current_polygon_is_static = false
		current_polygon_brush_shape = "circle"
		return
	
	# Final simplification
	current_polygon = simplify_polygon(current_polygon)
	
	# Check if polygon area is too small
	var polygon_area = calculate_polygon_area(current_polygon)
	if polygon_area < MIN_POLYGON_AREA:
		print("Polygon too small (area: ", polygon_area, "), discarding")
		if current_preview_polygon != null:
			current_preview_polygon.queue_free()
			current_preview_polygon = null
		current_polygon = PackedVector2Array()
		current_polygon_material = null
		current_polygon_shader = null
		current_polygon_is_static = false
		current_polygon_brush_shape = "circle"
		return
	
	# Check if this polygon overlaps with existing bodies on the same layer
	var overlapping_bodies = find_overlapping_bodies(current_polygon, current_layer)
	
	if overlapping_bodies.size() > 0:
		# Merge with existing bodies
		merge_polygon_into_bodies(current_polygon, overlapping_bodies)
	else:
		# Create new physics body
		create_physics_body_from_polygon(current_polygon, current_polygon_material, current_polygon_shader, current_polygon_is_static, current_layer)
	
	# Clean up preview
	if current_preview_polygon != null:
		current_preview_polygon.queue_free()
		current_preview_polygon = null
	
	# Reset current polygon state
	current_polygon = PackedVector2Array()
	current_polygon_material = null
	current_polygon_shader = null
	current_polygon_is_static = false
	current_polygon_brush_shape = "circle"


func find_overlapping_bodies(polygon: PackedVector2Array, layer: int) -> Array:
	"""Finds existing bodies that overlap with the given polygon on the specified layer"""
	var overlapping = []
	
	for body in existing_drawn_bodies:
		if not is_instance_valid(body):
			continue
		var body_layer = body.get_meta("layer", 1)
		if body_layer != layer:
			continue
		
		# Check if body has a Polygon2D child to compare with
		for child in body.get_children():
			if child is Polygon2D:
				# Check if polygons intersect
				var body_polygon = child.polygon
				if polygons_overlap(polygon, body_polygon, body.global_position):
					overlapping.append(body)
					break
	
	for body in existing_static_bodies:
		if not is_instance_valid(body):
			continue
		var body_layer = body.get_meta("layer", 1)
		if body_layer != layer:
			continue
		
		# Check if body has a Polygon2D child to compare with
		for child in body.get_children():
			if child is Polygon2D:
				# Check if polygons intersect
				var body_polygon = child.polygon
				if polygons_overlap(polygon, body_polygon, body.global_position):
					overlapping.append(body)
					break
	
	return overlapping


func polygons_overlap(poly_a: PackedVector2Array, poly_b: PackedVector2Array, offset_b: Vector2 = Vector2.ZERO) -> bool:
	"""Checks if two polygons overlap (simple AABB check for performance)"""
	# Calculate AABB for poly_a
	var min_a = poly_a[0]
	var max_a = poly_a[0]
	for point in poly_a:
		min_a.x = min(min_a.x, point.x)
		min_a.y = min(min_a.y, point.y)
		max_a.x = max(max_a.x, point.x)
		max_a.y = max(max_a.y, point.y)
	
	# Calculate AABB for poly_b (with offset)
	var min_b = poly_b[0] + offset_b
	var max_b = poly_b[0] + offset_b
	for point in poly_b:
		var world_point = point + offset_b
		min_b.x = min(min_b.x, world_point.x)
		min_b.y = min(min_b.y, world_point.y)
		max_b.x = max(max_b.x, world_point.x)
		max_b.y = max(max_b.y, world_point.y)
	
	# Check AABB overlap with merge distance tolerance
	var tolerance = MERGE_DISTANCE
	return not (max_a.x + tolerance < min_b.x or max_b.x + tolerance < min_a.x or 
				max_a.y + tolerance < min_b.y or max_b.y + tolerance < min_a.y)


func _on_cursor_mode_changed(active: bool) -> void:
	if not active:
		# Finish current polygon if drawing
		if is_currently_drawing and current_polygon.size() >= 3:
			finish_current_polygon()
		is_currently_drawing = false
		current_polygon = PackedVector2Array()
		current_polygon_material = null
		current_polygon_shader = null
		current_polygon_is_static = false
		current_polygon_brush_shape = "circle"


func create_physics_body_from_polygon(polygon: PackedVector2Array, material: DrawMaterial, shader_mat: ShaderMaterial, is_static: bool, layer: int) -> void:
	"""Creates a RigidBody2D or StaticBody2D with Polygon2D and CollisionPolygon2D from a polygon"""
	if polygon.size() < 3:
		return
	
	# Check minimum area threshold
	var polygon_area = calculate_polygon_area(polygon)
	if polygon_area < MIN_POLYGON_AREA:
		print("Skipping body creation - polygon too small (area: ", polygon_area, ")")
		return
	
	# Calculate center of polygon for positioning
	var center = Vector2.ZERO
	for point in polygon:
		center += point
	center /= polygon.size()
	
	# Convert polygon to local coordinates (relative to center)
	var local_polygon = PackedVector2Array()
	for point in polygon:
		local_polygon.append(point - center)
	
	# Create physics body
	var physics_body: Node2D
	if is_static:
		physics_body = StaticBody2D.new()
	else:
		physics_body = RigidBody2D.new()
		physics_body.gravity_scale = 1.0
		
		# Calculate mass based on polygon area and material density
		var area = calculate_polygon_area(local_polygon)
		var density = 1.0
		if material != null:
			density = material.density
		physics_body.mass = max(5.0, area * density * 0.02)  # Increased minimum mass and density multiplier
		
		# Enable continuous collision detection for stability
		physics_body.continuous_cd = RigidBody2D.CCD_MODE_CAST_SHAPE
		
		# Add damping to reduce excessive motion
		physics_body.linear_damp = 0.5  # Slow down linear motion
		physics_body.angular_damp = 2.0  # Reduce spinning significantly
		
		# Adjust sleep settings for better stability
		physics_body.can_sleep = true
		physics_body.lock_rotation = false
		
		# Set physics material with higher friction for stability
		var phys_mat = PhysicsMaterial.new()
		if material != null:
			phys_mat.friction = max(0.8, material.friction)  # Minimum friction for stability
			phys_mat.bounce = min(0.2, material.bounce)  # Reduce bounciness
		else:
			phys_mat.friction = 0.8
			phys_mat.bounce = 0.1
		physics_body.physics_material_override = phys_mat
	
	physics_body.global_position = center
	
	# Set collision layers
	if layer == 1:
		physics_body.collision_layer = 1 << LAYER_1_COLLISION_BIT  # Bit 0 = value 1
		physics_body.collision_mask = (1 << LAYER_1_COLLISION_BIT) | (1 << GROUND_COLLISION_BIT)  # Bits 0,2 = value 5
	else:  # layer 2
		physics_body.collision_layer = 1 << LAYER_2_COLLISION_BIT  # Bit 1 = value 2
		physics_body.collision_mask = (1 << LAYER_2_COLLISION_BIT) | (1 << GROUND_COLLISION_BIT)  # Bits 1,2 = value 6
	
	print("Created %s body on layer %d - collision_layer: %d collision_mask: %d" % ["static" if is_static else "dynamic", layer, physics_body.collision_layer, physics_body.collision_mask])
	
	# Store layer metadata
	physics_body.set_meta("layer", layer)
	
	# Create CollisionPolygon2D with convex decomposition for stable physics
	var collision_polygon = CollisionPolygon2D.new()
	collision_polygon.polygon = local_polygon
	collision_polygon.build_mode = CollisionPolygon2D.BUILD_SOLIDS
	# Use convex decomposition to break complex concave shapes into stable convex pieces
	var convex_polygons = Geometry2D.decompose_polygon_in_convex(local_polygon)
	# Allow more pieces for smooth circular shapes
	if convex_polygons.size() > 24:
		# Too complex - use original polygon as single piece
		collision_polygon.polygon = local_polygon
		physics_body.add_child(collision_polygon)
	elif convex_polygons.size() > 1:
		# If decomposition produced multiple convex shapes, use them
		collision_polygon.queue_free()
		for convex_poly in convex_polygons:
			var convex_collision = CollisionPolygon2D.new()
			convex_collision.polygon = convex_poly
			convex_collision.build_mode = CollisionPolygon2D.BUILD_SOLIDS
			physics_body.add_child(convex_collision)
	else:
		# Simple polygon, use as-is
		physics_body.add_child(collision_polygon)
	
	# Create Polygon2D for visual
	var visual_polygon = Polygon2D.new()
	visual_polygon.polygon = local_polygon
	visual_polygon.color = Color(1.0, 1.0, 1.0, 0.5)  # Semi-transparent for debugging
	visual_polygon.material = shader_mat
	physics_body.add_child(visual_polygon)
	
	# Create debug Line2D to visualize collision shape
	var debug_line = Line2D.new()
	debug_line.width = 2.0
	debug_line.default_color = Color(1.0, 0.0, 0.0, 1.0)  # Red outline
	debug_line.antialiased = true
	# Add all polygon points plus first point again to close the loop
	for point in local_polygon:
		debug_line.add_point(point)
	debug_line.add_point(local_polygon[0])  # Close the shape
	physics_body.add_child(debug_line)
	
	get_parent().add_child(physics_body)
	
	# Set z_index based on layer (Layer 1 = front, Layer 2 = back)
	physics_body.z_index = 10 if layer == 1 else 5
	
	# Apply layer visual modulation
	apply_layer_modulation(physics_body, layer)
	
	# If physics is paused, freeze this body immediately
	if is_physics_paused and not is_static:
		physics_body.freeze_mode = RigidBody2D.FREEZE_MODE_STATIC
		physics_body.freeze = true
	
	# Track this body for future operations
	if is_static:
		existing_static_bodies.append(physics_body)
	else:
		existing_drawn_bodies.append(physics_body)


func calculate_polygon_area(polygon: PackedVector2Array) -> float:
	"""Calculates the area of a polygon using the shoelace formula"""
	if polygon.size() < 3:
		return 0.0
	
	var area = 0.0
	var n = polygon.size()
	for i in range(n):
		var j = (i + 1) % n
		area += polygon[i].x * polygon[j].y
		area -= polygon[j].x * polygon[i].y
	
	return abs(area) / 2.0


func merge_polygon_into_bodies(polygon: PackedVector2Array, bodies: Array) -> void:
	"""Merges a new polygon into one or more existing bodies using Boolean operations"""
	if bodies.size() == 0:
		return
	
	# For now, merge into the first body (simple case)
	# TODO: Handle merging multiple bodies together
	var target_body = bodies[0]
	
	if not is_instance_valid(target_body):
		return
	
	# Find the Polygon2D and CollisionPolygon2D in the target body
	var visual_polygon: Polygon2D = null
	var collision_polygon: CollisionPolygon2D = null
	
	for child in target_body.get_children():
		if child is Polygon2D:
			visual_polygon = child
		elif child is CollisionPolygon2D:
			collision_polygon = child
	
	if visual_polygon == null or collision_polygon == null:
		print("Warning: Target body missing Polygon2D or CollisionPolygon2D")
		return
	
	# Convert new polygon to target body's local space
	var local_polygon = PackedVector2Array()
	for point in polygon:
		local_polygon.append(target_body.to_local(point))
	
	# Merge the polygons
	var current_body_polygon = visual_polygon.polygon
	var merged = Geometry2D.merge_polygons(current_body_polygon, local_polygon)
	
	if merged.size() > 0:
		var new_polygon = merged[0]
		
		# Update visual and collision polygons
		visual_polygon.polygon = new_polygon
		collision_polygon.polygon = new_polygon
		
		# Update mass if it's a RigidBody2D
		if target_body is RigidBody2D:
			var area = calculate_polygon_area(new_polygon)
			var density = 1.0
			if current_polygon_material != null:
				density = current_polygon_material.density
			target_body.mass = max(1.0, area * density * 0.01)


func convert_strokes_to_physics() -> void:
	# Deprecated - old stroke-based system
	# Kept for compatibility but does nothing
	pass


func create_collision_shape_for_brush(brush_shape: String, brush_scale: float = 1.0) -> Shape2D:
	## Creates the appropriate collision shape based on brush type
	var scaled_size = DRAW_SIZE * brush_scale
	var half_size = scaled_size / 2.0
	if brush_shape == "square":
		var rect_shape = RectangleShape2D.new()
		rect_shape.size = Vector2(scaled_size, scaled_size)
		return rect_shape
	else:  # Default to circle
		var circle_shape = CircleShape2D.new()
		circle_shape.radius = half_size
		return circle_shape


func configure_line2d_for_brush(line: Line2D, brush_shape: String) -> void:
	## Configures Line2D cap and joint modes based on brush shape
	## Note: For circles only - squares use create_square_visuals instead
	line.joint_mode = Line2D.LINE_JOINT_ROUND
	line.begin_cap_mode = Line2D.LINE_CAP_ROUND
	line.end_cap_mode = Line2D.LINE_CAP_ROUND


func create_square_visuals(points: Array, shader_mat: ShaderMaterial, parent: Node) -> void:
	## Creates axis-aligned square sprites for each point (for square brush)
	var half_size = DRAW_SIZE / 2.0
	for point in points:
		var square = ColorRect.new()
		square.size = Vector2(DRAW_SIZE, DRAW_SIZE)
		square.position = point - Vector2(half_size, half_size)
		square.color = Color.WHITE
		square.material = shader_mat
		parent.add_child(square)


func create_static_body_for_stroke(stroke_data: Dictionary) -> void:
	var stroke_points = stroke_data["points"]
	var stroke_material = stroke_data["material"]
	var stroke_shader = stroke_data["shader_material"]
	var brush_shape = stroke_data.get("brush_shape", "circle")
	var brush_scale = stroke_data.get("brush_scale", 1.0)
	var scaled_size = DRAW_SIZE * brush_scale
	
	if stroke_points.is_empty():
		return
	
	# Calculate center
	var center = Vector2.ZERO
	for point in stroke_points:
		center += point
	center /= stroke_points.size()
	
	# Create StaticBody2D
	var static_body = StaticBody2D.new()
	static_body.global_position = center
	
	# Get layer from stroke data
	var body_layer = stroke_data.get("layer", 1)
	
	# Set collision layers
	if body_layer == 1:
		static_body.collision_layer = 1 << LAYER_1_COLLISION_BIT  # Bit 0 = value 1
		static_body.collision_mask = (1 << LAYER_1_COLLISION_BIT) | (1 << GROUND_COLLISION_BIT)  # Bits 0,2 = value 5
	else:  # layer 2
		static_body.collision_layer = 1 << LAYER_2_COLLISION_BIT  # Bit 1 = value 2
		static_body.collision_mask = (1 << LAYER_2_COLLISION_BIT) | (1 << GROUND_COLLISION_BIT)  # Bits 1,2 = value 6
	
	print("Created static body on layer ", body_layer, " - collision_layer: ", static_body.collision_layer, " collision_mask: ", static_body.collision_mask)
	
	# Store layer metadata
	static_body.set_meta("layer", body_layer)
	
	# Create collision shapes for each point
	for point in stroke_points:
		var collision = CollisionShape2D.new()
		collision.shape = create_collision_shape_for_brush(brush_shape, brush_scale)
		collision.position = point - center
		
		# Store material metadata
		var density = 1.0
		if stroke_material != null:
			density = stroke_material.density
		collision.set_meta("density", density)
		collision.set_meta("material", stroke_material)
		collision.set_meta("brush_shape", brush_shape)
		static_body.add_child(collision)
	
	# Create visual based on brush shape
	if brush_shape == "square":
		# Create axis-aligned squares for each point (relative to center)
		var half_size = scaled_size / 2.0
		for point in stroke_points:
			var square = ColorRect.new()
			square.size = Vector2(scaled_size, scaled_size)
			square.position = (point - center) - Vector2(half_size, half_size)
			square.color = Color.WHITE
			square.material = stroke_shader
			static_body.add_child(square)
	else:
		# Use Line2D for circle brush
		var visual_line = Line2D.new()
		visual_line.width = scaled_size
		visual_line.default_color = Color(1.0, 1.0, 1.0, 1.0)
		configure_line2d_for_brush(visual_line, brush_shape)
		visual_line.antialiased = true
		visual_line.material = stroke_shader
		
		for point in stroke_points:
			visual_line.add_point(point - center)
		
		static_body.add_child(visual_line)
	
	get_parent().add_child(static_body)
	
	# Set z_index based on layer (Layer 1 = front, Layer 2 = back)
	static_body.z_index = 10 if body_layer == 1 else 5
	
	# Apply layer visual modulation
	apply_layer_modulation(static_body, body_layer)
	
	# Track for debug draw
	existing_static_bodies.append(static_body)


func convert_dynamic_strokes_to_physics(dynamic_strokes: Array) -> void:
	# Deprecated - old stroke-based system
	# Polygon-based system handles merging automatically via Boolean operations
	pass


func are_strokes_near(stroke_a: Array, stroke_b: Array) -> bool:
	# Check if any point in stroke_a is within MERGE_DISTANCE of any point in stroke_b
	for point_a in stroke_a:
		for point_b in stroke_b:
			if point_a.distance_to(point_b) <= MERGE_DISTANCE:
				return true
	return false


func combine_bodies_with_strokes(bodies: Array, strokes: Array) -> void:
	# Deprecated - old stroke-based system
	pass


func is_point_near_body(point: Vector2, body: RigidBody2D) -> bool:
	# Deprecated - old stroke-based system  
	# Use polygons_overlap instead
	return false


func find_overlapping_collision(body: RigidBody2D, local_pos: Vector2) -> CollisionShape2D:
	# Deprecated - old stroke-based system
	return null


func get_collision_density(collision: CollisionShape2D) -> float:
	# Get the density stored on a collision shape, default to 1.0
	if collision.has_meta("density"):
		return collision.get_meta("density")
	return 1.0


func merge_strokes_into_body(strokes: Array, body: RigidBody2D) -> void:
	# Deprecated - old stroke-based system
	pass


func group_points_by_proximity(points: Array[Vector2]) -> Array:
	# Deprecated - old stroke-based system
	return []


func create_physics_body_for_points(points: Array, strokes: Array) -> void:
	# Deprecated - old stroke-based system
	pass


func update_merge_highlights() -> void:
	# Clean up invalid bodies
	existing_drawn_bodies = existing_drawn_bodies.filter(func(body): return is_instance_valid(body))
	
	# Check if current polygon would overlap with any existing bodies on the same layer
	if current_polygon.size() < 3:
		clear_merge_highlights()
		return
	
	var bodies_in_range = find_overlapping_bodies(current_polygon, current_layer)
	
	# Update visual highlighting on all bodies
	for body in existing_drawn_bodies:
		for child in body.get_children():
			if child is Polygon2D:
				if body in bodies_in_range:
					# Highlight with a green tint to indicate merge target
					child.modulate = Color(0.7, 1.0, 0.7, 1.0)
				else:
					# Normal color
					child.modulate = Color(1.0, 1.0, 1.0, 1.0)


func clear_merge_highlights() -> void:
	# Reset all bodies to normal color
	for body in existing_drawn_bodies:
		if not is_instance_valid(body):
			continue
		for child in body.get_children():
			if child is Polygon2D:
				child.modulate = Color(1.0, 1.0, 1.0, 1.0)


func _process_debug(_delta: float) -> void:
	if debug_draw_collisions:
		queue_redraw()


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


func _draw() -> void:
	if not debug_draw_collisions:
		return
	
	# Clean up static bodies list
	existing_static_bodies = existing_static_bodies.filter(func(body): return is_instance_valid(body))
	
	# Draw debug shapes for all collision shapes on dynamic bodies
	for body in existing_drawn_bodies:
		if not is_instance_valid(body):
			continue
		
		var body_rotation = body.global_rotation
		
		for child in body.get_children():
			if child is CollisionShape2D:
				# Get world position of collision shape
				var world_pos = body.to_global(child.position)
				var local_pos = to_local(world_pos)
				
				# Color based on material density
				var density = get_collision_density(child)
				var color = Color.CYAN
				if density < 1.0:
					color = Color(0.6, 0.4, 0.2, 0.9)  # Light brown for wood
				elif density > 2.0:
					color = Color(0.5, 0.5, 0.6, 0.9)  # Gray for metal
				else:
					color = Color(0.4, 0.4, 0.4, 0.9)  # Dark gray for stone/brick
				
				# Draw shape outline based on type
				if child.shape is CircleShape2D:
					var radius = child.shape.radius
					draw_arc(local_pos, radius, 0, TAU, 16, color, 3.0)
				elif child.shape is RectangleShape2D:
					# Draw rotated rectangle as polygon
					var half_size = child.shape.size / 2.0
					var corners = [
						Vector2(-half_size.x, -half_size.y),
						Vector2(half_size.x, -half_size.y),
						Vector2(half_size.x, half_size.y),
						Vector2(-half_size.x, half_size.y)
					]
					# Rotate corners and translate to position
					for i in range(corners.size()):
						corners[i] = corners[i].rotated(body_rotation) + local_pos
					# Draw lines between corners
					for i in range(4):
						draw_line(corners[i], corners[(i + 1) % 4], color, 3.0)
	
	# Draw debug shapes for static bodies (with different style)
	for body in existing_static_bodies:
		if not is_instance_valid(body):
			continue
		
		var body_rotation = body.global_rotation
		
		for child in body.get_children():
			if child is CollisionShape2D:
				# Get world position of collision shape
				var world_pos = body.to_global(child.position)
				var local_pos = to_local(world_pos)
				
				# Static bodies get a distinct color (green tint)
				var color = Color(0.2, 0.7, 0.3, 0.9)  # Green for static
				
				# Draw shape outline based on type
				if child.shape is CircleShape2D:
					var radius = child.shape.radius
					draw_arc(local_pos, radius, 0, TAU, 16, color, 3.0)
					# Draw inner circle to distinguish from dynamic
					draw_arc(local_pos, radius * 0.6, 0, TAU, 12, color, 2.0)
				elif child.shape is RectangleShape2D:
					# Draw rotated rectangle as polygon
					var half_size = child.shape.size / 2.0
					var corners = [
						Vector2(-half_size.x, -half_size.y),
						Vector2(half_size.x, -half_size.y),
						Vector2(half_size.x, half_size.y),
						Vector2(-half_size.x, half_size.y)
					]
					# Rotate corners and translate to position
					for i in range(corners.size()):
						corners[i] = corners[i].rotated(body_rotation) + local_pos
					# Draw lines between corners (outer)
					for i in range(4):
						draw_line(corners[i], corners[(i + 1) % 4], color, 3.0)
					# Draw inner rect to distinguish from dynamic
					var inner_corners = [
						Vector2(-half_size.x * 0.6, -half_size.y * 0.6),
						Vector2(half_size.x * 0.6, -half_size.y * 0.6),
						Vector2(half_size.x * 0.6, half_size.y * 0.6),
						Vector2(-half_size.x * 0.6, half_size.y * 0.6)
					]
					for i in range(inner_corners.size()):
						inner_corners[i] = inner_corners[i].rotated(body_rotation) + local_pos
					for i in range(4):
						draw_line(inner_corners[i], inner_corners[(i + 1) % 4], color, 2.0)