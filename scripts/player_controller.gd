extends CharacterBody2D
## Player controller for 2D platformer movement

# Movement constants
const SPEED = 300.0
const JUMP_VELOCITY = -400.0

# Get the gravity from the project settings
var gravity = ProjectSettings.get_setting("physics/2d/default_gravity")

# Reference to cursor for checking if cursor mode is active
var cursor: Node2D = null


func _ready() -> void:
	# Find cursor after scene is ready
	await get_tree().process_frame
	cursor = get_tree().get_first_node_in_group("cursor")


func _physics_process(delta: float) -> void:
	# Add the gravity
	if not is_on_floor():
		velocity.y += gravity * delta

	# Don't accept movement input if cursor mode is active
	if cursor and cursor.has_method("is_cursor_active") and cursor.is_cursor_active():
		# Still apply physics but no input
		velocity.x = move_toward(velocity.x, 0, SPEED)
		move_and_slide()
		return

	# Handle jump
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	# Get the input direction: -1, 0, 1
	var direction := Input.get_axis("ui_left", "ui_right")
	
	# Apply horizontal movement
	if direction:
		velocity.x = direction * SPEED
	else:
		# Apply friction when not moving
		velocity.x = move_toward(velocity.x, 0, SPEED)

	move_and_slide()
