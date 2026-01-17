extends Camera2D
## Camera that follows the player smoothly and scales with screen resolution

@export var follow_target: Node2D = null
@export var follow_smoothness: float = 5.0
@export var base_resolution: Vector2 = Vector2(1920, 1080)
@export var base_zoom: float = 4.0


func _ready() -> void:
	# Add to group so cursor can find us
	add_to_group("main_camera")
	# Find the player if not assigned
	if follow_target == null:
		follow_target = get_parent().get_node_or_null("Player")
	
	# Update zoom based on current screen size
	update_zoom()
	
	# Connect to viewport size changes
	get_viewport().size_changed.connect(update_zoom)


func update_zoom() -> void:
	var viewport_size = get_viewport().get_visible_rect().size
	
	# Calculate scale factor based on height (to maintain consistent vertical view)
	var scale_factor = viewport_size.y / base_resolution.y
	
	# Apply zoom - higher scale factor means bigger screen, so we can zoom in more
	zoom = Vector2.ONE * (base_zoom * scale_factor)


func _process(delta: float) -> void:
	if follow_target:
		# Smoothly move camera to player position
		global_position = global_position.lerp(follow_target.global_position, follow_smoothness * delta)
