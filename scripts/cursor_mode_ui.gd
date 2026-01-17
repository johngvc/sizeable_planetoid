extends CanvasLayer
## UI for cursor mode tools - Draw and Select/Move, plus material selection

signal tool_changed(tool_name: String)
signal material_changed(material: DrawMaterial)

@onready var cursor_mode_button: Button = %CursorModeButton
@onready var tool_panel: PanelContainer = %ToolPanel
@onready var draw_dynamic_button: Button = %DrawDynamicButton
@onready var draw_static_button: Button = %DrawStaticButton
@onready var select_button: Button = %SelectButton
@onready var wood_button: Button = %WoodButton
@onready var stone_button: Button = %StoneButton
@onready var metal_button: Button = %MetalButton
@onready var brick_button: Button = %BrickButton

var current_tool: String = "draw_dynamic"
var current_material: DrawMaterial = null

# Material definitions
var materials: Dictionary = {}


func _ready() -> void:
	# Initialize materials
	materials["wood"] = DrawMaterial.create_wood()
	materials["stone"] = DrawMaterial.create_stone()
	materials["metal"] = DrawMaterial.create_metal()
	materials["brick"] = DrawMaterial.create_brick()
	
	# Load textures
	for mat in materials.values():
		mat.load_texture()
	
	# Set default material
	current_material = materials["wood"]
	
	# Connect tool buttons
	draw_dynamic_button.pressed.connect(_on_draw_dynamic_pressed)
	draw_static_button.pressed.connect(_on_draw_static_pressed)
	select_button.pressed.connect(_on_select_pressed)
	
	# Connect material buttons
	wood_button.pressed.connect(_on_wood_pressed)
	stone_button.pressed.connect(_on_stone_pressed)
	metal_button.pressed.connect(_on_metal_pressed)
	brick_button.pressed.connect(_on_brick_pressed)
	
	# Connect cursor mode button
	cursor_mode_button.pressed.connect(_on_cursor_mode_button_pressed)
	
	# Find cursor and connect to mode changes
	await get_tree().process_frame
	var cursor = get_tree().get_first_node_in_group("cursor")
	if cursor:
		cursor.cursor_mode_changed.connect(_on_cursor_mode_changed)
	
	# Emit initial material
	material_changed.emit(current_material)


func _on_cursor_mode_button_pressed() -> void:
	var cursor = get_tree().get_first_node_in_group("cursor")
	if cursor:
		cursor.toggle_cursor()


func _on_cursor_mode_changed(active: bool) -> void:
	tool_panel.visible = active
	cursor_mode_button.button_pressed = active
	if active:
		# Reset to draw dynamic tool when opening cursor mode
		set_tool("draw_dynamic")


func _on_draw_dynamic_pressed() -> void:
	set_tool("draw_dynamic")


func _on_draw_static_pressed() -> void:
	set_tool("draw_static")


func _on_select_pressed() -> void:
	set_tool("select")


func _on_wood_pressed() -> void:
	set_material("wood")


func _on_stone_pressed() -> void:
	set_material("stone")


func _on_metal_pressed() -> void:
	set_material("metal")


func _on_brick_pressed() -> void:
	set_material("brick")


func set_tool(tool_name: String) -> void:
	current_tool = tool_name
	
	# Update button states
	draw_dynamic_button.button_pressed = (tool_name == "draw_dynamic")
	draw_static_button.button_pressed = (tool_name == "draw_static")
	select_button.button_pressed = (tool_name == "select")
	
	tool_changed.emit(tool_name)


func set_material(material_name: String) -> void:
	if materials.has(material_name):
		current_material = materials[material_name]
		
		# Update button states
		wood_button.button_pressed = (material_name == "wood")
		stone_button.button_pressed = (material_name == "stone")
		metal_button.button_pressed = (material_name == "metal")
		brick_button.button_pressed = (material_name == "brick")
		
		material_changed.emit(current_material)


func get_current_tool() -> String:
	return current_tool


func get_current_material() -> DrawMaterial:
	return current_material
