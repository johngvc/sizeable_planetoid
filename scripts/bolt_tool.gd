extends Node2D
## Manages placing bolts that connect Layer 1 and Layer 2 objects
## Bolts are very stiff connections that snap when over-tensioned

const BOLT_VISUAL_RADIUS: float = 4.0
const DETECTION_RADIUS: float = 20.0  # How close to stroke we need to click

# Snapping configuration
const MAX_TENSION_DISTANCE: float = 10.0  # Maximum stretch before bolt snaps (in pixels)
const STRESS_WARNING_DISTANCE: float = 5.0  # Distance at which bolt shows stress (turns red)

# Track all placed bolts
# Each bolt stores: position, layer1_body, layer2_body, joint, visual, 
#                   local_anchor1 (position in layer1_body local coords),
#                   local_anchor2 (position in layer2_body local coords)
var placed_bolts: Array = []

# Bolts pending reattachment after body recreation
var _pending_reattach: Array = []  # Array of indices needing reattachment
var _reattach_delay_frames: int = 0  # Wait a few frames for physics to settle


func _ready() -> void:
	add_to_group("bolt_tool")


func _physics_process(_delta: float) -> void:
	"""Monitor bolt tension and snap bolts that are over-stressed or have invalid attachments"""
	
	# Process pending reattachments after delay
	if _pending_reattach.size() > 0:
		_reattach_delay_frames -= 1
		if _reattach_delay_frames <= 0:
			_process_pending_reattachments()
			_pending_reattach.clear()
		return  # Skip normal processing while reattaching
	
	# Iterate backwards so we can safely remove snapped bolts
	for i in range(placed_bolts.size() - 1, -1, -1):
		var bolt_data = placed_bolts[i]
		
		# Check if bodies became invalid (happens when polygons are split/recreated)
		var body1_valid = is_instance_valid(bolt_data.layer1_body)
		var body2_valid = is_instance_valid(bolt_data.layer2_body)
		
		if not body1_valid or not body2_valid:
			# Mark for reattachment - don't remove yet
			if i not in _pending_reattach:
				_pending_reattach.append(i)
				_reattach_delay_frames = 3  # Wait 3 frames for new bodies to be created
			continue
		
		# Check if attachment points still exist on the bodies (polygon region wasn't erased)
		if not _is_attachment_point_valid(bolt_data.layer1_body, bolt_data.local_anchor1):
			snap_bolt(i, true)  # Silent snap - region was erased
			continue
		if not _is_attachment_point_valid(bolt_data.layer2_body, bolt_data.local_anchor2):
			snap_bolt(i, true)  # Silent snap - region was erased
			continue
		
		# Calculate current tension (distance between anchor points in world space)
		var world_anchor1 = bolt_data.layer1_body.to_global(bolt_data.local_anchor1)
		var world_anchor2 = bolt_data.layer2_body.to_global(bolt_data.local_anchor2)
		var tension_distance = world_anchor1.distance_to(world_anchor2)
		
		# Update visual stress indicator
		update_bolt_stress_visual(bolt_data, tension_distance)
		
		# Check if bolt should snap
		if tension_distance > MAX_TENSION_DISTANCE:
			snap_bolt(i, false)


func _process_pending_reattachments() -> void:
	"""Try to reattach bolts to recreated bodies"""
	# Sort indices in reverse order for safe removal
	_pending_reattach.sort()
	_pending_reattach.reverse()
	
	for i in _pending_reattach:
		if i >= placed_bolts.size():
			continue
		
		var bolt_data = placed_bolts[i]
		var world_pos = bolt_data.position
		
		# Try to find bodies at the original world position
		var body1_valid = is_instance_valid(bolt_data.layer1_body)
		var body2_valid = is_instance_valid(bolt_data.layer2_body)
		
		var new_body1 = bolt_data.layer1_body if body1_valid else _find_body_at_world_position(world_pos, 1)
		var new_body2 = bolt_data.layer2_body if body2_valid else _find_body_at_world_position(world_pos, 2)
		
		if new_body1 == null or new_body2 == null:
			# Can't find one or both bodies - remove bolt silently
			snap_bolt(i, true)
			continue
		
		# Update body references and local anchors
		bolt_data.layer1_body = new_body1
		bolt_data.layer2_body = new_body2
		bolt_data.local_anchor1 = new_body1.to_local(world_pos)
		bolt_data.local_anchor2 = new_body2.to_local(world_pos)
		
		# Recreate joint synchronously
		_recreate_bolt_joint(bolt_data)


func _find_body_at_world_position(world_pos: Vector2, layer: int) -> PhysicsBody2D:
	"""Find a physics body at the given world position on the specified layer"""
	var space_state = get_world_2d().direct_space_state
	var query = PhysicsShapeQueryParameters2D.new()
	
	var shape = CircleShape2D.new()
	shape.radius = 12.0  # Generous detection radius for re-acquisition
	query.shape = shape
	query.transform = Transform2D(0, world_pos)
	
	# Set collision mask to only detect the specified layer
	if layer == 1:
		query.collision_mask = 1 << 0  # Layer 1 collision bit
	else:
		query.collision_mask = 1 << 1  # Layer 2 collision bit
	
	var results = space_state.intersect_shape(query, 32)
	
	for result in results:
		var collider = result.collider
		if collider is PhysicsBody2D:
			var body_layer = collider.get_meta("layer", 1)
			if body_layer == layer:
				return collider
	
	return null


func _recreate_bolt_joint(bolt_data: Dictionary) -> void:
	"""Recreate the bolt joint with updated body references (synchronous)"""
	# Clean up old joint
	if is_instance_valid(bolt_data.joint):
		bolt_data.joint.queue_free()
		bolt_data.joint = null
	
	# Can't recreate without valid bodies
	if not is_instance_valid(bolt_data.layer1_body) or not is_instance_valid(bolt_data.layer2_body):
		return
	
	# Create new joint
	var pin_joint = PinJoint2D.new()
	pin_joint.position = bolt_data.local_anchor1
	
	bolt_data.layer1_body.add_child(pin_joint)
	
	pin_joint.node_a = pin_joint.get_path_to(bolt_data.layer1_body)
	pin_joint.node_b = pin_joint.get_path_to(bolt_data.layer2_body)
	pin_joint.softness = 0.0
	pin_joint.bias = 0.95
	pin_joint.disable_collision = true
	
	# Recreate visual
	var new_visual = create_bolt_visual(Vector2.ZERO)
	pin_joint.add_child(new_visual)
	
	# Clean up old visual if it exists
	if is_instance_valid(bolt_data.visual):
		bolt_data.visual.queue_free()
	
	bolt_data.joint = pin_joint
	bolt_data.visual = new_visual


func _is_attachment_point_valid(body: PhysicsBody2D, local_pos: Vector2) -> bool:
	"""Check if the attachment point still exists on the body (polygon hasn't been erased there)"""
	if not is_instance_valid(body):
		return false
	
	# Check collision polygons directly by testing if point is inside any of them
	# Use a very small tolerance - only remove bolt if immediate area is erased
	const TOLERANCE: float = 2.0  # Very small - only the immediate area under the bolt
	
	for child in body.get_children():
		if child is CollisionPolygon2D:
			var polygon = child.polygon
			if polygon.size() < 3:
				continue
			# Transform local_pos to the child's local space (accounting for child position)
			var point_in_child = local_pos - child.position
			if Geometry2D.is_point_in_polygon(point_in_child, polygon):
				return true
			# Check with minimal tolerance for edge cases
			if _is_point_near_polygon(point_in_child, polygon, TOLERANCE):
				return true
		elif child is CollisionShape2D:
			# For regular collision shapes, check if point is within shape bounds
			var point_in_child = local_pos - child.position
			if child.shape is CircleShape2D:
				if point_in_child.length() <= child.shape.radius + TOLERANCE:
					return true
			elif child.shape is RectangleShape2D:
				var half_size = child.shape.size / 2.0 + Vector2(TOLERANCE, TOLERANCE)
				if abs(point_in_child.x) <= half_size.x and abs(point_in_child.y) <= half_size.y:
					return true
	
	return false


func _is_point_near_polygon(point: Vector2, polygon: PackedVector2Array, tolerance: float) -> bool:
	"""Check if a point is within tolerance distance of a polygon's edges or inside it"""
	# First check if inside
	if Geometry2D.is_point_in_polygon(point, polygon):
		return true
	
	# Check distance to each edge
	for i in range(polygon.size()):
		var a = polygon[i]
		var b = polygon[(i + 1) % polygon.size()]
		var closest = Geometry2D.get_closest_point_to_segment(point, a, b)
		if point.distance_to(closest) <= tolerance:
			return true
	
	return false


func snap_bolt(index: int, silent: bool = false) -> void:
	"""Snap (break) a bolt at the given index"""
	if index < 0 or index >= placed_bolts.size():
		return
	
	var bolt_data = placed_bolts[index]
	
	# Create snap effect if not silent
	if not silent and is_instance_valid(bolt_data.joint):
		create_snap_effect(bolt_data.joint.global_position)
	
	# Clean up joint and visual
	if is_instance_valid(bolt_data.joint):
		bolt_data.joint.queue_free()
	if is_instance_valid(bolt_data.visual):
		bolt_data.visual.queue_free()
	
	placed_bolts.remove_at(index)


func create_snap_effect(snap_position: Vector2) -> void:
	"""Create a visual effect when a bolt snaps"""
	# Create particle burst effect
	var effect = Node2D.new()
	effect.global_position = snap_position
	effect.z_index = 25
	get_parent().add_child(effect)
	
	# Create expanding ring
	var ring = Line2D.new()
	ring.width = 3.0
	ring.default_color = Color(1.0, 0.3, 0.0, 1.0)  # Orange
	var ring_points = PackedVector2Array()
	var segments = 16
	for j in range(segments + 1):
		var angle = (j / float(segments)) * TAU
		ring_points.append(Vector2(cos(angle), sin(angle)) * BOLT_VISUAL_RADIUS)
	ring.points = ring_points
	effect.add_child(ring)
	
	# Create debris particles (small squares flying outward)
	for k in range(6):
		var debris = Polygon2D.new()
		debris.polygon = PackedVector2Array([
			Vector2(-2, -2), Vector2(2, -2), Vector2(2, 2), Vector2(-2, 2)
		])
		debris.color = Color(0.4, 0.4, 0.4)
		var angle = (k / 6.0) * TAU + randf() * 0.5
		debris.position = Vector2(cos(angle), sin(angle)) * 5.0
		debris.set_meta("velocity", Vector2(cos(angle), sin(angle)) * (100.0 + randf() * 50.0))
		debris.set_meta("rotation_speed", randf_range(-10.0, 10.0))
		effect.add_child(debris)
	
	# Animate and clean up using a tween
	var tween = create_tween()
	tween.set_parallel(true)
	
	# Expand and fade the ring
	tween.tween_property(ring, "scale", Vector2(8.0, 8.0), 0.3)
	tween.tween_property(ring, "modulate:a", 0.0, 0.3)
	
	# Animate debris
	for child in effect.get_children():
		if child is Polygon2D and child.has_meta("velocity"):
			var velocity = child.get_meta("velocity")
			var rot_speed = child.get_meta("rotation_speed")
			tween.tween_property(child, "position", child.position + velocity * 0.3, 0.3)
			tween.tween_property(child, "rotation", rot_speed * 0.3, 0.3)
			tween.tween_property(child, "modulate:a", 0.0, 0.3)
	
	# Clean up after animation
	tween.chain().tween_callback(effect.queue_free)


func update_bolt_stress_visual(bolt_data: Dictionary, tension_distance: float) -> void:
	"""Update the bolt visual to show stress level"""
	if not is_instance_valid(bolt_data.visual):
		return
	
	var stress_ratio = tension_distance / MAX_TENSION_DISTANCE
	
	# Color transitions from gray (no stress) to orange (warning) to red (critical)
	var stress_color: Color
	if stress_ratio < STRESS_WARNING_DISTANCE / MAX_TENSION_DISTANCE:
		# Low stress - normal gray
		stress_color = Color(1.0, 1.0, 1.0, 1.0)  # White modulate (original colors)
	elif stress_ratio < 0.8:
		# Medium stress - transition to orange
		var t = (stress_ratio - STRESS_WARNING_DISTANCE / MAX_TENSION_DISTANCE) / (0.8 - STRESS_WARNING_DISTANCE / MAX_TENSION_DISTANCE)
		stress_color = Color(1.0, 1.0 - t * 0.5, 1.0 - t, 1.0)
	else:
		# High stress - transition to red with pulsing
		var pulse = (sin(Time.get_ticks_msec() * 0.02) + 1.0) * 0.5
		stress_color = Color(1.0, 0.2 + pulse * 0.3, 0.0, 1.0)
	
	bolt_data.visual.modulate = stress_color


func place_bolt(world_position: Vector2) -> void:
	"""Place a bolt at the given world position, connecting layer 1 and layer 2 objects"""
	# Find physics bodies at this position
	var layer1_body = find_body_at_position(world_position, 1)
	var layer2_body = find_body_at_position(world_position, 2)
	
	if layer1_body == null and layer2_body == null:
		return
	elif layer1_body == null:
		return
	elif layer2_body == null:
		return
	
	# Store local anchor positions for tension calculation
	var local_anchor1 = layer1_body.to_local(world_position)
	var local_anchor2 = layer2_body.to_local(world_position)
	
	# Create the bolt joint - very stiff configuration
	var pin_joint = PinJoint2D.new()
	pin_joint.position = local_anchor1
	
	# Add joint as child of layer1_body
	layer1_body.add_child(pin_joint)
	
	# Set up the joint to connect to layer2_body
	pin_joint.node_a = pin_joint.get_path_to(layer1_body)
	pin_joint.node_b = pin_joint.get_path_to(layer2_body)
	pin_joint.softness = 0.0  # Maximum stiffness (0.0 = completely rigid)
	pin_joint.bias = 0.95  # Very high bias for maximum constraint correction
	pin_joint.disable_collision = true  # Disable collision to prevent joint instability
	
	# Create visual representation attached to the joint
	var bolt_visual = create_bolt_visual(Vector2.ZERO)  # Position relative to joint
	pin_joint.add_child(bolt_visual)
	
	# Track the bolt with anchor positions for tension monitoring
	placed_bolts.append({
		"position": world_position,
		"layer1_body": layer1_body,
		"layer2_body": layer2_body,
		"joint": pin_joint,
		"visual": bolt_visual,
		"local_anchor1": local_anchor1,
		"local_anchor2": local_anchor2
	})


func find_body_at_position(position: Vector2, layer: int) -> PhysicsBody2D:
	"""Find a physics body at the given position on the specified layer"""
	# Use a shape query with a small circle for more forgiving detection
	var space_state = get_world_2d().direct_space_state
	var query = PhysicsShapeQueryParameters2D.new()
	
	# Create a small circle for detection
	var shape = CircleShape2D.new()
	shape.radius = 8.0  # Small detection radius
	query.shape = shape
	query.transform = Transform2D(0, position)
	
	# Set collision mask to only detect the specified layer
	if layer == 1:
		query.collision_mask = 1 << 0  # Layer 1 collision bit
	else:
		query.collision_mask = 1 << 1  # Layer 2 collision bit
	
	var results = space_state.intersect_shape(query, 32)  # Check more objects
	
	# Filter results by layer metadata
	for result in results:
		var collider = result.collider
		if collider is PhysicsBody2D:
			var body_layer = collider.get_meta("layer", 1)
			if body_layer == layer:
				return collider
	
	return null


func create_bolt_visual(position: Vector2) -> Node2D:
	"""Create a visual representation of a bolt"""
	var container = Node2D.new()
	container.position = position  # Use local position
	container.z_index = 20  # Above both layers
	
	# Create bolt head (outer circle)
	var outer_circle = create_circle_polygon(BOLT_VISUAL_RADIUS, Color(0.3, 0.3, 0.3))
	container.add_child(outer_circle)
	
	# Create bolt shine (inner circle)
	var inner_circle = create_circle_polygon(BOLT_VISUAL_RADIUS * 0.6, Color(0.5, 0.5, 0.5))
	container.add_child(inner_circle)
	
	# Create bolt slot (cross shape)
	var slot_line1 = Line2D.new()
	slot_line1.width = 2.0
	slot_line1.default_color = Color(0.2, 0.2, 0.2)
	slot_line1.add_point(Vector2(-BOLT_VISUAL_RADIUS * 0.5, 0))
	slot_line1.add_point(Vector2(BOLT_VISUAL_RADIUS * 0.5, 0))
	container.add_child(slot_line1)
	
	var slot_line2 = Line2D.new()
	slot_line2.width = 2.0
	slot_line2.default_color = Color(0.2, 0.2, 0.2)
	slot_line2.add_point(Vector2(0, -BOLT_VISUAL_RADIUS * 0.5))
	slot_line2.add_point(Vector2(0, BOLT_VISUAL_RADIUS * 0.5))
	container.add_child(slot_line2)
	
	return container


func create_circle_polygon(radius: float, color: Color) -> Polygon2D:
	"""Create a circular polygon"""
	var polygon = Polygon2D.new()
	var points = PackedVector2Array()
	var segments = 16
	
	for i in range(segments):
		var angle = (i / float(segments)) * TAU
		points.append(Vector2(cos(angle), sin(angle)) * radius)
	
	polygon.polygon = points
	polygon.color = color
	return polygon


func remove_bolt_at_position(position: Vector2, threshold: float = 16.0) -> bool:
	"""Remove a bolt near the given position"""
	for i in range(placed_bolts.size() - 1, -1, -1):
		var bolt_data = placed_bolts[i]
		if bolt_data.position.distance_to(position) < threshold:
			# Clean up joint and visual
			if is_instance_valid(bolt_data.joint):
				bolt_data.joint.queue_free()
			if is_instance_valid(bolt_data.visual):
				bolt_data.visual.queue_free()
			
			placed_bolts.remove_at(i)
			return true
	
	return false
