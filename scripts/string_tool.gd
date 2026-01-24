extends Node2D
## Manages placing strings (rope-like connectors) between physics bodies
## Strings allow free movement within their length but prevent stretching beyond

const STRING_WIDTH: float = 2.0
const DETECTION_RADIUS: float = 20.0
const CONSTRAINT_STIFFNESS: float = 0.9  # How strongly to enforce the constraint (0-1)

# Track all placed strings
var placed_strings: Array = []  # Array of { body_a, body_b, line, attach_local_a, attach_local_b, max_length }

# Two-click workflow state
var pending_first_body: PhysicsBody2D = null
var pending_attach_local: Vector2 = Vector2.ZERO
var pending_attach_world: Vector2 = Vector2.ZERO

# Preview line for showing pending connection
var preview_line: Line2D = null


func _ready() -> void:
	add_to_group("string_tool")
	_create_preview_line()


func _create_preview_line() -> void:
	preview_line = Line2D.new()
	preview_line.width = STRING_WIDTH
	preview_line.default_color = Color(0.6, 0.4, 0.2, 0.5)  # Semi-transparent brown
	preview_line.visible = false
	preview_line.z_index = 15
	add_child(preview_line)


func _physics_process(delta: float) -> void:
	# Apply rope constraints and update visuals
	for string_data in placed_strings:
		_apply_rope_constraint(string_data, delta)
		_update_string_visual(string_data)
	
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


func _apply_rope_constraint(string_data: Dictionary, _delta: float) -> void:
	"""Apply rope constraint - only prevents stretching beyond max_length, allows free rotation"""
	var body_a: PhysicsBody2D = string_data.body_a
	var body_b: PhysicsBody2D = string_data.body_b
	var max_length: float = string_data.max_length
	
	if not is_instance_valid(body_a) or not is_instance_valid(body_b):
		return
	
	# Get current attachment positions in world space
	var local_a: Vector2 = string_data.attach_local_a
	var local_b: Vector2 = string_data.attach_local_b
	var global_a = body_a.to_global(local_a)
	var global_b = body_b.to_global(local_b)
	
	# Calculate current distance
	var delta_pos = global_b - global_a
	var current_length = delta_pos.length()
	
	# Only apply constraint if stretched beyond max length
	if current_length <= max_length:
		return  # Within rope length, no constraint needed
	
	# Calculate how much we've exceeded the max length
	var excess = current_length - max_length
	var direction = delta_pos.normalized()
	
	# Determine which bodies can move (RigidBody2D vs StaticBody2D)
	var a_is_dynamic = body_a is RigidBody2D and not body_a.freeze
	var b_is_dynamic = body_b is RigidBody2D and not body_b.freeze
	
	if not a_is_dynamic and not b_is_dynamic:
		return  # Both static, nothing to do
	
	# Use impulse-based constraint for proper physics integration
	# Apply impulses at the attachment points to allow natural rotation
	var constraint_force = excess * 500.0  # Strong constraint force
	
	if a_is_dynamic and b_is_dynamic:
		# Both dynamic - split based on inverse mass
		var total_inv_mass = (1.0 / body_a.mass) + (1.0 / body_b.mass)
		var ratio_a = (1.0 / body_a.mass) / total_inv_mass
		var ratio_b = (1.0 / body_b.mass) / total_inv_mass
		
		# Calculate impulse to stop separation
		var relative_vel = _get_point_velocity(body_b, global_b) - _get_point_velocity(body_a, global_a)
		var vel_along_rope = relative_vel.dot(direction)
		
		# Impulse to correct position and velocity
		var impulse_magnitude = constraint_force + max(0, vel_along_rope) * 50.0
		var impulse = direction * impulse_magnitude
		
		# Apply impulses at attachment points (this creates proper torque for rotation)
		body_a.apply_impulse(impulse * ratio_a, global_a - body_a.global_position)
		body_b.apply_impulse(-impulse * ratio_b, global_b - body_b.global_position)
		
	elif a_is_dynamic:
		# Only A is dynamic - apply impulse to A toward B
		var point_vel = _get_point_velocity(body_a, global_a)
		var vel_along_rope = point_vel.dot(-direction)
		
		var impulse_magnitude = constraint_force + max(0, -vel_along_rope) * 50.0
		var impulse = direction * impulse_magnitude
		
		body_a.apply_impulse(impulse, global_a - body_a.global_position)
	else:
		# Only B is dynamic - apply impulse to B toward A
		var point_vel = _get_point_velocity(body_b, global_b)
		var vel_along_rope = point_vel.dot(direction)
		
		var impulse_magnitude = constraint_force + max(0, vel_along_rope) * 50.0
		var impulse = -direction * impulse_magnitude
		
		body_b.apply_impulse(impulse, global_b - body_b.global_position)


func _get_point_velocity(body: RigidBody2D, world_point: Vector2) -> Vector2:
	"""Get the velocity of a point on a rigid body (includes angular velocity contribution)"""
	var offset = world_point - body.global_position
	# Velocity at point = linear_velocity + angular_velocity × offset
	# In 2D: angular velocity is scalar, cross product gives perpendicular vector
	var angular_contribution = Vector2(-offset.y, offset.x) * body.angular_velocity
	return body.linear_velocity + angular_contribution


func _update_string_visual(string_data: Dictionary) -> void:
	"""Update a string's Line2D to follow its connected bodies"""
	var line: Line2D = string_data.line
	var body_a: PhysicsBody2D = string_data.body_a
	var body_b: PhysicsBody2D = string_data.body_b
	
	if not is_instance_valid(line) or not is_instance_valid(body_a) or not is_instance_valid(body_b):
		return
	
	# Convert local attachment points to global positions
	var global_a = body_a.to_global(string_data.attach_local_a)
	var global_b = body_b.to_global(string_data.attach_local_b)
	
	# Update line points
	line.clear_points()
	line.add_point(global_a)
	line.add_point(global_b)


func place_string_point(world_position: Vector2) -> void:
	"""Handle a click for placing strings (two-click workflow)"""
	var body = find_body_at_position(world_position)
	
	if body == null:
		print("⚠ No object found at string position")
		cancel_pending()
		return
	
	if pending_first_body == null:
		# First click - store first body and attachment point
		pending_first_body = body
		pending_attach_local = body.to_local(world_position)
		pending_attach_world = world_position
		print("✓ String start point set - click on another object to complete")
	else:
		# Second click - create the string
		if body == pending_first_body:
			print("⚠ Cannot connect an object to itself")
			return
		
		var attach_local_b = body.to_local(world_position)
		create_string(pending_first_body, pending_attach_local, body, attach_local_b)
		
		# Reset pending state
		pending_first_body = null
		pending_attach_local = Vector2.ZERO
		pending_attach_world = Vector2.ZERO


func create_string(body_a: PhysicsBody2D, local_a: Vector2, body_b: PhysicsBody2D, local_b: Vector2) -> void:
	"""Create a rope-like string connection between two bodies"""
	# Calculate max length from initial distance
	var global_a = body_a.to_global(local_a)
	var global_b = body_b.to_global(local_b)
	var max_length = global_a.distance_to(global_b)
	
	# Create visual Line2D (as child of this tool so it persists)
	var line = Line2D.new()
	line.width = STRING_WIDTH
	line.default_color = Color(0.6, 0.4, 0.2)  # Brown rope color
	line.z_index = 10
	line.add_point(global_a)
	line.add_point(global_b)
	add_child(line)
	
	# Track the string (no joint - we use custom rope constraint)
	placed_strings.append({
		"body_a": body_a,
		"body_b": body_b,
		"line": line,
		"attach_local_a": local_a,
		"attach_local_b": local_b,
		"max_length": max_length
	})
	
	print("✓ String placed connecting two objects (length: %.1f)" % max_length)


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


func remove_string_at_position(position: Vector2, threshold: float = 20.0) -> bool:
	"""Remove a string near the given position"""
	for i in range(placed_strings.size() - 1, -1, -1):
		var string_data = placed_strings[i]
		
		if not is_instance_valid(string_data.body_a) or not is_instance_valid(string_data.body_b):
			continue
		
		# Check distance to the line segment
		var global_a = string_data.body_a.to_global(string_data.attach_local_a)
		var global_b = string_data.body_b.to_global(string_data.attach_local_b)
		var distance = _point_to_segment_distance(position, global_a, global_b)
		
		if distance < threshold:
			# Clean up visual
			if is_instance_valid(string_data.line):
				string_data.line.queue_free()
			
			placed_strings.remove_at(i)
			print("String removed")
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


func cleanup_invalid_strings() -> void:
	"""Remove strings whose connected bodies no longer exist"""
	for i in range(placed_strings.size() - 1, -1, -1):
		var string_data = placed_strings[i]
		
		if not is_instance_valid(string_data.body_a) or not is_instance_valid(string_data.body_b):
			if is_instance_valid(string_data.line):
				string_data.line.queue_free()
			
			placed_strings.remove_at(i)
