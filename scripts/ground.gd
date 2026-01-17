extends Node2D
## Infinite horizontal ground platform - repeats template tiles left and right

const TILE_SIZE = 16
const CHUNK_SIZE = 32  # Tiles per chunk
const LOAD_DISTANCE = 3  # Chunks to load ahead of player

var loaded_chunks: Dictionary = {}
var player: Node2D = null
var tilemap: TileMapLayer = null
var template_tilemap: TileMapLayer = null
var template_tiles: Array = []  # Stores template tile data
var template_min_x: int = 0
var template_max_x: int = 0
var template_width: int = 0


func _ready() -> void:
	tilemap = $TileMapLayer
	template_tilemap = $TileMapLayer2
	
	# Read the template tiles from TileMapLayer2
	if template_tilemap:
		read_template_tiles()
		template_tilemap.visible = false  # Hide the template
	
	# Find the player
	await get_tree().process_frame
	player = get_tree().get_first_node_in_group("player")
	if player == null:
		player = get_parent().get_node_or_null("Player")
	
	# Generate initial chunks around origin
	update_chunks(0)


func read_template_tiles() -> void:
	var used_cells = template_tilemap.get_used_cells()
	if used_cells.is_empty():
		return
	
	# Find the x-range of the template
	template_min_x = used_cells[0].x
	template_max_x = used_cells[0].x
	
	for cell in used_cells:
		template_min_x = mini(template_min_x, cell.x)
		template_max_x = maxi(template_max_x, cell.x)
	
	template_width = template_max_x - template_min_x + 1
	
	# Store all template tiles
	for cell in used_cells:
		var atlas_coords = template_tilemap.get_cell_atlas_coords(cell)
		var source_id = template_tilemap.get_cell_source_id(cell)
		template_tiles.append({
			"pos": cell,
			"local_x": cell.x - template_min_x,  # Relative x position within template
			"y": cell.y,
			"atlas": atlas_coords,
			"source": source_id
		})


func _process(_delta: float) -> void:
	if player and tilemap:
		var player_chunk = floori(player.global_position.x / (CHUNK_SIZE * TILE_SIZE))
		update_chunks(player_chunk)


func update_chunks(center_chunk: int) -> void:
	# Load chunks around the player
	for chunk_x in range(center_chunk - LOAD_DISTANCE, center_chunk + LOAD_DISTANCE + 1):
		if not loaded_chunks.has(chunk_x):
			generate_chunk(chunk_x)
			loaded_chunks[chunk_x] = true


func generate_chunk(chunk_x: int) -> void:
	if template_tiles.is_empty() or template_width <= 0:
		return
	
	var start_x = chunk_x * CHUNK_SIZE
	var end_x = start_x + CHUNK_SIZE
	
	# For each x position in the chunk, repeat the template pattern
	for x in range(start_x, end_x):
		# Calculate which template column this x maps to (using modulo for infinite repeat)
		var template_x = posmod(x - template_min_x, template_width)
		
		# Place all tiles in this column from the template
		for tile_data in template_tiles:
			if tile_data.local_x == template_x:
				tilemap.set_cell(Vector2i(x, tile_data.y), tile_data.source, tile_data.atlas)
