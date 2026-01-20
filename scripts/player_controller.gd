extends CharacterBody2D
## Player controller for 2D platformer movement

signal fly_mode_changed(active: bool)

# Movement constants
const SPEED = 200.0
const FLY_SPEED = 250.0
const ACCELERATION = 2000.0  # Pixels per second squared
const FLY_ACCELERATION = 1800.0  # Pixels per second squared in fly mode
const FRICTION = 2400.0  # Deceleration when no input
const JUMP_VELOCITY = -400.0

# Get the gravity from the project settings
var gravity = ProjectSettings.get_setting("physics/2d/default_gravity")

# Reference to cursor for checking if cursor mode is active
var cursor: Node2D = null

# Fly mode state
var is_fly_mode: bool = false
var drag_velocity: Vector2 = Vector2.ZERO  # Velocity from cursor dragging
var original_collision_mask: int = 0  # Store original collision mask
var original_collision_layer: int = 0  # Store original collision layer
var original_z_index: int = 0  # Store original z-index


func _ready() -> void:
	# Add player to group so cursor can find us
	add_to_group("player")
	
	# Store original collision settings
	original_collision_mask = collision_mask
	original_collision_layer = collision_layer
	original_z_index = z_index
	
	# Find cursor after scene is ready
	await get_tree().process_frame
	cursor = get_tree().get_first_node_in_group("cursor")


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_O:
		toggle_fly_mode()


func toggle_fly_mode() -> void:
	is_fly_mode = not is_fly_mode
	fly_mode_changed.emit(is_fly_mode)
	
	if is_fly_mode:
		# Enable fly mode: only detect collisions with layer 4 (boundaries)
		collision_mask = 4  # Only detect collisions with layer 4 (boundaries)
		collision_layer = 0  # Don't exist on any layer (other objects won't collide with us)
		z_index = 100  # Draw in foreground
	else:
		# Restore original settings
		collision_mask = original_collision_mask
		collision_layer = original_collision_layer
		z_index = original_z_index
		drag_velocity = Vector2.ZERO
		collision_mask = original_collision_mask
		z_index = original_z_index
		drag_velocity = Vector2.ZERO


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
