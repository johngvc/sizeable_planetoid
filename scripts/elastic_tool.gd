extends Node2D
## Manages placing elastic connectors between physics bodies
## Elastics allow free movement within their length and stretch when pulled
## Uses force-based constraint with springy behavior

const ELASTIC_WIDTH: float = 2.0
const DETECTION_RADIUS: float = 20.0

# Track all placed elastics
var placed_elastics: Array = []  # Array of { body_a, body_b, line, attach_local_a, attach_local_b, max_length }

# Two-click workflow state
var pending_first_body: PhysicsBody2D = null
var pending_attach_local: Vector2 = Vector2.ZERO
var pending_attach_world: Vector2 = Vector2.ZERO

# Preview line for showing pending connection
var preview_line: Line2D = null


func _ready() -> void:
	add_to_group("elastic_tool")
	_create_preview_line()


func _create_preview_line() -> void:
	preview_line = Line2D.new()
	preview_line.width = ELASTIC_WIDTH
	preview_line.default_color = Color(0.2, 0.8, 0.3, 0.5)  # Semi-transparent green
	preview_line.visible = false
	preview_line.z_index = 15
	add_child(preview_line)


func _physics_process(_delta: float) -> void:
	# Apply elastic constraints and update visuals
	for elastic_data in placed_elastics:
		_apply_elastic_constraint(elastic_data)
		_update_elastic_visual(elastic_data)
	
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


func _apply_elastic_constraint(elastic_data: Dictionary) -> void:
	"""Apply elastic constraint - stretchy spring-like behavior"""
	var body_a: PhysicsBody2D = elastic_data.body_a
	var body_b: PhysicsBody2D = elastic_data.body_b
	var max_length: float = elastic_data.max_length
	
	if not is_instance_valid(body_a) or not is_instance_valid(body_b):
		return
	
	# Get current attachment positions
	var global_a = body_a.to_global(elastic_data.attach_local_a)
	var global_b = body_b.to_global(elastic_data.attach_local_b)
	
	# Calculate current distance
	var delta_pos = global_b - global_a
	var current_length = delta_pos.length()
	
	# Only apply constraint if stretched beyond max length
	if current_length <= max_length:
		return  # Within elastic length, free movement allowed
	
	var direction = delta_pos.normalized()
	var excess = current_length - max_length
	
	# Determine which bodies can move
	var a_is_dynamic = body_a is RigidBody2D and not body_a.freeze
	var b_is_dynamic = body_b is RigidBody2D and not body_b.freeze
	
	if not a_is_dynamic and not b_is_dynamic:
		return
	
	# Soft elastic force - allows stretching
	var stiffness = 100.0  # Gentle spring force
	var damping = 5.0  # Velocity damping
	
	if a_is_dynamic and b_is_dynamic:
		var total_inv_mass = (1.0 / body_a.mass) + (1.0 / body_b.mass)
		var ratio_a = (1.0 / body_a.mass) / total_inv_mass
		var ratio_b = (1.0 / body_b.mass) / total_inv_mass
		
		# Get relative velocity along elastic direction
		var rel_vel = body_b.linear_velocity - body_a.linear_velocity
		var vel_along_elastic = rel_vel.dot(direction)
		
		# Apply force only if moving apart or already stretched
		var force_mag = excess * stiffness
		if vel_along_elastic > 0:
			force_mag += vel_along_elastic * damping * body_a.mass
		
		var force = direction * force_mag
		body_a.apply_central_force(force * ratio_a)
		body_b.apply_central_force(-force * ratio_b)
		
	elif a_is_dynamic:
		var vel_along_elastic = body_a.linear_velocity.dot(-direction)
		var force_mag = excess * stiffness
		if vel_along_elastic < 0:
			force_mag += -vel_along_elastic * damping * body_a.mass
		body_a.apply_central_force(direction * force_mag)
		
	else:  # b_is_dynamic
		var vel_along_elastic = body_b.linear_velocity.dot(direction)
		var force_mag = excess * stiffness
		if vel_along_elastic > 0:
			force_mag += vel_along_elastic * damping * body_b.mass
		body_b.apply_central_force(-direction * force_mag)


func _update_elastic_visual(elastic_data: Dictionary) -> void:
	"""Update an elastic's Line2D to follow its connected bodies"""
	var line: Line2D = elastic_data.line
	var body_a: PhysicsBody2D = elastic_data.body_a
	var body_b: PhysicsBody2D = elastic_data.body_b
	
	if not is_instance_valid(line) or not is_instance_valid(body_a) or not is_instance_valid(body_b):
		return
	
	# Convert local attachment points to global positions
	var global_a = body_a.to_global(elastic_data.attach_local_a)
	var global_b = body_b.to_global(elastic_data.attach_local_b)
	
	# Update line points
	line.clear_points()
	line.add_point(global_a)
	line.add_point(global_b)


func place_elastic_point(world_position: Vector2) -> void:
	"""Handle a click for placing elastics (two-click workflow)"""
	var body = find_body_at_position(world_position)
	
	if body == null:
		print("⚠ No object found at elastic position")
		cancel_pending()
		return
	
	if pending_first_body == null:
		# First click - store first body and attachment point
		pending_first_body = body
		pending_attach_local = body.to_local(world_position)
		pending_attach_world = world_position
		print("✓ Elastic start point set - click on another object to complete")
	else:
		# Second click - create the elastic
		if body == pending_first_body:
			print("⚠ Cannot connect an object to itself")
			return
		
		var attach_local_b = body.to_local(world_position)
		create_elastic(pending_first_body, pending_attach_local, body, attach_local_b)
		
		# Reset pending state
		pending_first_body = null
		pending_attach_local = Vector2.ZERO
		pending_attach_world = Vector2.ZERO


func create_elastic(body_a: PhysicsBody2D, local_a: Vector2, body_b: PhysicsBody2D, local_b: Vector2) -> void:
	"""Create an elastic connection between two bodies"""
	var global_a = body_a.to_global(local_a)
	var global_b = body_b.to_global(local_b)
	var max_length = global_a.distance_to(global_b)
	
	# Create visual Line2D
	var line = Line2D.new()
	line.width = ELASTIC_WIDTH
	line.default_color = Color(0.2, 0.8, 0.3)  # Green elastic color
	line.z_index = 10
	line.add_point(global_a)
	line.add_point(global_b)
	add_child(line)
	
	# Track the elastic (using custom constraint, not a joint)
	placed_elastics.append({
		"body_a": body_a,
		"body_b": body_b,
		"line": line,
		"attach_local_a": local_a,
		"attach_local_b": local_b,
		"max_length": max_length
	})
	
	print("✓ Elastic placed connecting two objects (rest length: %.1f)" % max_length)


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


func remove_elastic_at_position(position: Vector2, threshold: float = 20.0) -> bool:
	"""Remove an elastic near the given position"""
	for i in range(placed_elastics.size() - 1, -1, -1):
		var elastic_data = placed_elastics[i]
		
		if not is_instance_valid(elastic_data.body_a) or not is_instance_valid(elastic_data.body_b):
			continue
		
		# Check distance to the line segment
		var global_a = elastic_data.body_a.to_global(elastic_data.attach_local_a)
		var global_b = elastic_data.body_b.to_global(elastic_data.attach_local_b)
		var distance = _point_to_segment_distance(position, global_a, global_b)
		
		if distance < threshold:
			# Clean up visual
			if is_instance_valid(elastic_data.line):
				elastic_data.line.queue_free()
			
			placed_elastics.remove_at(i)
			print("Elastic removed")
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


func cleanup_invalid_elastics() -> void:
	"""Remove elastics whose connected bodies no longer exist"""
	for i in range(placed_elastics.size() - 1, -1, -1):
		var elastic_data = placed_elastics[i]
		
		if not is_instance_valid(elastic_data.body_a) or not is_instance_valid(elastic_data.body_b):
			if is_instance_valid(elastic_data.line):
				elastic_data.line.queue_free()
			
			placed_elastics.remove_at(i)
