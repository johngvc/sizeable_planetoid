extends Node2D
## Visual representation of the combined physics drawn object with wood texture
## Uses world-space UV coordinates so texture appears fixed (window into infinite texture)

var wood_texture: Texture2D = null
var points: Array = []
var center: Vector2 = Vector2.ZERO
var draw_size: float = 16.0
var use_world_pos: bool = false
var texture_scale: float = 0.02  # How much to scale the texture (smaller = larger tiles)


func _ready() -> void:
	points = get_meta("points", [])
	center = get_meta("center", Vector2.ZERO)
	draw_size = get_meta("draw_size", 16.0)
	wood_texture = get_meta("wood_texture", null)
	use_world_pos = get_meta("use_world_pos", false)
	queue_redraw()


func _process(_delta: float) -> void:
	# Continuously redraw to update world-space texture coordinates
	queue_redraw()


func _draw() -> void:
	if points.is_empty() or wood_texture == null:
		return
	
	var half_size = draw_size / 2.0
	var tex_size = wood_texture.get_size()
	
	# Draw each point as a textured square with world-space UV
	for point in points:
		var local_pos = point if use_world_pos else point - center
		
		# Calculate world position for this square
		var world_pos: Vector2
		if use_world_pos:
			world_pos = point
		else:
			# Get the actual world position by combining parent transform
			world_pos = get_global_transform() * local_pos
		
		# Calculate UV based on world position (fixed orientation, infinite tiling)
		var uv_origin = Vector2(
			fposmod(world_pos.x * texture_scale, 1.0),
			fposmod(world_pos.y * texture_scale, 1.0)
		)
		
		# Size of one square in UV space
		var uv_size = draw_size * texture_scale
		
		# Source rect in texture pixels
		var src_rect = Rect2(
			uv_origin * tex_size,
			Vector2(uv_size, uv_size) * tex_size
		)
		
		# Destination rect in local space
		var dest_rect = Rect2(local_pos.x - half_size, local_pos.y - half_size, draw_size, draw_size)
		
		# Draw with tiled texture
		draw_texture_rect_region(wood_texture, dest_rect, src_rect)
	
	# Draw subtle outline for definition
	for point in points:
		var local_pos = point if use_world_pos else point - center
		var rect = Rect2(local_pos.x - half_size, local_pos.y - half_size, draw_size, draw_size)
		draw_rect(rect, Color(0.3, 0.2, 0.1, 0.3), false, 1.0)
