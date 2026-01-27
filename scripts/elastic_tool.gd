extends Node2D
## Manages placing elastic connectors between physics bodies
## Elastics allow free movement within their length and stretch when pulled
## Uses DampedSpringJoint2D for physics-based spring behavior

const ELASTIC_WIDTH: float = 2.0
const DETECTION_RADIUS: float = 20.0
const SPRING_STIFFNESS: float = 2000.0  # Strong spring force to support weight
const SPRING_DAMPING: float = 10.0  # Moderate damping for stability
const SNAP_STRETCH_RATIO: float = 4.0  # Snap at 300% stretch (4x rest length)

# Track all placed elastics
# Array of { body_a, body_b, line, spring_joint, attach_local_a, attach_local_b, rest_length }
var placed_elastics: Array = []

# Track bodies that need to be unfrozen when game unpauses
var pending_unfreeze: Array = []  # Array of RigidBody2D

# Reference to draw_manager for pause state
var _draw_manager: Node = null

# Two-click workflow state
var pending_first_body: PhysicsBody2D = null
var pending_attach_local: Vector2 = Vector2.ZERO
var pending_attach_world: Vector2 = Vector2.ZERO

# Preview line for showing pending connection
var preview_line: Line2D = null


func _ready() -> void:
	add_to_group("elastic_tool")
	_create_preview_line()
	# Get reference to draw_manager for pause state checking
	call_deferred("_find_draw_manager")


func _find_draw_manager() -> void:
	"""Find the draw_manager to check its pause state"""
	_draw_manager = get_tree().get_first_node_in_group("draw_manager")


func _is_physics_paused() -> bool:
	"""Check if physics is paused using draw_manager's custom pause state"""
	if _draw_manager and _draw_manager.has_method("get") and "is_physics_paused" in _draw_manager:
		return _draw_manager.is_physics_paused
	# Fallback to tree pause state
	return get_tree().paused


func _create_preview_line() -> void:
	preview_line = Line2D.new()
	preview_line.width = ELASTIC_WIDTH
	preview_line.default_color = Color(0.2, 0.8, 0.3, 0.5)  # Semi-transparent green
	preview_line.visible = false
	preview_line.z_index = 15
	add_child(preview_line)


func _physics_process(_delta: float) -> void:
	var is_paused = _is_physics_paused()
	
	# Unfreeze bodies when game unpauses
	if not is_paused and pending_unfreeze.size() > 0:
		for body in pending_unfreeze:
			if is_instance_valid(body) and body is RigidBody2D:
				body.freeze = false
		pending_unfreeze.clear()
	
	# Clean up elastics whose connected bodies were deleted or overstretched
	_cleanup_invalid_elastics()
	
	# Update visuals only - physics handled by DampedSpringJoint2D
	for elastic_data in placed_elastics:
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


func _cleanup_invalid_elastics() -> void:
	"""Remove elastics whose connected bodies were deleted or that are over-stretched"""
	var elastics_to_remove = []
	
	for i in range(placed_elastics.size()):
		var elastic_data = placed_elastics[i]
		var body_a = elastic_data.body_a
		var body_b = elastic_data.body_b
		var should_delete = false
		
		# Check if either connected body is invalid/deleted
		if not is_instance_valid(body_a) or not is_instance_valid(body_b):
			should_delete = true
		# Check if attachment points still exist on the bodies
		elif not _is_attachment_point_valid(body_a, elastic_data.attach_local_a):
			should_delete = true
		elif not _is_attachment_point_valid(body_b, elastic_data.attach_local_b):
			should_delete = true
		# Check if elastic is over-stretched (snap when stretched beyond threshold)
		elif _is_elastic_overstretched(elastic_data):
			should_delete = true
		
		if should_delete:
			_delete_elastic(elastic_data)
			elastics_to_remove.append(i)
	
	# Remove invalid elastics from the array (in reverse order to preserve indices)
	for i in range(elastics_to_remove.size() - 1, -1, -1):
		placed_elastics.remove_at(elastics_to_remove[i])


func _is_elastic_overstretched(elastic_data: Dictionary) -> bool:
	"""Check if elastic is stretched beyond snap threshold"""
	var body_a = elastic_data.body_a
	var body_b = elastic_data.body_b
	
	if not is_instance_valid(body_a) or not is_instance_valid(body_b):
		return false
	
	var pos_a = body_a.to_global(elastic_data.attach_local_a)
	var pos_b = body_b.to_global(elastic_data.attach_local_b)
	var current_distance = pos_a.distance_to(pos_b)
	var rest_length = elastic_data.rest_length
	
	# Snap if stretched beyond threshold (e.g., 2x rest length = 100% stretch)
	var snap_threshold = rest_length * SNAP_STRETCH_RATIO
	
	return current_distance > snap_threshold


func _is_attachment_point_valid(body: PhysicsBody2D, local_pos: Vector2) -> bool:
	"""Check if an attachment point still exists on a body (hasn't been erased)"""
	if not is_instance_valid(body):
		return false
	
	# Check if the body still has any collision shapes
	var shape_count = body.get_child_count()
	var has_collision = false
	for i in range(shape_count):
		var child = body.get_child(i)
		if child is CollisionShape2D or child is CollisionPolygon2D:
			has_collision = true
			break
	
	if not has_collision:
		return false
	
	# Do a spatial check - check if the attachment point is within the body's collision
	var world_pos = body.to_global(local_pos)
	var space_state = get_world_2d().direct_space_state
	var query = PhysicsPointQueryParameters2D.new()
	query.position = world_pos
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.collision_mask = 0xFFFFFFFF
	
	var results = space_state.intersect_point(query, 5)
	
	for result in results:
		if result.collider == body:
			return true
	
	# Fallback: shape query with small radius
	var shape_query = PhysicsShapeQueryParameters2D.new()
	var circle = CircleShape2D.new()
	circle.radius = 5.0
	shape_query.shape = circle
	shape_query.transform = Transform2D(0, world_pos)
	shape_query.collision_mask = 0xFFFFFFFF
	
	var shape_results = space_state.intersect_shape(shape_query, 5)
	for result in shape_results:
		if result.collider == body:
			return true
	
	return false


func _delete_elastic(elastic_data: Dictionary) -> void:
	"""Delete all components of an elastic"""
	# Delete visual line
	if is_instance_valid(elastic_data.line):
		elastic_data.line.queue_free()
	
	# Delete spring joint
	if elastic_data.has("spring_joint") and is_instance_valid(elastic_data.spring_joint):
		elastic_data.spring_joint.queue_free()


func _update_elastic_visual(elastic_data: Dictionary) -> void:
	"""Update an elastic's Line2D to follow its connected bodies with stretch indicator"""
	var line: Line2D = elastic_data.line
	var body_a: PhysicsBody2D = elastic_data.body_a
	var body_b: PhysicsBody2D = elastic_data.body_b
	
	if not is_instance_valid(line) or not is_instance_valid(body_a) or not is_instance_valid(body_b):
		return
	
	# Convert local attachment points to global positions
	var global_a = body_a.to_global(elastic_data.attach_local_a)
	var global_b = body_b.to_global(elastic_data.attach_local_b)
	
	# Calculate stretch ratio for visual feedback
	var current_length = global_a.distance_to(global_b)
	var rest_length = elastic_data.rest_length
	var stretch_ratio = current_length / rest_length if rest_length > 0 else 1.0
	
	# Update line points - single straight segment
	line.clear_points()
	line.add_point(global_a)
	line.add_point(global_b)
	
	# Color feedback based on stretch (green -> yellow -> red as it stretches)
	if stretch_ratio < 1.2:
		line.default_color = Color(0.2, 0.8, 0.3)  # Green - relaxed
	elif stretch_ratio < 1.6:
		var t = (stretch_ratio - 1.2) / 0.4
		line.default_color = Color(0.2 + 0.6 * t, 0.8 - 0.4 * t, 0.3 - 0.2 * t)  # Green to yellow
	else:
		var t = min(1.0, (stretch_ratio - 1.6) / 0.4)
		line.default_color = Color(0.8 + 0.2 * t, 0.4 - 0.4 * t, 0.1 - 0.1 * t)  # Yellow to red


func place_elastic_point(world_position: Vector2) -> void:
	"""Handle a click for placing elastics (two-click workflow)"""
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
		# Second click - create the elastic
		if body == pending_first_body:
			return
		
		var attach_local_b = body.to_local(world_position)
		create_elastic(pending_first_body, pending_attach_local, body, attach_local_b)
		
		# Reset pending state
		pending_first_body = null
		pending_attach_local = Vector2.ZERO
		pending_attach_world = Vector2.ZERO


func create_elastic(body_a: PhysicsBody2D, local_a: Vector2, body_b: PhysicsBody2D, local_b: Vector2) -> void:
	"""Create an elastic connection between two bodies using DampedSpringJoint2D"""
	var global_a = body_a.to_global(local_a)
	var global_b = body_b.to_global(local_b)
	var rest_length = global_a.distance_to(global_b)
	
	var is_paused = _is_physics_paused()
	
	# Unfreeze RigidBody2D objects so elastic physics can work
	# If paused, defer unfreezing until game unpauses
	if body_a is RigidBody2D:
		if body_a.freeze:
			if is_paused:
				if body_a not in pending_unfreeze:
					pending_unfreeze.append(body_a)
			else:
				body_a.freeze = false
			
	if body_b is RigidBody2D:
		if body_b.freeze:
			if is_paused:
				if body_b not in pending_unfreeze:
					pending_unfreeze.append(body_b)
			else:
				body_b.freeze = false
	
	# Create DampedSpringJoint2D for physics-based elastic behavior
	var spring = DampedSpringJoint2D.new()
	body_a.add_child(spring)
	spring.position = local_a
	
	# Connect to both bodies
	spring.node_a = spring.get_path_to(body_a)
	spring.node_b = spring.get_path_to(body_b)
	
	# Configure spring properties
	spring.rest_length = rest_length  # Natural length (no force applied)
	spring.length = rest_length  # Current/initial length
	spring.stiffness = SPRING_STIFFNESS  # How strong the spring force is
	spring.damping = SPRING_DAMPING  # How quickly oscillations settle
	spring.disable_collision = true  # Don't collide between connected bodies
	
	# Create visual Line2D
	var line = Line2D.new()
	line.width = ELASTIC_WIDTH
	line.default_color = Color(0.2, 0.8, 0.3)  # Green elastic color
	line.z_index = 10
	line.add_point(global_a)
	line.add_point(global_b)
	add_child(line)
	
	# Track the elastic with spring joint reference
	placed_elastics.append({
		"body_a": body_a,
		"body_b": body_b,
		"line": line,
		"spring_joint": spring,
		"attach_local_a": local_a,
		"attach_local_b": local_b,
		"rest_length": rest_length
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
	
	# Check all collision layers (enable all 32 bits)
	query.collision_mask = 0xFFFFFFFF
	
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
			_delete_elastic(elastic_data)
			placed_elastics.remove_at(i)
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
	"""Remove elastics whose connected bodies no longer exist (public API)"""
	_cleanup_invalid_elastics()
