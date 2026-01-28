extends RigidBody2D
## RigidBody2D Player controller with physics interactions
## Supports pushing objects, rolling circular objects, and grabbing plaster materials

signal fly_mode_changed(active: bool)
signal layer_changed(new_layer: int)
signal grab_state_changed(is_grabbing: bool, grabbed_object: RigidBody2D)

# Movement constants (force-based)
const MOVE_FORCE = 2000.0  # Horizontal movement force
const FLY_FORCE = 1200.0  # Force in fly mode
const MAX_SPEED = 200.0  # Maximum horizontal speed
const FLY_MAX_SPEED = 250.0  # Maximum speed in fly mode
const JUMP_IMPULSE = 450.0  # Upward impulse for jumping (halved)
const AIR_CONTROL_MULTIPLIER = 0.7  # Reduced control in air

# Grab constants
const GRAB_FORCE_GROUNDED = 1.0  # Full force when grounded
const GRAB_FORCE_AIRBORNE = 0.3  # Reduced force when airborne
const GRAB_BREAK_DISTANCE = 60.0  # Distance at which grab breaks
const GRAB_STIFFNESS = 50.0  # Spring stiffness for grab joint
const GRAB_DAMPING = 5.0  # Damping for grab joint

# Push/roll constants
const PUSH_FORCE_MULTIPLIER = 0.8  # Force transferred when pushing
const ROLL_TORQUE_MULTIPLIER = 50.0  # Torque applied to circular objects

# Layer system constants
const FRONT_LAYER = 0
const BACK_LAYER = 1
const FRONT_LAYER_TINT = Color(1.0, 1.0, 1.0, 1.0)
const BACK_LAYER_TINT = Color(0.7, 0.7, 0.7, 1.0)
const FRONT_LAYER_SCALE = Vector2(1.0, 1.0)
const BACK_LAYER_SCALE = Vector2(0.85, 0.85)
const FRONT_LAYER_Z_INDEX = 10
const BACK_LAYER_Z_INDEX = 0
const FLY_MODE_SCALE = Vector2(1.15, 1.15)
const FRONT_COLLISION_MASK = 1 | 4 | 8
const BACK_COLLISION_MASK = 2 | 4 | 8
const FRONT_COLLISION_LAYER = 1
const BACK_COLLISION_LAYER = 2

# Layer state
var current_layer: int = FRONT_LAYER

# References
var cursor: Node2D = null
@onready var sprite: Sprite2D = $Sprite2D
@onready var ground_raycast: RayCast2D = $GroundRayCast
@onready var grab_area: Area2D = $GrabArea

# Fly mode state
var is_fly_mode: bool = false
var drag_velocity: Vector2 = Vector2.ZERO
var original_collision_mask: int = 0
var original_collision_layer: int = 0
var original_z_index: int = 0
var original_scale: Vector2 = Vector2(1.0, 1.0)
var original_gravity_scale: float = 1.0

# Grab state
var grabbed_object: RigidBody2D = null
var grab_joint: PinJoint2D = null
var grab_offset: Vector2 = Vector2.ZERO
var is_grabbing: bool = false

# Facing direction (for grab area positioning)
var facing_direction: int = 1  # 1 = right, -1 = left

# Landing velocity preservation
var was_grounded: bool = true
var pre_landing_velocity_x: float = 0.0
var just_landed: bool = false  # Flag for _physics_process to also restore velocity

# Push tracking to prevent twitching
var push_cooldowns: Dictionary = {}  # Object RID -> cooldown timer
const PUSH_COOLDOWN_TIME = 0.15  # Seconds before same object can be pushed again
var objects_being_pushed: Array[RigidBody2D] = []  # Objects currently in contact

# Jump state to prevent climbing on objects
var is_jumping: bool = false  # True when player initiated a jump


func _integrate_forces(state: PhysicsDirectBodyState2D) -> void:
	# Check if we just landed by looking at contacts
	var is_grounded_now = false
	var contacted_bodies: Array[RigidBody2D] = []
	var has_climbable_rigidbody_slope = false  # True if any RigidBody2D contact is climbable
	var touching_rigidbody = false
	
	# Slope threshold: 75 degrees from horizontal
	# cos(75°) ≈ 0.259, so normal.y must be <= -0.259 for climbable slope
	const CLIMBABLE_SLOPE_THRESHOLD = -0.259
	
	for i in range(state.get_contact_count()):
		var normal = state.get_contact_local_normal(i)
		if normal.y < -0.5:
			is_grounded_now = true
		
		# Track RigidBody2D contacts for continuous pushing
		var collider = state.get_contact_collider_object(i)
		if collider is RigidBody2D and collider != self:
			touching_rigidbody = true
			if not contacted_bodies.has(collider):
				contacted_bodies.append(collider)
			
			# Check if this contact has a climbable slope (75° or less from horizontal)
			if normal.y <= CLIMBABLE_SLOPE_THRESHOLD:
				has_climbable_rigidbody_slope = true
	
	# Update list of objects being pushed
	objects_being_pushed = contacted_bodies
	
	# Prevent climbing on objects - if touching a RigidBody2D with steep slope and not jumping,
	# clamp upward velocity to prevent collision response from lifting the player
	if touching_rigidbody and not is_jumping and not has_climbable_rigidbody_slope:
		var vel = state.get_linear_velocity()
		if vel.y < 0:  # Moving upward
			vel.y = 0  # Cancel upward movement from collision
			state.set_linear_velocity(vel)
			print("[CLIMB_BLOCK] Prevented climbing - slope too steep (>75°)")
	
	# Reset jump state when grounded
	if is_grounded_now:
		is_jumping = false
	
	# Preserve horizontal velocity when landing
	if is_grounded_now and not was_grounded:
		# Restore horizontal velocity that collision tried to kill
		var vel = state.get_linear_velocity()
		vel.x = pre_landing_velocity_x
		state.set_linear_velocity(vel)
		just_landed = true  # Tell _physics_process to also restore
		print("[LAND] Restored vel.x to ", pre_landing_velocity_x)
	
	# Track velocity while airborne for next landing
	if not is_grounded_now:
		pre_landing_velocity_x = state.get_linear_velocity().x
	
	was_grounded = is_grounded_now


func _ready() -> void:
	add_to_group("player")
	
	# Ensure body is not frozen and cannot sleep
	freeze = false
	sleeping = false
	can_sleep = false
	
	# Store original settings
	original_collision_mask = collision_mask
	original_collision_layer = collision_layer
	original_z_index = z_index
	original_scale = scale
	original_gravity_scale = gravity_scale
	
	# Initialize layer appearance
	_update_layer_appearance()
	_update_layer_collision()
	
	# Connect body signals for push detection
	body_entered.connect(_on_body_entered)
	
	# Find cursor after scene is ready
	await get_tree().process_frame
	cursor = get_tree().get_first_node_in_group("cursor")


func _input(event: InputEvent) -> void:
	# Toggle fly mode with O key
	if event is InputEventKey and event.pressed and event.keycode == KEY_O:
		toggle_fly_mode()
	
	# Layer switching (disabled in fly mode)
	if event is InputEventKey and event.pressed and not event.echo and not is_fly_mode:
		if event.keycode == KEY_UP or event.keycode == KEY_W:
			switch_to_layer(BACK_LAYER)
		elif event.keycode == KEY_DOWN or event.keycode == KEY_S:
			switch_to_layer(FRONT_LAYER)
	
	# Grab input with Shift (disabled in fly mode)
	if event is InputEventKey and not is_fly_mode:
		if event.keycode == KEY_SHIFT:
			if event.pressed and not is_grabbing:
				_try_grab()
			elif not event.pressed and is_grabbing:
				_release_grab()


func _physics_process(delta: float) -> void:
	# Restore velocity immediately if we just landed (before any rendering)
	if just_landed:
		linear_velocity.x = pre_landing_velocity_x
		just_landed = false
	
	_update_facing_direction()
	_update_grab_area_position()
	
	if is_fly_mode:
		_handle_fly_mode(delta)
	else:
		_handle_platformer_mode(delta)
		_handle_grab_physics(delta)
		_process_continuous_push(delta)
	
	# Clamp velocity to max speed
	_clamp_velocity()


func _handle_platformer_mode(delta: float) -> void:
	var is_grounded = _is_on_floor()
	var old_vel = linear_velocity
	
	# Don't accept movement input if cursor mode is active
	var cursor_active = cursor and cursor.has_method("is_cursor_active") and cursor.is_cursor_active()
	
	if cursor_active:
		# Apply counter-force to slow down horizontal movement
		if abs(linear_velocity.x) > 10:
			apply_central_force(Vector2(-sign(linear_velocity.x) * MOVE_FORCE * 0.5, 0))
		return
	
	# Handle jump - set velocity directly since impulse doesn't work properly
	if Input.is_action_just_pressed("ui_accept") and is_grounded and not is_grabbing:
		# Calculate jump velocity: impulse / mass
		var jump_velocity = -JUMP_IMPULSE / mass
		linear_velocity.y = jump_velocity
		is_jumping = true  # Mark that player initiated a jump
		print("[JUMP] vel.y set to ", linear_velocity.y)
	
	# Get horizontal input
	var direction := Input.get_axis("ui_left", "ui_right")
	if direction == 0:
		direction = Input.get_axis("move_left", "move_right")
	
	var action = "none"
	
	if direction != 0:
		# Set velocity directly to target speed when grounded for consistent movement
		# Use gradual acceleration only in air for more floaty air control
		var target_speed = direction * MAX_SPEED
		if is_grounded:
			# Grounded: instant full speed (overrides collision friction)
			linear_velocity.x = target_speed
		else:
			# Airborne: gradual acceleration with reduced control
			var new_vel_x = move_toward(linear_velocity.x, target_speed, MOVE_FORCE * AIR_CONTROL_MULTIPLIER * delta)
			linear_velocity.x = new_vel_x
		action = "move dir=" + str(direction) + " target=" + str(target_speed)
	else:
		# Apply friction to slow down when no input
		if is_grounded:
			var new_vel_x = move_toward(linear_velocity.x, 0, MOVE_FORCE * 2 * delta)
			linear_velocity.x = new_vel_x
			action = "friction (grounded)"
		else:
			action = "no input (air)"
	
	# Log when velocity changes significantly or every half second
	var vel_changed = abs(linear_velocity.x - old_vel.x) > 5 or abs(linear_velocity.y - old_vel.y) > 5
	if vel_changed or Engine.get_physics_frames() % 30 == 0:
		print("[Move] grounded=", is_grounded, " vel=", snapped(linear_velocity, Vector2(0.1, 0.1)), " action=", action, " delta=", snapped(delta, 0.001), " linear_damp=", linear_damp)


func _handle_fly_mode(delta: float) -> void:
	var cursor_active = cursor and cursor.has_method("is_cursor_active") and cursor.is_cursor_active()
	
	if cursor_active:
		# Apply drag velocity from cursor
		linear_velocity = drag_velocity
	else:
		# Free flight with omnidirectional movement
		var direction := Vector2.ZERO
		var horizontal = Input.get_axis("ui_left", "ui_right")
		if horizontal == 0:
			horizontal = Input.get_axis("move_left", "move_right")
		var vertical = Input.get_axis("ui_up", "ui_down")
		if vertical == 0:
			vertical = Input.get_axis("move_up", "move_down")
		direction.x = horizontal
		direction.y = vertical
		
		if direction != Vector2.ZERO:
			direction = direction.normalized()
			apply_central_force(direction * FLY_FORCE)
		else:
			# Apply damping when no input
			if linear_velocity.length() > 10:
				apply_central_force(-linear_velocity.normalized() * FLY_FORCE * 0.5)


func _clamp_velocity() -> void:
	var max_spd = FLY_MAX_SPEED if is_fly_mode else MAX_SPEED
	if not is_fly_mode:
		# Only clamp horizontal in platformer mode
		linear_velocity.x = clamp(linear_velocity.x, -max_spd, max_spd)
	else:
		# Clamp total velocity in fly mode
		if linear_velocity.length() > max_spd:
			linear_velocity = linear_velocity.normalized() * max_spd


func _is_on_floor() -> bool:
	# Use PhysicsDirectBodyState2D for contact detection
	var state = PhysicsServer2D.body_get_direct_state(get_rid())
	if state and state.get_contact_count() > 0:
		for i in range(state.get_contact_count()):
			var contact_normal = state.get_contact_local_normal(i)
			# If normal points up, we're resting on something below
			if contact_normal.y < -0.5:
				return true
	
	# Fallback to raycast
	if ground_raycast and ground_raycast.is_colliding():
		return true
	
	return false


func _update_facing_direction() -> void:
	var horizontal = Input.get_axis("ui_left", "ui_right")
	if horizontal == 0:
		horizontal = Input.get_axis("move_left", "move_right")
	
	if horizontal != 0:
		facing_direction = int(sign(horizontal))


func _update_grab_area_position() -> void:
	if grab_area:
		# Position grab area in front of player based on facing direction
		var grab_shape = grab_area.get_node_or_null("GrabShape")
		if grab_shape:
			grab_shape.position.x = 12 * facing_direction


# ============== GRAB MECHANICS ==============

func _try_grab() -> void:
	if is_fly_mode:
		return
	
	# Get bodies overlapping grab area
	var bodies = grab_area.get_overlapping_bodies()
	
	for body in bodies:
		if body is RigidBody2D and body != self:
			# Check if object is grabbable (plaster material or low mass)
			if _is_grabbable(body):
				_grab_object(body)
				return


func _is_grabbable(body: RigidBody2D) -> bool:
	# Check for plaster material
	if body.has_meta("material_regions"):
		var regions = body.get_meta("material_regions")
		for region in regions:
			if region is MaterialRegion and region.material:
				# Check if it's plaster (density 0.4) or similarly light material
				if region.material.density <= 0.5:
					return true
	
	# Also allow grabbing light objects (mass threshold)
	if body.mass <= 2.0:
		return true
	
	return false


func _grab_object(body: RigidBody2D) -> void:
	grabbed_object = body
	is_grabbing = true
	
	# Calculate grab offset (where we're grabbing the object)
	grab_offset = body.global_position - global_position
	
	# Create a pin joint to connect player to object
	grab_joint = PinJoint2D.new()
	grab_joint.node_a = get_path()
	grab_joint.node_b = body.get_path()
	grab_joint.softness = 1.0 / GRAB_STIFFNESS
	add_child(grab_joint)
	
	grab_state_changed.emit(true, grabbed_object)


func _release_grab() -> void:
	if grab_joint:
		grab_joint.queue_free()
		grab_joint = null
	
	var old_grabbed = grabbed_object
	grabbed_object = null
	is_grabbing = false
	grab_offset = Vector2.ZERO
	
	grab_state_changed.emit(false, old_grabbed)


func _handle_grab_physics(delta: float) -> void:
	if not is_grabbing or not grabbed_object or not is_instance_valid(grabbed_object):
		if is_grabbing:
			_release_grab()
		return
	
	# Check if grab should break due to distance
	var current_distance = global_position.distance_to(grabbed_object.global_position)
	if current_distance > GRAB_BREAK_DISTANCE:
		_release_grab()
		return
	
	# Apply movement force to grabbed object based on player's movement
	var is_grounded = _is_on_floor()
	var force_multiplier = GRAB_FORCE_GROUNDED if is_grounded else GRAB_FORCE_AIRBORNE
	
	# Transfer some of player's movement intention to grabbed object
	var horizontal = Input.get_axis("ui_left", "ui_right")
	if horizontal == 0:
		horizontal = Input.get_axis("move_left", "move_right")
	
	if horizontal != 0:
		var grab_force = horizontal * MOVE_FORCE * force_multiplier * 0.5
		grabbed_object.apply_central_force(Vector2(grab_force, 0))


# ============== PUSH/ROLL MECHANICS ==============

func _on_body_entered(body: Node) -> void:
	# Initial contact - only used for logging now, actual push is continuous
	if body is RigidBody2D and body != self and not is_grabbing:
		print("[PUSH] Contact with: ", body.name)


func _process_continuous_push(delta: float) -> void:
	# Update cooldowns
	var rids_to_remove: Array = []
	for rid in push_cooldowns:
		push_cooldowns[rid] -= delta
		if push_cooldowns[rid] <= 0:
			rids_to_remove.append(rid)
	for rid in rids_to_remove:
		push_cooldowns.erase(rid)
	
	# Process objects we're currently in contact with
	for body in objects_being_pushed:
		if not is_instance_valid(body) or is_grabbing:
			continue
		
		var rid = body.get_rid()
		
		# Skip if on cooldown
		if push_cooldowns.has(rid):
			continue
		
		# Only push if we're actively moving toward the object
		var to_body = (body.global_position - global_position).normalized()
		var velocity_toward = linear_velocity.dot(to_body)
		
		if velocity_toward > 10:  # Moving toward object at reasonable speed
			_apply_push_force(body)
			push_cooldowns[rid] = PUSH_COOLDOWN_TIME


func _apply_push_force(body: RigidBody2D) -> void:
	# Calculate push direction from player to object
	var push_direction = (body.global_position - global_position).normalized()
	
	# Calculate push force based on player's velocity
	var push_magnitude = linear_velocity.length() * PUSH_FORCE_MULTIPLIER
	var push_force = push_direction * push_magnitude * mass
	
	# Apply force to the object
	body.apply_central_impulse(push_force)
	print("[PUSH] Applied force ", snapped(push_force.length(), 0.1), " to ", body.name, " dir=", snapped(push_direction, Vector2(0.01, 0.01)))
	
	# Check if object has circular collision for rolling
	if _has_circular_collision(body):
		_apply_roll_torque(body, push_direction)


func _has_circular_collision(body: RigidBody2D) -> bool:
	for child in body.get_children():
		if child is CollisionShape2D:
			var shape = child.shape
			if shape is CircleShape2D:
				return true
	return false


func _apply_roll_torque(body: RigidBody2D, push_direction: Vector2) -> void:
	# Apply torque to make circular object roll
	# Torque direction depends on push direction (push right = roll clockwise)
	var torque = push_direction.x * linear_velocity.length() * ROLL_TORQUE_MULTIPLIER
	body.apply_torque(torque)


# ============== FLY MODE ==============

func toggle_fly_mode() -> void:
	is_fly_mode = not is_fly_mode
	
	# Release grab when entering fly mode
	if is_fly_mode and is_grabbing:
		_release_grab()
	
	# If trying to exit fly mode, check if front layer is clear
	if not is_fly_mode and not _is_layer_clear(FRONT_LAYER):
		is_fly_mode = true  # Stay in fly mode
		return
	
	fly_mode_changed.emit(is_fly_mode)
	
	if is_fly_mode:
		# Enable fly mode
		collision_mask = 12  # Ground and boundaries only
		collision_layer = 0  # Don't exist on any layer
		z_index = 100
		scale = FLY_MODE_SCALE
		gravity_scale = 0.0  # No gravity in fly mode
		if sprite:
			sprite.modulate = FRONT_LAYER_TINT
	else:
		# Restore normal mode
		current_layer = FRONT_LAYER
		collision_mask = original_collision_mask
		collision_layer = original_collision_layer
		z_index = original_z_index
		drag_velocity = Vector2.ZERO
		gravity_scale = original_gravity_scale
		_update_layer_appearance()
		_update_layer_collision()


func set_drag_velocity(vel: Vector2) -> void:
	"""Called by cursor controller to drag player in fly mode"""
	if is_fly_mode:
		drag_velocity = vel


# ============== LAYER SYSTEM ==============

func switch_to_layer(new_layer: int) -> void:
	if current_layer == new_layer:
		return
	
	if not _is_layer_clear(new_layer):
		return
	
	current_layer = new_layer
	_update_layer_appearance()
	_update_layer_collision()
	layer_changed.emit(current_layer)


func _is_layer_clear(target_layer: int) -> bool:
	var current_mask = collision_mask
	var current_col_layer = collision_layer
	
	if target_layer == BACK_LAYER:
		collision_mask = BACK_COLLISION_MASK
	else:
		collision_mask = FRONT_COLLISION_MASK
	
	# Use shape query for RigidBody2D
	var space_state = get_world_2d().direct_space_state
	var query = PhysicsShapeQueryParameters2D.new()
	
	# Get player's collision shape
	var collision_shape = get_node_or_null("CollisionShape2D")
	if collision_shape and collision_shape.shape:
		query.shape = collision_shape.shape
		query.transform = global_transform
		query.collision_mask = collision_mask
		query.exclude = [get_rid()]
		
		var result = space_state.intersect_shape(query, 1)
		
		# Restore original settings
		collision_mask = current_mask
		collision_layer = current_col_layer
		
		return result.is_empty()
	
	# Restore if no shape found
	collision_mask = current_mask
	collision_layer = current_col_layer
	return true


func _update_layer_appearance() -> void:
	if not sprite:
		return
	
	if is_fly_mode:
		return
	
	if current_layer == BACK_LAYER:
		sprite.modulate = BACK_LAYER_TINT
		scale = BACK_LAYER_SCALE
		z_index = BACK_LAYER_Z_INDEX
	else:
		sprite.modulate = FRONT_LAYER_TINT
		scale = FRONT_LAYER_SCALE
		z_index = FRONT_LAYER_Z_INDEX


func _update_layer_collision() -> void:
	if is_fly_mode:
		return
	
	if current_layer == BACK_LAYER:
		collision_mask = BACK_COLLISION_MASK
		collision_layer = BACK_COLLISION_LAYER
	else:
		collision_mask = FRONT_COLLISION_MASK
		collision_layer = FRONT_COLLISION_LAYER
	
	if not is_fly_mode:
		original_collision_mask = collision_mask
		original_collision_layer = collision_layer
		original_z_index = z_index
