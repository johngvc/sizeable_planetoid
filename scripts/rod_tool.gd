extends Node2D
## Manages placing rods (rigid connectors) between physics bodies
## Uses PinJoint2D for stable physics - maintains fixed distance between attachment points

const ROD_WIDTH: float = 3.0
const DETECTION_RADIUS: float = 20.0

# Track all placed rods
var placed_rods: Array = []  # Array of { body_a, body_b, joint, line, attach_local_a, attach_local_b }

# Two-click workflow state
var pending_first_body: PhysicsBody2D = null
var pending_attach_local: Vector2 = Vector2.ZERO
var pending_attach_world: Vector2 = Vector2.ZERO

# Preview line for showing pending connection
var preview_line: Line2D = null


func _ready() -> void:
	add_to_group("rod_tool")
	_create_preview_line()


func _create_preview_line() -> void:
	preview_line = Line2D.new()
	preview_line.width = ROD_WIDTH
	preview_line.default_color = Color(0.5, 0.5, 0.5, 0.5)  # Semi-transparent gray (metal)
	preview_line.visible = false
	preview_line.z_index = 15
	add_child(preview_line)


func _physics_process(_delta: float) -> void:
	# Update rod visuals
	for rod_data in placed_rods:
		_update_rod_visual(rod_data)
	
	# Update preview line if we have a pending first point
	if pending_first_body != null and is_instance_valid(pending_first_body):
		var cursor = get_tree().get_first_node_in_group("cursor")
		if cursor and preview_line:
			var start_pos = pending_first_body.to_global(pending_attach_local)
			preview_line.clear_points()
			preview_line.add_point(start_pos)
			preview_line.add_point(cursor.global_position)
			preview_line.visible = true
	else:
		if preview_line:
			preview_line.visible = false


func _update_rod_visual(rod_data: Dictionary) -> void:
	"""Update a rod's Line2D to follow its connected bodies"""
	var line: Line2D = rod_data.line
	var body_a: PhysicsBody2D = rod_data.body_a
	var body_b: PhysicsBody2D = rod_data.body_b
	
	if not is_instance_valid(line) or not is_instance_valid(body_a) or not is_instance_valid(body_b):
		return
	
	# Convert local attachment points to global positions
	var global_a = body_a.to_global(rod_data.attach_local_a)
	var global_b = body_b.to_global(rod_data.attach_local_b)
	
	# Update line points
	line.clear_points()
	line.add_point(global_a)
	line.add_point(global_b)


func place_rod_point(world_position: Vector2) -> void:
	"""Handle a click for placing rods (two-click workflow)"""
	var body = find_body_at_position(world_position)
	
	if body == null:
		cancel_pending()
		return
	
	if pending_first_body == null:
		# First click - store first body and attachment point
		pending_first_body = body
		pending_attach_local = body.to_local(world_position)
		pending_attach_world = world_position
	else:
		# Second click - create the rod
		if body == pending_first_body:
			return
		
		var attach_local_b = body.to_local(world_position)
		create_rod(pending_first_body, pending_attach_local, body, attach_local_b)
		
		# Reset pending state
		pending_first_body = null
		pending_attach_local = Vector2.ZERO
		pending_attach_world = Vector2.ZERO


func create_rod(body_a: PhysicsBody2D, local_a: Vector2, body_b: PhysicsBody2D, local_b: Vector2) -> void:
	"""Create a rigid rod connection between two bodies using PinJoint2D"""
	var global_a = body_a.to_global(local_a)
	var global_b = body_b.to_global(local_b)
	var rod_length = global_a.distance_to(global_b)
	
	# Create a PinJoint2D at the first attachment point
	var pin_joint = PinJoint2D.new()
	pin_joint.position = local_a  # Local position on body_a
	
	# Add joint as child of body_a
	body_a.add_child(pin_joint)
	
	# Configure the joint
	pin_joint.node_a = pin_joint.get_path_to(body_a)
	pin_joint.node_b = pin_joint.get_path_to(body_b)
	
	# Rigid rod settings - completely rigid, no flexibility
	pin_joint.softness = 0.0  # 0 = completely rigid
	pin_joint.bias = 0.9  # High bias for strong constraint correction
	pin_joint.disable_collision = false  # Keep collision between connected bodies
	
	# Create visual Line2D (gray metallic look for rod)
	var line = Line2D.new()
	line.width = ROD_WIDTH
	line.default_color = Color(0.5, 0.5, 0.55)  # Gray metallic color
	line.z_index = 10
	line.add_point(global_a)
	line.add_point(global_b)
	add_child(line)
	
	# Track the rod
	placed_rods.append({
		"body_a": body_a,
		"body_b": body_b,
		"joint": pin_joint,
		"line": line,
		"attach_local_a": local_a,
		"attach_local_b": local_b,
		"length": rod_length
	})


func find_body_at_position(position: Vector2) -> PhysicsBody2D:
	"""Find any physics body at the given position"""
	var space_state = get_world_2d().direct_space_state
	var query = PhysicsShapeQueryParameters2D.new()
	
	# Create a small circle for detection
	var shape = CircleShape2D.new()
	shape.radius = DETECTION_RADIUS
	query.shape = shape
	query.transform = Transform2D(0, position)
	
	# Check both layers (mask bits 0 and 1)
	query.collision_mask = (1 << 0) | (1 << 1)
	
	var results = space_state.intersect_shape(query, 32)
	
	for result in results:
		var collider = result.collider
		if collider is PhysicsBody2D:
			return collider
	
	return null


func cancel_pending() -> void:
	"""Cancel the pending first point"""
	pending_first_body = null
	pending_attach_local = Vector2.ZERO
	pending_attach_world = Vector2.ZERO
	if preview_line:
		preview_line.visible = false


func remove_rod_at_position(position: Vector2, threshold: float = 20.0) -> bool:
	"""Remove a rod near the given position"""
	for i in range(placed_rods.size() - 1, -1, -1):
		var rod_data = placed_rods[i]
		
		if not is_instance_valid(rod_data.body_a) or not is_instance_valid(rod_data.body_b):
			continue
		
		# Check distance to the line segment
		var global_a = rod_data.body_a.to_global(rod_data.attach_local_a)
		var global_b = rod_data.body_b.to_global(rod_data.attach_local_b)
		var distance = _point_to_segment_distance(position, global_a, global_b)
		
		if distance < threshold:
			# Clean up joint and visual
			if is_instance_valid(rod_data.joint):
				rod_data.joint.queue_free()
			if is_instance_valid(rod_data.line):
				rod_data.line.queue_free()
			
			placed_rods.remove_at(i)
			return true
	
	return false


func _point_to_segment_distance(point: Vector2, seg_start: Vector2, seg_end: Vector2) -> float:
	"""Calculate shortest distance from a point to a line segment"""
	var segment = seg_end - seg_start
	var length_squared = segment.length_squared()
	
	if length_squared == 0:
		return point.distance_to(seg_start)
	
	# Project point onto line, clamped to segment
	var t = max(0, min(1, (point - seg_start).dot(segment) / length_squared))
	var projection = seg_start + t * segment
	
	return point.distance_to(projection)


func cleanup_invalid_rods() -> void:
	"""Remove rods whose connected bodies no longer exist"""
	for i in range(placed_rods.size() - 1, -1, -1):
		var rod_data = placed_rods[i]
		
		if not is_instance_valid(rod_data.body_a) or not is_instance_valid(rod_data.body_b):
			if is_instance_valid(rod_data.joint):
				rod_data.joint.queue_free()
			if is_instance_valid(rod_data.line):
				rod_data.line.queue_free()
			
			placed_rods.remove_at(i)
