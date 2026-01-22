extends CharacterBody2D
## Player controller for 2D platformer movement

signal fly_mode_changed(active: bool)
signal layer_changed(new_layer: int)

# Movement constants
const SPEED = 200.0
const FLY_SPEED = 250.0
const ACCELERATION = 2000.0  # Pixels per second squared
const FLY_ACCELERATION = 1800.0  # Pixels per second squared in fly mode
const FRICTION = 2400.0  # Deceleration when no input
const JUMP_VELOCITY = -400.0

# Layer system constants
const FRONT_LAYER = 0  # Front/close layer
const BACK_LAYER = 1   # Back/far layer
const FRONT_LAYER_TINT = Color(1.0, 1.0, 1.0, 1.0)  # Normal color
const BACK_LAYER_TINT = Color(0.7, 0.7, 0.7, 1.0)   # Darker tint
const FRONT_LAYER_SCALE = Vector2(1.0, 1.0)  # Normal scale
const BACK_LAYER_SCALE = Vector2(0.85, 0.85)  # Smaller scale for farther layer
const FRONT_LAYER_Z_INDEX = 10  # Front layer z-index
const BACK_LAYER_Z_INDEX = 0   # Back layer z-index (lower = behind)
const FLY_MODE_SCALE = Vector2(1.15, 1.15)  # Slightly larger in fly mode
# Collision masks: Layer bits - 1 (front), 2 (back), 4 (shared/ground), 8 (boundaries)
const FRONT_COLLISION_MASK = 1 | 4 | 8  # Bit 0 (front only), bit 2 (shared), bit 3 (boundaries)
const BACK_COLLISION_MASK = 2 | 4 | 8   # Bit 1 (back only), bit 2 (shared), bit 3 (boundaries)
const FRONT_COLLISION_LAYER = 1  # Player exists on front layer
const BACK_COLLISION_LAYER = 2   # Player exists on back layer

# Get the gravity from the project settings
var gravity = ProjectSettings.get_setting("physics/2d/default_gravity")

# Layer state
var current_layer: int = FRONT_LAYER

# Reference to cursor for checking if cursor mode is active
var cursor: Node2D = null

# Reference to sprite for tinting
@onready var sprite: Sprite2D = $Sprite2D

# Fly mode state
var is_fly_mode: bool = false
var drag_velocity: Vector2 = Vector2.ZERO  # Velocity from cursor dragging
var original_collision_mask: int = 0  # Store original collision mask
var original_collision_layer: int = 0  # Store original collision layer
var original_z_index: int = 0  # Store original z-index
var original_scale: Vector2 = Vector2(1.0, 1.0)  # Store original scale


func _ready() -> void:
	# Add player to group so cursor can find us
	add_to_group("player")
	
	# Store original collision settings
	original_collision_mask = collision_mask
	original_collision_layer = collision_layer
	original_z_index = z_index
	original_scale = scale
	
	# Initialize to front layer
	_update_layer_appearance()
	_update_layer_collision()
	
	# Find cursor after scene is ready
	await get_tree().process_frame
	cursor = get_tree().get_first_node_in_group("cursor")


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_O:
		toggle_fly_mode()
	
	# Layer switching with Up/Down arrows and W/S keys
	if event is InputEventKey and event.pressed and not event.echo:
		# Don't allow layer changes in fly mode
		if is_fly_mode:
			return
		
		if event.keycode == KEY_UP or event.keycode == KEY_W:
			switch_to_layer(BACK_LAYER)
		elif event.keycode == KEY_DOWN or event.keycode == KEY_S:
			switch_to_layer(FRONT_LAYER)


func toggle_fly_mode() -> void:
	is_fly_mode = not is_fly_mode
	
	# If trying to exit fly mode, check if front layer is clear
	if not is_fly_mode and not _is_layer_clear(FRONT_LAYER):
		# Can't exit fly mode - front layer is blocked
		is_fly_mode = true  # Stay in fly mode
		return
	
	fly_mode_changed.emit(is_fly_mode)
	
	if is_fly_mode:
		# Enable fly mode: detect collisions with ground and boundaries
		collision_mask = 12  # Detect bit 2 (ground/shared) and bit 3 (boundaries)
		collision_layer = 0  # Don't exist on any layer (other objects won't collide with us)
		z_index = 100  # Draw in foreground
		scale = FLY_MODE_SCALE  # Increase size in fly mode
		if sprite:
			sprite.modulate = FRONT_LAYER_TINT  # Remove any tint in fly mode
	else:
		# Restore original settings and always go to front layer
		current_layer = FRONT_LAYER
		collision_mask = original_collision_mask
		collision_layer = original_collision_layer
		z_index = original_z_index
		drag_velocity = Vector2.ZERO
		# Restore scale and appearance based on front layer
		_update_layer_appearance()
		_update_layer_collision()


func set_drag_velocity(vel: Vector2) -> void:
	"""Called by cursor controller to drag player in fly mode"""
	if is_fly_mode:
		drag_velocity = vel


func _physics_process(delta: float) -> void:
	if is_fly_mode:
		_handle_fly_mode(delta)
	else:
		_handle_platformer_mode(delta)
	
	move_and_slide()


func _handle_fly_mode(delta: float) -> void:
	# In fly mode, no gravity
	var cursor_is_active = cursor and cursor.has_method("is_cursor_active") and cursor.is_cursor_active()
	
	if cursor_is_active:
		# In cursor mode + fly mode, apply drag velocity from cursor
		velocity = drag_velocity
	else:
		# Free flight with omnidirectional movement
		var direction := Vector2.ZERO
		# Support both arrow keys and WASD
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
			# Smooth acceleration toward target speed
			var target_velocity = direction * FLY_SPEED
			velocity = velocity.move_toward(target_velocity, FLY_ACCELERATION * delta)
		else:
			# Apply smooth friction when not moving
			velocity = velocity.move_toward(Vector2.ZERO, FRICTION * delta)


func _handle_platformer_mode(delta: float) -> void:
	# Add the gravity
	if not is_on_floor():
		velocity.y += gravity * delta

	# Don't accept movement input if cursor mode is active
	if cursor and cursor.has_method("is_cursor_active") and cursor.is_cursor_active():
		# Still apply physics but no input - smooth deceleration
		velocity.x = move_toward(velocity.x, 0, FRICTION * delta)
		return

	# Handle jump
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	# Get the input direction: -1, 0, 1 (support both arrow keys and WASD)
	var direction := Input.get_axis("ui_left", "ui_right")
	if direction == 0:
		direction = Input.get_axis("move_left", "move_right")
	
	# Apply smooth horizontal movement
	if direction:
		velocity.x = move_toward(velocity.x, direction * SPEED, ACCELERATION * delta)
	else:
		# Apply smooth friction when not moving
		velocity.x = move_toward(velocity.x, 0, FRICTION * delta)


func switch_to_layer(new_layer: int) -> void:
	"""Switch the player to a different depth layer"""
	if current_layer == new_layer:
		return  # Already on this layer
	
	# Check if the target layer is clear before switching
	if not _is_layer_clear(new_layer):
		return  # Can't switch - something is blocking
	
	current_layer = new_layer
	_update_layer_appearance()
	_update_layer_collision()
	layer_changed.emit(current_layer)


func _is_layer_clear(target_layer: int) -> bool:
	"""Check if the player can safely switch to the target layer"""
	# Store current collision settings
	var current_mask = collision_mask
	var current_col_layer = collision_layer
	
	# Temporarily set collision to target layer to test
	if target_layer == BACK_LAYER:
		collision_mask = BACK_COLLISION_MASK
	else:
		collision_mask = FRONT_COLLISION_MASK
	
	# Test if there's a collision at the current position with the new layer mask
	var collision_params = PhysicsTestMotionParameters2D.new()
	collision_params.from = global_transform
	collision_params.motion = Vector2.ZERO
	collision_params.collide_separation_ray = true
	
	var result = PhysicsTestMotionResult2D.new()
	var has_collision = PhysicsServer2D.body_test_motion(get_rid(), collision_params, result)
	
	# Restore original collision settings
	collision_mask = current_mask
	collision_layer = current_col_layer
	
	# Return true if no collision (layer is clear)
	return not has_collision


func _update_layer_appearance() -> void:
	"""Update the visual appearance based on current layer"""
	if not sprite:
		return
	
	if is_fly_mode:
		# In fly mode, keep fly mode scale and z-index
		return
	
	if current_layer == BACK_LAYER:
		# Farther layer - darker tint, smaller scale, lower z-index
		sprite.modulate = BACK_LAYER_TINT
		scale = BACK_LAYER_SCALE
		z_index = BACK_LAYER_Z_INDEX
	else:
		# Front layer - normal color and scale, higher z-index
		sprite.modulate = FRONT_LAYER_TINT
		scale = FRONT_LAYER_SCALE
		z_index = FRONT_LAYER_Z_INDEX


func _update_layer_collision() -> void:
	"""Update collision mask based on current layer"""
	if is_fly_mode:
		return  # Don't override fly mode collision settings
	
	if current_layer == BACK_LAYER:
		collision_mask = BACK_COLLISION_MASK
		collision_layer = BACK_COLLISION_LAYER
	else:
		collision_mask = FRONT_COLLISION_MASK
		collision_layer = FRONT_COLLISION_LAYER
	
	# Update original collision mask and z_index so they restore correctly from fly mode
	if not is_fly_mode:
		original_collision_mask = collision_mask
		original_collision_layer = collision_layer
		original_z_index = z_index
