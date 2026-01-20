extends Node2D
## Boundary walls that contain the player within a play space

const TILE_SIZE = 16
const WALL_HEIGHT = 100  # Height of the walls in tiles

@export var left_boundary_x: int = -200  # Left boundary position in pixels
@export var right_boundary_x: int = 200  # Right boundary position in pixels
@export var ground_y: int = 100  # Y position of the ground
@export var ceiling_height: int = -500  # Y position of the ceiling in pixels

var tilemap: TileMapLayer = null


func _ready() -> void:
	tilemap = $TileMapLayer
	generate_boundaries()


func generate_boundaries() -> void:
	# Convert pixel positions to tile positions
	var left_tile_x = floori(left_boundary_x / float(TILE_SIZE))
	var right_tile_x = floori(right_boundary_x / float(TILE_SIZE))
	var ground_tile_y = floori(ground_y / float(TILE_SIZE))
	var ceiling_tile_y = floori(ceiling_height / float(TILE_SIZE))
	
	# Generate left wall (extends upward from ground)
	for y in range(ceiling_tile_y, ground_tile_y + 1):
		# Use different tiles for variation (atlas coords 0:0 through 3:0)
		var atlas_x = abs(y) % 4
		tilemap.set_cell(Vector2i(left_tile_x, y), 0, Vector2i(atlas_x, 1))
	
	# Generate right wall (extends upward from ground)
	for y in range(ceiling_tile_y, ground_tile_y + 1):
		var atlas_x = abs(y) % 4
		tilemap.set_cell(Vector2i(right_tile_x, y), 0, Vector2i(atlas_x, 1))
	
	# Generate ceiling (horizontal barrier across the top)
	for x in range(left_tile_x, right_tile_x + 1):
		var atlas_x = abs(x) % 4
		tilemap.set_cell(Vector2i(x, ceiling_tile_y), 0, Vector2i(atlas_x, 1))
