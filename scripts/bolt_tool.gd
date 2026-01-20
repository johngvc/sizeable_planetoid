extends Node2D
## Manages placing bolts that connect Layer 1 and Layer 2 objects

const BOLT_VISUAL_RADIUS: float = 4.0
const DETECTION_RADIUS: float = 20.0  # How close to stroke we need to click

# Track all placed bolts
var placed_bolts: Array = []  # Array of { position: Vector2, layer1_body: PhysicsBody2D, layer2_body: PhysicsBody2D, joint: PinJoint2D, visual: Node2D }

# Track preview bolts (not yet converted to physics joints)
var preview_bolts: Array = []  # Array of { position: Vector2, layer1_index: int, layer2_index: int, visual: Node2D }


func _ready() -> void:
	add_to_group("bolt_tool")


func place_bolt(world_position: Vector2) -> void:
	"""Place a bolt at the given world position, connecting layer 1 and layer 2 objects"""
	# First, try to find preview strokes at this position
	var layer1_index = find_preview_stroke_at_position(world_position, 1)
	var layer2_index = find_preview_stroke_at_position(world_position, 2)
	
	# If we found preview strokes, create a preview bolt
	if layer1_index >= 0 and layer2_index >= 0:
		create_preview_bolt(world_position, layer1_index, layer2_index)
		return
	
	# Otherwise, try to find physics bodies
	var layer1_body = find_body_at_position(world_position, 1)
	var layer2_body = find_body_at_position(world_position, 2)
	
	if layer1_body == null and layer2_body == null:
		if layer1_index < 0 and layer2_index < 0:
			print("⚠ No objects found at bolt position")
		elif layer1_index < 0:
			print("⚠ No Layer 1 (Front) object found at bolt position")
		else:
			print("⚠ No Layer 2 (Back) object found at bolt position")
		return
	elif layer1_body == null:
		print("⚠ No Layer 1 (Front) physics object found at bolt position")
		return
	elif layer2_body == null:
		print("⚠ No Layer 2 (Back) physics object found at bolt position")
		return
	
	# Create the bolt joint - very stiff configuration
	var pin_joint = PinJoint2D.new()
	pin_joint.position = layer1_body.to_local(world_position)
	
	# Add joint as child of layer1_body
	layer1_body.add_child(pin_joint)
	
	# Set up the joint to connect to layer2_body
	pin_joint.node_a = pin_joint.get_path_to(layer1_body)
	pin_joint.node_b = pin_joint.get_path_to(layer2_body)
	pin_joint.softness = 0.0  # Maximum stiffness (0.0 = completely rigid)
	pin_joint.bias = 0.9  # High bias for strong constraint correction
	pin_joint.disable_collision = true  # Disable collision to prevent joint instability
	
	# Create visual representation attached to the joint
	var bolt_visual = create_bolt_visual(Vector2.ZERO)  # Position relative to joint
	pin_joint.add_child(bolt_visual)
	
	# Track the bolt
	placed_bolts.append({
		"position": world_position,
		"layer1_body": layer1_body,
		"layer2_body": layer2_body,
		"joint": pin_joint,
		"visual": bolt_visual
	})
	
	print("✓ Bolt placed connecting Layer 1 and Layer 2 objects")


func find_preview_stroke_at_position(position: Vector2, layer: int) -> int:
	"""Find a preview stroke at the given position on the specified layer. Returns stroke index or -1"""
	var draw_manager = get_tree().get_first_node_in_group("draw_manager")
	if draw_manager == null:
		return -1
	
	# Check all strokes in draw_manager
	for i in range(draw_manager.all_strokes.size()):
		var stroke_data = draw_manager.all_strokes[i]
		var stroke_layer = stroke_data.get("layer", 1)
		
		# Only check strokes on the specified layer
		if stroke_layer != layer:
			continue
		
		var points: Array = stroke_data["points"]
		
		# Check if position is near any point in the stroke
		for point in points:
			if position.distance_to(point) < DETECTION_RADIUS:
				return i
	
	return -1


func create_preview_bolt(world_position: Vector2, layer1_index: int, layer2_index: int) -> void:
	"""Create a visual bolt for preview mode that will be converted to a joint later"""
	# Create visual representation
	var bolt_visual = create_bolt_visual(world_position)
	get_parent().add_child(bolt_visual)
	
	# Track the preview bolt
	preview_bolts.append({
		"position": world_position,
		"layer1_index": layer1_index,
		"layer2_index": layer2_index,
		"visual": bolt_visual
	})
	
	print("✓ Preview bolt placed - will connect when objects are converted to physics")


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
			print("Bolt removed")
			return true
	
	return false


func cleanup_invalid_bolts() -> void:
	"""Remove bolts whose connected bodies no longer exist"""
	for i in range(placed_bolts.size() - 1, -1, -1):
		var bolt_data = placed_bolts[i]
		
		if not is_instance_valid(bolt_data.layer1_body) or not is_instance_valid(bolt_data.layer2_body):
			if is_instance_valid(bolt_data.joint):
				bolt_data.joint.queue_free()
			if is_instance_valid(bolt_data.visual):
				bolt_data.visual.queue_free()
			
			placed_bolts.remove_at(i)


func convert_preview_bolts_to_joints() -> void:
	"""Convert all preview bolts to actual physics joints after strokes become bodies"""
	var draw_manager = get_tree().get_first_node_in_group("draw_manager")
	if draw_manager == null:
		return
	
	# Try to convert each preview bolt
	for preview_bolt in preview_bolts:
		var position = preview_bolt.position
		
		# Find the physics bodies that were created from these stroke indices
		var layer1_body = find_body_at_position(position, 1)
		var layer2_body = find_body_at_position(position, 2)
		
		if layer1_body != null and layer2_body != null:
			# Create the bolt joint - very stiff configuration
			var pin_joint = PinJoint2D.new()
			pin_joint.position = layer1_body.to_local(position)
			
			# Add joint as child of layer1_body
			layer1_body.add_child(pin_joint)
			
			# Set up the joint to connect to layer2_body
			pin_joint.node_a = pin_joint.get_path_to(layer1_body)
			pin_joint.node_b = pin_joint.get_path_to(layer2_body)
			pin_joint.softness = 0.0  # Maximum stiffness (0.0 = completely rigid)
			pin_joint.bias = 0.9  # High bias for strong constraint correction
			pin_joint.disable_collision = true  # Disable collision to prevent joint instability
			
			# Remove the old preview visual
			if is_instance_valid(preview_bolt.visual):
				preview_bolt.visual.queue_free()
			
			# Create new visual attached to the joint
			var bolt_visual = create_bolt_visual(Vector2.ZERO)
			pin_joint.add_child(bolt_visual)
			
			# Track the bolt
			placed_bolts.append({
				"position": position,
				"layer1_body": layer1_body,
				"layer2_body": layer2_body,
				"joint": pin_joint,
				"visual": bolt_visual
			})
			
			print("✓ Preview bolt converted to physics joint")
		else:
			# Clean up preview visual if bodies weren't found
			if is_instance_valid(preview_bolt.visual):
				preview_bolt.visual.queue_free()
	
	# Clear preview bolts array
	preview_bolts.clear()
