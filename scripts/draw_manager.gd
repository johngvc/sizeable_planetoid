extends Node2D
## Manages drawing objects with the cursor and converting them to physics objects
## Uses proximity-based merging - any strokes with points close together merge into one body
## Supports merging new strokes with existing physics objects

const DRAW_SIZE: float = 16.0  # Size/width of the brush stroke
const MIN_DRAW_DISTANCE: float = 4.0  # Distance between draw points for smooth brush
const MERGE_DISTANCE: float = 24.0  # Distance threshold for merging strokes

# Shader for world-space UV mapping
var world_uv_shader: Shader = null

# Current drawing material
var current_draw_material: DrawMaterial = null

# Strokes - each stroke is a separate continuous line
# Each entry is a dictionary with "points" (Array[Vector2]), "material" (DrawMaterial), "is_static" (bool), "brush_shape" (String)
var all_strokes: Array = []  # Array of { points: Array[Vector2], material: DrawMaterial, shader_material: ShaderMaterial, is_static: bool, brush_shape: String }
var current_stroke: Array[Vector2] = []  # The stroke currently being drawn
var current_stroke_material: DrawMaterial = null  # Material for current stroke
var current_stroke_shader: ShaderMaterial = null  # Shader material for current stroke
var current_stroke_is_static: bool = false  # Whether current stroke is static
var current_stroke_brush_shape: String = "circle"  # Brush shape for current stroke
var last_draw_position: Vector2 = Vector2.ZERO
var preview_nodes: Array[Node2D] = []  # One preview node per stroke (Line2D for circles, Node2D with ColorRects for squares)
var current_preview_node: Node2D = null  # Preview node for the current stroke being drawn
var current_preview_line: Line2D = null  # Line2D for circle brush preview (child of current_preview_node or same node)
var is_currently_drawing: bool = false

# Track all existing drawn physics bodies for merging
var existing_drawn_bodies: Array[RigidBody2D] = []  # Dynamic bodies
var existing_static_bodies: Array[StaticBody2D] = []  # Static bodies

# Tool state - only draw when draw tool is active
var is_draw_tool_active: bool = true
var is_draw_static_mode: bool = false  # false = dynamic (RigidBody2D), true = static (StaticBody2D)

# Brush shape state
var current_brush_shape: String = "circle"  # "circle" or "square"

# Debug visualization
var debug_draw_collisions: bool = true

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
		# Get initial values
		if cursor_ui.get_current_material() != null:
			_on_material_changed(cursor_ui.get_current_material())
		current_brush_shape = cursor_ui.get_current_brush_shape()


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


func create_shader_material_for(material: DrawMaterial) -> ShaderMaterial:
	# Create a NEW shader material instance for the given material
	var shader_mat = ShaderMaterial.new()
	shader_mat.shader = world_uv_shader
	if material != null and material.texture != null:
		shader_mat.set_shader_parameter("wood_texture", material.texture)
	shader_mat.set_shader_parameter("texture_scale", 0.02)
	if material != null:
		shader_mat.set_shader_parameter("tint_color", material.tint)
	else:
		shader_mat.set_shader_parameter("tint_color", Color.WHITE)
	return shader_mat


func _on_tool_changed(tool_name: String) -> void:
	is_draw_tool_active = (tool_name == "draw_dynamic" or tool_name == "draw_static")
	is_draw_static_mode = (tool_name == "draw_static")
	
	# If switching away from draw tool mid-stroke, finish the stroke
	if not is_draw_tool_active and is_currently_drawing:
		if current_stroke.size() > 0:
			all_strokes.append({
				"points": current_stroke.duplicate(),
				"material": current_stroke_material,
				"shader_material": current_stroke_shader,
				"is_static": current_stroke_is_static,
				"brush_shape": current_stroke_brush_shape,
				"brush_scale": 1.0
			})
			if current_preview_node != null:
				preview_nodes.append(current_preview_node)
				current_preview_node = null
				current_preview_line = null
		current_stroke = []
		current_stroke_material = null
		current_stroke_shader = null
		current_stroke_is_static = false
		current_stroke_brush_shape = "circle"
		is_currently_drawing = false


func _process(_delta: float) -> void:
	var cursor = get_tree().get_first_node_in_group("cursor")
	if cursor == null or not cursor.is_cursor_active():
		# Clear any merge highlights when cursor is inactive
		clear_merge_highlights()
		# Still update debug draw
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
	
	# Check if mouse is over UI - don't draw if so
	var is_mouse_over_ui = is_mouse_over_gui()
	
	# Check if B is pressed or mouse left button is pressed for drawing
	var is_drawing = Input.is_key_pressed(KEY_B) or (Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and not is_mouse_over_ui)
	
	if is_drawing:
		var draw_pos = cursor.global_position
		
		if not is_currently_drawing:
			# Starting a new stroke - capture current material and static mode
			is_currently_drawing = true
			current_stroke = []
			current_stroke_material = current_draw_material
			current_stroke_shader = create_shader_material_for(current_draw_material)
			current_stroke_is_static = is_draw_static_mode
			current_stroke_brush_shape = current_brush_shape
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
			# Finished this stroke - save it with its material and static mode
			if current_stroke.size() > 0:
				all_strokes.append({
					"points": current_stroke.duplicate(),
					"material": current_stroke_material,
					"shader_material": current_stroke_shader,
					"is_static": current_stroke_is_static,
					"brush_shape": current_stroke_brush_shape,
					"brush_scale": 1.0  # Default scale, modified by select tool resize
				})
				# Keep the preview node for this finished stroke
				if current_preview_node != null:
					preview_nodes.append(current_preview_node)
					current_preview_node = null
					current_preview_line = null
			current_stroke = []
			current_stroke_material = null
			current_stroke_shader = null
			current_stroke_is_static = false
			current_stroke_brush_shape = "circle"
			is_currently_drawing = false
	
	# Update debug draw
	if debug_draw_collisions:
		queue_redraw()


func start_new_stroke_preview() -> void:
	if current_stroke_brush_shape == "square":
		# For squares, create a container node that will hold ColorRects
		current_preview_node = Node2D.new()
		get_parent().add_child(current_preview_node)
		current_preview_line = null
	else:
		# For circles, use Line2D
		current_preview_line = Line2D.new()
		current_preview_line.width = DRAW_SIZE
		current_preview_line.default_color = Color(1.0, 1.0, 1.0, 1.0)
		configure_line2d_for_brush(current_preview_line, current_stroke_brush_shape)
		current_preview_line.antialiased = true
		current_preview_line.material = current_stroke_shader
		get_parent().add_child(current_preview_line)
		current_preview_node = current_preview_line


func add_brush_point(pos: Vector2) -> void:
	current_stroke.append(pos)
	update_current_preview()


func update_current_preview() -> void:
	if current_stroke.size() == 0:
		return
	
	var last_point = current_stroke[current_stroke.size() - 1]
	
	if current_stroke_brush_shape == "square":
		# Add a new ColorRect for this point
		if current_preview_node != null:
			var half_size = DRAW_SIZE / 2.0
			var square = ColorRect.new()
			square.size = Vector2(DRAW_SIZE, DRAW_SIZE)
			square.position = last_point - Vector2(half_size, half_size)
			square.color = Color.WHITE
			square.material = current_stroke_shader
			current_preview_node.add_child(square)
	else:
		# Add point to Line2D
		if current_preview_line != null:
			current_preview_line.add_point(last_point)


func _on_cursor_mode_changed(active: bool) -> void:
	if not active:
		# Finish current stroke if drawing
		if is_currently_drawing and current_stroke.size() > 0:
			all_strokes.append({
				"points": current_stroke.duplicate(),
				"material": current_stroke_material,
				"shader_material": current_stroke_shader,
				"is_static": current_stroke_is_static,
				"brush_shape": current_stroke_brush_shape,
				"brush_scale": 1.0
			})
		is_currently_drawing = false
		current_stroke = []
		current_stroke_material = null
		current_stroke_shader = null
		current_stroke_is_static = false
		current_stroke_brush_shape = "circle"
		
		if all_strokes.size() > 0:
			convert_strokes_to_physics()


func convert_strokes_to_physics() -> void:
	# Remove all preview nodes
	for node in preview_nodes:
		if is_instance_valid(node):
			node.queue_free()
	preview_nodes.clear()
	
	if current_preview_node != null:
		current_preview_node.queue_free()
		current_preview_node = null
		current_preview_line = null
	
	if all_strokes.is_empty():
		return
	
	# Separate static and dynamic strokes
	var static_strokes: Array = []
	var dynamic_strokes: Array = []
	for stroke_data in all_strokes:
		if stroke_data.get("is_static", false):
			static_strokes.append(stroke_data)
		else:
			dynamic_strokes.append(stroke_data)
	
	# Process static strokes - each becomes its own StaticBody2D (no merging)
	for stroke_data in static_strokes:
		create_static_body_for_stroke(stroke_data)
	
	# Process dynamic strokes with the existing merging logic
	if dynamic_strokes.size() > 0:
		convert_dynamic_strokes_to_physics(dynamic_strokes)
	
	all_strokes.clear()


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
	
	# Track for debug draw
	existing_static_bodies.append(static_body)


func convert_dynamic_strokes_to_physics(dynamic_strokes: Array) -> void:
	# Clean up any freed bodies from the tracking list
	existing_drawn_bodies = existing_drawn_bodies.filter(func(body): return is_instance_valid(body))
	
	# STEP 1: Find which strokes connect to which existing bodies
	var stroke_to_bodies: Array = []  # For each stroke index, array of connected bodies
	for stroke_data in dynamic_strokes:
		var stroke_points = stroke_data["points"]
		var connected_bodies: Array[RigidBody2D] = []
		for point in stroke_points:
			for body in existing_drawn_bodies:
				if not is_instance_valid(body):
					continue
				if body not in connected_bodies and is_point_near_body(point, body):
					connected_bodies.append(body)
		stroke_to_bodies.append(connected_bodies)
	
	# STEP 2: Build stroke-to-stroke proximity (which strokes are near each other)
	var stroke_count = dynamic_strokes.size()
	var stroke_parent: Array[int] = []
	stroke_parent.resize(stroke_count)
	for i in range(stroke_count):
		stroke_parent[i] = i
	
	# Union-find helpers for strokes
	var find_stroke = func(x: int) -> int:
		var root = x
		while stroke_parent[root] != root:
			root = stroke_parent[root]
		while stroke_parent[x] != root:
			var next = stroke_parent[x]
			stroke_parent[x] = root
			x = next
		return root
	
	var unite_strokes = func(a: int, b: int) -> void:
		var ra = find_stroke.call(a)
		var rb = find_stroke.call(b)
		if ra != rb:
			stroke_parent[ra] = rb
	
	# Unite strokes that are near each other (any point within MERGE_DISTANCE)
	for i in range(stroke_count):
		for j in range(i + 1, stroke_count):
			if are_strokes_near(dynamic_strokes[i]["points"], dynamic_strokes[j]["points"]):
				unite_strokes.call(i, j)
	
	# Also unite strokes that share a common body connection
	for i in range(stroke_count):
		for j in range(i + 1, stroke_count):
			# Check if they share any common body
			for body in stroke_to_bodies[i]:
				if body in stroke_to_bodies[j]:
					unite_strokes.call(i, j)
					break
	
	# STEP 3: Group strokes by their union-find root
	var stroke_groups: Dictionary = {}  # root_index -> Array of stroke indices
	for i in range(stroke_count):
		var root = find_stroke.call(i)
		if not stroke_groups.has(root):
			stroke_groups[root] = []
		stroke_groups[root].append(i)
	
	# STEP 4: For each stroke group, collect all connected bodies
	var final_groups: Array = []  # Array of { strokes: Array, bodies: Array[RigidBody2D] }
	
	for root in stroke_groups:
		var stroke_indices: Array = stroke_groups[root]
		var group_strokes: Array = []  # Now contains stroke_data dictionaries
		var group_bodies: Array[RigidBody2D] = []
		
		for idx in stroke_indices:
			group_strokes.append(dynamic_strokes[idx])  # Pass the whole stroke_data dictionary
			for body in stroke_to_bodies[idx]:
				if body not in group_bodies:
					group_bodies.append(body)
		
		final_groups.append({ "strokes": group_strokes, "bodies": group_bodies })
	
	# STEP 5: Now we need to also merge body groups that are connected via strokes
	# Use union-find on bodies
	var body_to_group: Dictionary = {}
	var group_to_bodies: Dictionary = {}
	var group_to_strokes: Dictionary = {}
	var next_group_id = 0
	
	for body in existing_drawn_bodies:
		body_to_group[body] = next_group_id
		group_to_bodies[next_group_id] = [body]
		group_to_strokes[next_group_id] = []
		next_group_id += 1
	
	# Create a special group for strokes that don't connect to any body
	var new_body_group_id = next_group_id
	group_to_bodies[new_body_group_id] = []
	group_to_strokes[new_body_group_id] = []
	next_group_id += 1
	
	# Process each final group
	for fg in final_groups:
		var strokes_in_fg: Array = fg["strokes"]
		var bodies_in_fg: Array = fg["bodies"]
		
		if bodies_in_fg.size() == 0:
			# These strokes don't connect to any existing body - they'll form new bodies
			for s in strokes_in_fg:
				group_to_strokes[new_body_group_id].append(s)
		else:
			# Merge all bodies in this group together
			var target_group = body_to_group[bodies_in_fg[0]]
			
			for i in range(1, bodies_in_fg.size()):
				var other_body = bodies_in_fg[i]
				var other_group = body_to_group[other_body]
				
				if other_group != target_group:
					for body in group_to_bodies[other_group]:
						body_to_group[body] = target_group
						group_to_bodies[target_group].append(body)
					for s in group_to_strokes[other_group]:
						group_to_strokes[target_group].append(s)
					group_to_bodies.erase(other_group)
					group_to_strokes.erase(other_group)
			
			# Add all strokes from this group
			for s in strokes_in_fg:
				group_to_strokes[target_group].append(s)
	
	# STEP 6: Perform the actual merges
	for group_id in group_to_bodies:
		var bodies_in_group: Array = group_to_bodies[group_id]
		var strokes_for_group: Array = group_to_strokes[group_id]
		
		if strokes_for_group.is_empty():
			continue
		
		if bodies_in_group.size() == 0:
			# New strokes that don't connect to existing bodies - create new bodies
			var all_points: Array[Vector2] = []
			for stroke_data in strokes_for_group:
				for point in stroke_data["points"]:
					all_points.append(point)
			
			var point_groups = group_points_by_proximity(all_points)
			for pg in point_groups:
				if pg.size() > 0:
					create_physics_body_for_points(pg, strokes_for_group)
		elif bodies_in_group.size() == 1:
			merge_strokes_into_body(strokes_for_group, bodies_in_group[0])
		else:
			combine_bodies_with_strokes(bodies_in_group, strokes_for_group)
	
	all_strokes.clear()


func are_strokes_near(stroke_a: Array, stroke_b: Array) -> bool:
	# Check if any point in stroke_a is within MERGE_DISTANCE of any point in stroke_b
	for point_a in stroke_a:
		for point_b in stroke_b:
			if point_a.distance_to(point_b) <= MERGE_DISTANCE:
				return true
	return false


func combine_bodies_with_strokes(bodies: Array, strokes: Array) -> void:
	# Combine multiple RigidBody2D into one, including new strokes
	if bodies.is_empty():
		return
	
	# Use the first body as the primary (keep it)
	var primary_body: RigidBody2D = bodies[0]
	var combined_mass = primary_body.mass
	
	# Collect all world-space data from other bodies
	for i in range(1, bodies.size()):
		var other_body: RigidBody2D = bodies[i]
		if not is_instance_valid(other_body):
			continue
		
		# Add mass from other body
		combined_mass += other_body.mass
		
		# Transfer collision shapes (convert to world space, then to primary's local space)
		for child in other_body.get_children():
			if child is CollisionShape2D:
				var world_pos = other_body.to_global(child.position)
				var collision = CollisionShape2D.new()
				# Copy the shape directly to preserve size (including any resizing)
				collision.shape = child.shape.duplicate()
				collision.position = primary_body.to_local(world_pos)
				# Preserve material metadata from original collision
				if child.has_meta("density"):
					collision.set_meta("density", child.get_meta("density"))
				if child.has_meta("material"):
					collision.set_meta("material", child.get_meta("material"))
				var brush_shape = child.get_meta("brush_shape") if child.has_meta("brush_shape") else "circle"
				collision.set_meta("brush_shape", brush_shape)
				primary_body.add_child(collision)
			elif child is Line2D:
				# Transfer Line2D visuals - preserve original material!
				var visual_line = Line2D.new()
				visual_line.width = child.width
				visual_line.default_color = child.default_color
				visual_line.joint_mode = child.joint_mode
				visual_line.begin_cap_mode = child.begin_cap_mode
				visual_line.end_cap_mode = child.end_cap_mode
				visual_line.antialiased = child.antialiased
				visual_line.material = child.material  # Preserve original material
				
				# Convert each point from other body's local to world to primary's local
				for j in range(child.get_point_count()):
					var local_point = child.get_point_position(j)
					var world_point = other_body.to_global(local_point)
					visual_line.add_point(primary_body.to_local(world_point))
				
				primary_body.add_child(visual_line)
			elif child is ColorRect:
				# Transfer ColorRect visuals (for square brush) - preserve original material!
				var world_pos = other_body.to_global(child.position + child.size / 2.0)
				var local_pos = primary_body.to_local(world_pos)
				var square = ColorRect.new()
				square.size = child.size
				square.position = local_pos - child.size / 2.0
				square.color = child.color
				square.material = child.material
				primary_body.add_child(square)
		
		# Remove other body from tracking and free it
		existing_drawn_bodies.erase(other_body)
		other_body.queue_free()
	
	# Now add the new strokes to the primary body
	merge_strokes_into_body(strokes, primary_body)
	
	# Recalculate combined mass from all collision shapes (accounts for overrides)
	var recalculated_mass = 0.0
	for child in primary_body.get_children():
		if child is CollisionShape2D:
			var density = get_collision_density(child)
			recalculated_mass += density * 0.1
	primary_body.mass = max(0.1, recalculated_mass)


func is_point_near_body(point: Vector2, body: RigidBody2D) -> bool:
	# Check if point is within MERGE_DISTANCE of any collision shape center
	# Use to_global() to properly account for body rotation
	for child in body.get_children():
		if child is CollisionShape2D:
			var shape_world_pos = body.to_global(child.position)
			if point.distance_to(shape_world_pos) <= MERGE_DISTANCE:
				return true
	return false


func find_overlapping_collision(body: RigidBody2D, local_pos: Vector2) -> CollisionShape2D:
	# Find an existing collision shape at or near the given local position
	var overlap_threshold = DRAW_SIZE * 0.5  # Points within half the brush size overlap
	for child in body.get_children():
		if child is CollisionShape2D:
			if child.position.distance_to(local_pos) < overlap_threshold:
				return child
	return null


func get_collision_density(collision: CollisionShape2D) -> float:
	# Get the density stored on a collision shape, default to 1.0
	if collision.has_meta("density"):
		return collision.get_meta("density")
	return 1.0


func merge_strokes_into_body(strokes: Array, body: RigidBody2D) -> void:
	# Merge complete strokes into an existing body
	# strokes is now an array of stroke_data dictionaries with "points", "material", "shader_material"
	if strokes.is_empty() or not is_instance_valid(body):
		return
	
	var mass_delta = 0.0  # Track net mass change (can be negative if overriding lighter material)
	
	for stroke_data in strokes:
		var stroke_points = stroke_data["points"]
		var stroke_material = stroke_data["material"]
		var stroke_shader = stroke_data["shader_material"]
		var brush_shape = stroke_data.get("brush_shape", "circle")
		var brush_scale = stroke_data.get("brush_scale", 1.0)
		var scaled_size = DRAW_SIZE * brush_scale
		
		if stroke_points.is_empty():
			continue
		
		var new_density = 1.0
		if stroke_material != null:
			new_density = stroke_material.density
		
		# Add collision shapes for all points in the stroke (with override check)
		for point in stroke_points:
			var local_pos = body.to_local(point)
			var existing_collision = find_overlapping_collision(body, local_pos)
			
			if existing_collision != null:
				# Override existing point's material
				var old_density = get_collision_density(existing_collision)
				existing_collision.set_meta("density", new_density)
				existing_collision.set_meta("material", stroke_material)
				# Adjust mass: subtract old contribution, add new
				mass_delta += (new_density - old_density) * 0.1
			else:
				# Create new collision shape
				var collision = CollisionShape2D.new()
				collision.shape = create_collision_shape_for_brush(brush_shape, brush_scale)
				collision.position = local_pos
				# Store material metadata on collision shape
				collision.set_meta("density", new_density)
				collision.set_meta("material", stroke_material)
				collision.set_meta("brush_shape", brush_shape)
				body.add_child(collision)
				mass_delta += new_density * 0.1
		
		# Add visual based on brush shape
		if brush_shape == "square":
			# Create axis-aligned squares for each point
			var half_size = scaled_size / 2.0
			for point in stroke_points:
				var local_pos = body.to_local(point)
				var square = ColorRect.new()
				square.size = Vector2(scaled_size, scaled_size)
				square.position = local_pos - Vector2(half_size, half_size)
				square.color = Color.WHITE
				square.material = stroke_shader
				body.add_child(square)
		else:
			# Use Line2D for circle brush
			var visual_line = Line2D.new()
			visual_line.width = scaled_size
			visual_line.default_color = Color(1.0, 1.0, 1.0, 1.0)
			configure_line2d_for_brush(visual_line, brush_shape)
			visual_line.antialiased = true
			visual_line.material = stroke_shader  # Use stroke's own shader material
			
			# Add all points in stroke order, converted to body's local space
			for point in stroke_points:
				visual_line.add_point(body.to_local(point))
			
			body.add_child(visual_line)
	
	# Update mass with net change
	body.mass = max(0.1, body.mass + mass_delta)


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
	# strokes is now an array of stroke_data dictionaries
	if points.is_empty():
		return
	
	# Create a single RigidBody2D
	var physics_body = RigidBody2D.new()
	physics_body.gravity_scale = 1.0
	
	# Build a map of point -> stroke_data for material lookup
	var point_to_stroke: Dictionary = {}
	for stroke_data in strokes:
		var stroke_points = stroke_data["points"]
		for p in stroke_points:
			if p in points:
				# Later strokes override earlier ones (last wins)
				point_to_stroke[p] = stroke_data
	
	# Calculate mass based on per-point material density
	var total_mass = 0.0
	for point in points:
		var density = 1.0
		if point_to_stroke.has(point) and point_to_stroke[point]["material"] != null:
			density = point_to_stroke[point]["material"].density
		total_mass += 0.1 * density
	
	physics_body.mass = max(1.0, total_mass)
	
	# Calculate weighted average friction and bounce based on material distribution
	var total_friction = 0.0
	var total_bounce = 0.0
	var material_point_count = 0
	for point in points:
		var friction = 0.5
		var bounce = 0.1
		if point_to_stroke.has(point) and point_to_stroke[point]["material"] != null:
			var mat = point_to_stroke[point]["material"]
			friction = mat.friction
			bounce = mat.bounce
		total_friction += friction
		total_bounce += bounce
		material_point_count += 1
	
	var phys_mat = PhysicsMaterial.new()
	if material_point_count > 0:
		phys_mat.friction = total_friction / material_point_count
		phys_mat.bounce = total_bounce / material_point_count
	else:
		phys_mat.friction = 0.5
		phys_mat.bounce = 0.1
	physics_body.physics_material_override = phys_mat
	
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
	
	# Create collision shape for each point with material metadata
	for point in points:
		var collision = CollisionShape2D.new()
		
		# Get brush shape and scale from the stroke this point belongs to
		var brush_shape = "circle"
		var brush_scale = 1.0
		if point_to_stroke.has(point):
			brush_shape = point_to_stroke[point].get("brush_shape", "circle")
			brush_scale = point_to_stroke[point].get("brush_scale", 1.0)
		collision.shape = create_collision_shape_for_brush(brush_shape, brush_scale)
		collision.position = point - center
		
		# Store material metadata on collision shape
		var density = 1.0
		var mat = null
		if point_to_stroke.has(point) and point_to_stroke[point]["material"] != null:
			mat = point_to_stroke[point]["material"]
			density = mat.density
		collision.set_meta("density", density)
		collision.set_meta("material", mat)
		collision.set_meta("brush_shape", brush_shape)
		physics_body.add_child(collision)
	
	# Create separate visuals for each stroke that has points in this group
	for stroke_data in strokes:
		var stroke_points = stroke_data["points"]
		var stroke_shader = stroke_data["shader_material"]
		var stroke_brush_shape = stroke_data.get("brush_shape", "circle")
		var stroke_brush_scale = stroke_data.get("brush_scale", 1.0)
		var scaled_size = DRAW_SIZE * stroke_brush_scale
		
		var stroke_points_in_group: Array[Vector2] = []
		for point in stroke_points:
			if points_set.has(point):
				stroke_points_in_group.append(point)
		
		if stroke_points_in_group.size() > 0:
			if stroke_brush_shape == "square":
				# Create axis-aligned squares for each point
				var half_size = scaled_size / 2.0
				for point in stroke_points_in_group:
					var square = ColorRect.new()
					square.size = Vector2(scaled_size, scaled_size)
					square.position = (point - center) - Vector2(half_size, half_size)
					square.color = Color.WHITE
					square.material = stroke_shader
					physics_body.add_child(square)
			else:
				# Use Line2D for circle brush
				var visual_line = Line2D.new()
				visual_line.width = scaled_size
				visual_line.default_color = Color(1.0, 1.0, 1.0, 1.0)
				configure_line2d_for_brush(visual_line, stroke_brush_shape)
				visual_line.antialiased = true
				visual_line.material = stroke_shader  # Use stroke's own shader material
				
				# Add points in stroke order
				for point in stroke_points_in_group:
					visual_line.add_point(point - center)
				
				physics_body.add_child(visual_line)
	
	get_parent().add_child(physics_body)
	
	# If physics is paused, freeze this body immediately
	if is_physics_paused:
		physics_body.freeze_mode = RigidBody2D.FREEZE_MODE_STATIC
		physics_body.freeze = true
	
	# Track this body for future merging
	existing_drawn_bodies.append(physics_body)


func update_merge_highlights() -> void:
	# Clean up invalid bodies
	existing_drawn_bodies = existing_drawn_bodies.filter(func(body): return is_instance_valid(body))
	
	# Gather all current drawing points (current stroke + finished strokes)
	var all_drawing_points: Array[Vector2] = []
	for point in current_stroke:
		all_drawing_points.append(point)
	for stroke_data in all_strokes:
		for point in stroke_data["points"]:
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