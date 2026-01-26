extends Node2D
## Manages placing strings (rope-like connectors) between physics bodies
## Uses the rope package for physics-based rope simulation

const STRING_WIDTH: float = 2.0
const DETECTION_RADIUS: float = 20.0
const ROPE_PIECE_LENGTH: float = 20.0  # Length of each rope segment

# Preload rope scenes
var RopeEndPieceScene = preload("res://rope/rope_end_piece.tscn")

# Track all placed strings
# Array of { body_a, body_b, line, attach_local_a, attach_local_b, rope: Rope, anchor_a, anchor_b }
var placed_strings: Array = []

# Track bodies that need to be unfrozen when game unpauses
var pending_unfreeze: Array = []  # Array of RigidBody2D

# Two-click workflow state
var pending_first_body: PhysicsBody2D = null
var pending_attach_local: Vector2 = Vector2.ZERO
var pending_attach_world: Vector2 = Vector2.ZERO

# Preview line for showing pending connection
var preview_line: Line2D = null

# Reference to draw_manager for pause state
var _draw_manager: Node = null


func _ready() -> void:
	add_to_group("string_tool")
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
	preview_line.width = STRING_WIDTH
	preview_line.default_color = Color(0.6, 0.4, 0.2, 0.5)  # Semi-transparent brown
	preview_line.visible = false
	preview_line.z_index = 15
	add_child(preview_line)


var _last_pause_state: bool = true  # Track pause state changes


func _physics_process(_delta: float) -> void:
	var is_paused = _is_physics_paused()
	
	if is_paused != _last_pause_state:
		_last_pause_state = is_paused
	
	if not is_paused and pending_unfreeze.size() > 0:
		for body in pending_unfreeze:
			if is_instance_valid(body) and body is RigidBody2D:
				body.freeze = false
		pending_unfreeze.clear()
	
	# Clean up ropes whose connected bodies were deleted
	_cleanup_invalid_ropes()
	
	# Update visuals only - physics handled by joints (no manual position updates!)
	for string_data in placed_strings:
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


func _cleanup_invalid_ropes() -> void:
	"""Remove ropes whose connected bodies or attachment points have been deleted, or that are over-stretched"""
	var ropes_to_remove = []
	
	for i in range(placed_strings.size()):
		var string_data = placed_strings[i]
		var body_a = string_data.body_a
		var body_b = string_data.body_b
		var should_delete = false
		
		# Check if either connected body is invalid/deleted
		if not is_instance_valid(body_a) or not is_instance_valid(body_b):
			should_delete = true
		# Check if attachment points still exist on the bodies
		elif not _is_attachment_point_valid(body_a, string_data.attach_local_a):
			should_delete = true
		elif not _is_attachment_point_valid(body_b, string_data.attach_local_b):
			should_delete = true
		# Check if rope is over-stretched (more than 10% beyond max length)
		elif _is_rope_overstretched(string_data):
			should_delete = true
		
		if should_delete:
			_delete_rope(string_data)
			ropes_to_remove.append(i)
	
	# Remove invalid ropes from the array (in reverse order to preserve indices)
	for i in range(ropes_to_remove.size() - 1, -1, -1):
		placed_strings.remove_at(ropes_to_remove[i])


func _is_rope_overstretched(string_data: Dictionary) -> bool:
	"""Check if rope is stretched beyond threshold (only breaks on tension, not compression)"""
	var body_a = string_data.body_a
	var body_b = string_data.body_b
	
	if not is_instance_valid(body_a) or not is_instance_valid(body_b):
		return false
	
	var pos_a = body_a.to_global(string_data.attach_local_a)
	var pos_b = body_b.to_global(string_data.attach_local_b)
	var current_distance = pos_a.distance_to(pos_b)
	var initial_distance = string_data.max_length
	
	# Only snap if distance INCREASES beyond threshold (tension, not compression)
	# The rope has slack (1.1x), so allow stretching beyond initial distance
	# Snap at 50% beyond the initial constraint distance
	var snap_threshold = initial_distance * 1.50
	
	# Only break if current distance is greater than initial AND greater than snap threshold
	var should_snap = current_distance > initial_distance and current_distance > snap_threshold
	
	return should_snap


func _is_attachment_point_valid(body: PhysicsBody2D, local_pos: Vector2) -> bool:
	"""Check if an attachment point still exists on a body (hasn't been erased)"""
	if not is_instance_valid(body):
		return false
	
	# Check if the body still has any collision shapes
	# If the body exists but all its collision was erased, it would have no shapes
	var shape_count = body.get_child_count()
	var has_collision = false
	for i in range(shape_count):
		var child = body.get_child(i)
		if child is CollisionShape2D or child is CollisionPolygon2D:
			has_collision = true
			break
	
	if not has_collision:
		return false
	
	# Do a more forgiving spatial check - check if the attachment point is within
	# a reasonable distance of the body's collision boundaries
	var world_pos = body.to_global(local_pos)
	var space_state = get_world_2d().direct_space_state
	var query = PhysicsPointQueryParameters2D.new()
	query.position = world_pos
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.collision_mask = 0xFFFFFFFF  # Check all layers
	
	# Query for bodies at this point
	var results = space_state.intersect_point(query, 5)  # Check up to 5 nearby bodies
	
	# Check if the attachment point still intersects with the original body
	for result in results:
		if result.collider == body:
			return true
	
	# If point query failed, do a shape query with small radius as fallback
	var shape_query = PhysicsShapeQueryParameters2D.new()
	var circle = CircleShape2D.new()
	circle.radius = 5.0  # Small tolerance radius
	shape_query.shape = circle
	shape_query.transform = Transform2D(0, world_pos)
	shape_query.collision_mask = 0xFFFFFFFF
	
	var shape_results = space_state.intersect_shape(shape_query, 5)
	for result in shape_results:
		if result.collider == body:
			return true
	
	return false


func _delete_rope(string_data: Dictionary) -> void:
	"""Delete all components of a rope"""
	# Delete visual line
	if is_instance_valid(string_data.line):
		string_data.line.queue_free()
	
	# Delete joints
	if is_instance_valid(string_data.joint_a):
		string_data.joint_a.queue_free()
	if is_instance_valid(string_data.joint_b):
		string_data.joint_b.queue_free()
	
	# Delete anchors
	if is_instance_valid(string_data.anchor_a):
		string_data.anchor_a.queue_free()
	if is_instance_valid(string_data.anchor_b):
		string_data.anchor_b.queue_free()
	
	# Delete rope (this will also delete all rope segments)
	if string_data.rope != null and is_instance_valid(string_data.rope):
		string_data.rope.queue_free()


func _update_string_visual(string_data: Dictionary) -> void:
	"""Update a string's Line2D to follow all rope segments"""
	var line: Line2D = string_data.line
	var rope: Rope = string_data.rope
	
	if not is_instance_valid(line) or rope == null:
		return
	
	# Get all rope points from the Rope class
	var points = rope.get_points()
	
	line.clear_points()
	for point in points:
		line.add_point(point)


func _create_anchor_joint(body: PhysicsBody2D, local_pos: Vector2, anchor: RopePiece) -> PinJoint2D:
	"""Create a PinJoint2D to connect a rope anchor to a physics body"""
	var joint = PinJoint2D.new()
	
	# Add joint as child of the body (so it moves with the body)
	body.add_child(joint)
	
	# Position joint at the local attachment point
	joint.position = local_pos
	
	# Connect body to anchor
	joint.node_a = joint.get_path_to(body)
	joint.node_b = joint.get_path_to(anchor)
	
	# Joint settings - slightly soft for stability
	joint.softness = 0.1
	joint.bias = 0.9
	joint.disable_collision = true
	
	return joint


func place_string_point(world_position: Vector2) -> void:
	"""Handle a click for placing strings (two-click workflow)"""
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
		# Second click - create the string
		if body == pending_first_body:
			return
		
		var attach_local_b = body.to_local(world_position)
		create_string(pending_first_body, pending_attach_local, body, attach_local_b)
		
		# Reset pending state
		pending_first_body = null
		pending_attach_local = Vector2.ZERO
		pending_attach_world = Vector2.ZERO


func create_string(body_a: PhysicsBody2D, local_a: Vector2, body_b: PhysicsBody2D, local_b: Vector2) -> void:
	"""Create a rope connection between two bodies using the Rope package"""
	var global_a = body_a.to_global(local_a)
	var global_b = body_b.to_global(local_b)
	var total_distance = global_a.distance_to(global_b)
	
	var is_paused = _is_physics_paused()
	
	# Unfreeze RigidBody2D objects so rope physics can work
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
	
	# Calculate segment mass based on attached body mass (keep ratio under 10:1)
	var max_body_mass = 1.0
	if body_a is RigidBody2D:
		max_body_mass = max(max_body_mass, body_a.mass)
	if body_b is RigidBody2D:
		max_body_mass = max(max_body_mass, body_b.mass)
	var recommended_segment_mass = max(1.0, max_body_mass / 5.0)  # Keep ratio at 5:1 for stability
	
	# Create start anchor - freeze if physics is paused
	var anchor_a: RopePiece = RopeEndPieceScene.instantiate()
	anchor_a.global_position = global_a
	anchor_a.freeze = is_paused  # Freeze if paused
	anchor_a.freeze_mode = RigidBody2D.FREEZE_MODE_STATIC if is_paused else RigidBody2D.FREEZE_MODE_KINEMATIC
	anchor_a.mass = recommended_segment_mass
	anchor_a.gravity_scale = 0.0  # No gravity
	anchor_a.linear_damp = 5.0
	anchor_a.angular_damp = 5.0
	anchor_a.collision_layer = 0  # No collisions
	anchor_a.collision_mask = 0
	anchor_a.enable_mouse_force = false  # Prevent cursor attraction
	anchor_a.process_mode = Node.PROCESS_MODE_PAUSABLE  # Stop on pause
	add_child(anchor_a)
	if is_paused:
		pending_unfreeze.append(anchor_a)
	
	# Create end anchor - freeze if physics is paused
	var anchor_b: RopePiece = RopeEndPieceScene.instantiate()
	anchor_b.global_position = global_b
	anchor_b.freeze = is_paused  # Freeze if paused
	anchor_b.freeze_mode = RigidBody2D.FREEZE_MODE_STATIC if is_paused else RigidBody2D.FREEZE_MODE_KINEMATIC
	anchor_b.mass = recommended_segment_mass
	anchor_b.gravity_scale = 0.0  # No gravity
	anchor_b.linear_damp = 5.0
	anchor_b.angular_damp = 5.0
	anchor_b.collision_layer = 0  # No collisions
	anchor_b.collision_mask = 0
	anchor_b.enable_mouse_force = false  # Prevent cursor attraction
	anchor_b.process_mode = Node.PROCESS_MODE_PAUSABLE  # Stop on pause
	add_child(anchor_b)
	if is_paused:
		pending_unfreeze.append(anchor_b)
	
	# Create the Rope instance
	var rope = Rope.new(anchor_a, ROPE_PIECE_LENGTH)
	rope.process_mode = Node.PROCESS_MODE_PAUSABLE  # Stop on pause
	add_child(rope)
	
	# Create the rope segments connecting anchor_a to anchor_b
	rope.create_rope(anchor_b)
	
	# Adjust segment masses for stability (freeze if paused)
	_adjust_rope_segment_masses(rope, recommended_segment_mass, is_paused)
	
	# Connect anchors to bodies using PinJoint2D (physics-based connection, no teleportation)
	var joint_a = _create_anchor_joint(body_a, local_a, anchor_a)
	var joint_b = _create_anchor_joint(body_b, local_b, anchor_b)
	
	# Create visual Line2D
	var line = Line2D.new()
	line.width = STRING_WIDTH
	line.default_color = Color(0.6, 0.4, 0.2)  # Brown rope color
	line.z_index = 10
	add_child(line)
	
	# Track the string with all its components
	placed_strings.append({
		"body_a": body_a,
		"body_b": body_b,
		"line": line,
		"attach_local_a": local_a,
		"attach_local_b": local_b,
		"rope": rope,
		"anchor_a": anchor_a,
		"anchor_b": anchor_b,
		"joint_a": joint_a,
		"joint_b": joint_b,
		"max_length": total_distance
	})


func _adjust_rope_segment_masses(rope: Rope, target_mass: float, freeze_if_paused: bool = false) -> void:
	"""Adjust the mass of rope segments and disable collisions between them"""
	var walker: RopePiece = rope.rope_start
	while walker:
		if walker is RigidBody2D:
			# Disable all collisions for rope segments
			walker.collision_layer = 0
			walker.collision_mask = 0
			# Stop processing on pause
			walker.process_mode = Node.PROCESS_MODE_PAUSABLE
			
			# Set mass and damping
			walker.mass = target_mass
			walker.linear_damp = max(walker.linear_damp, 2.0)
			walker.angular_damp = max(walker.angular_damp, 4.0)
			
			# Disable the mouse force behavior (prevents rope being pulled to cursor)
			if "enable_mouse_force" in walker:
				walker.enable_mouse_force = false
			
			# Freeze if physics is paused
			if freeze_if_paused:
				walker.freeze_mode = RigidBody2D.FREEZE_MODE_STATIC
				walker.freeze = true
				if walker not in pending_unfreeze:
					pending_unfreeze.append(walker)
		walker = walker.next_piece


func find_body_at_position(position: Vector2) -> PhysicsBody2D:
	"""Find any physics body at the given position"""
	var space_state = get_world_2d().direct_space_state
	var query = PhysicsShapeQueryParameters2D.new()
	
	# Create a small circle shape for detection
	var circle = CircleShape2D.new()
	circle.radius = DETECTION_RADIUS
	query.shape = circle
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


func remove_string_at_position(position: Vector2, threshold: float = 20.0) -> bool:
	"""Remove a string near the given position"""
	for i in range(placed_strings.size() - 1, -1, -1):
		var string_data = placed_strings[i]
		
		if not is_instance_valid(string_data.body_a) or not is_instance_valid(string_data.body_b):
			continue
		
		# Check distance to the line segment (first to last point)
		var global_a = string_data.body_a.to_global(string_data.attach_local_a)
		var global_b = string_data.body_b.to_global(string_data.attach_local_b)
		var distance = _point_to_segment_distance(position, global_a, global_b)
		
		if distance < threshold:
			_cleanup_string_data(string_data)
			placed_strings.remove_at(i)
			return true
	
	return false


func _cleanup_string_data(string_data: Dictionary) -> void:
	"""Free all resources associated with a string"""
	# Free the anchor joints first
	if string_data.has("joint_a") and is_instance_valid(string_data.joint_a):
		string_data.joint_a.queue_free()
	if string_data.has("joint_b") and is_instance_valid(string_data.joint_b):
		string_data.joint_b.queue_free()
	
	# Free the rope (which contains all segments and joints)
	var rope: Rope = string_data.rope
	if rope != null:
		# Free all children of the rope (segments)
		for child in rope.get_children():
			child.queue_free()
		rope.queue_free()
	
	# Free anchors
	if is_instance_valid(string_data.anchor_a):
		string_data.anchor_a.queue_free()
	if is_instance_valid(string_data.anchor_b):
		string_data.anchor_b.queue_free()
	
	# Free visual line
	if is_instance_valid(string_data.line):
		string_data.line.queue_free()


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
			_cleanup_string_data(string_data)
			placed_strings.remove_at(i)
