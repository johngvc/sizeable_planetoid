extends CanvasLayer
## UI for cursor mode tools - Draw and Select/Move, plus material selection

signal tool_changed(tool_name: String)
signal material_changed(material: DrawMaterial)
signal physics_paused(paused: bool)
signal brush_shape_changed(shape: String)
signal layer_changed(layer_number: int)
signal show_other_layers_changed(show: bool)
signal toolbox_tool_changed(toolbox_tool: String)

@onready var cursor_mode_button: Button = %CursorModeButton
@onready var tool_panel: PanelContainer = %ToolPanel
@onready var draw_dynamic_button: CheckBox = %DrawDynamicButton
@onready var draw_static_button: CheckBox = %DrawStaticButton
@onready var eraser_button: CheckBox = %EraserButton
@onready var select_button: CheckBox = %SelectButton
@onready var toolbox_button: CheckBox = %ToolboxButton
@onready var wood_button: CheckBox = %WoodButton
@onready var stone_button: CheckBox = %StoneButton
@onready var metal_button: CheckBox = %MetalButton
@onready var brick_button: CheckBox = %BrickButton
@onready var pause_button: Button = %PauseButton
@onready var pause_indicator: PanelContainer = %PauseIndicator
@onready var circle_brush_button: CheckBox = %CircleBrushButton
@onready var square_brush_button: CheckBox = %SquareBrushButton
@onready var layer1_button: CheckBox = %Layer1Button
@onready var layer2_button: CheckBox = %Layer2Button
@onready var show_other_layers_button: Button = %ShowOtherLayersButton
@onready var transform_mode_label: Label = %TransformModeLabel
@onready var current_layer_label: Label = %CurrentLayerLabel
@onready var toolbox_panel: PanelContainer = %ToolboxPanel
@onready var bolt_tool_button: CheckBox = %BoltToolButton

var current_tool: String = "draw_dynamic"
var current_material: DrawMaterial = null
var is_physics_paused: bool = false
var current_brush_shape: String = "circle"
var current_layer: int = 1
var show_other_layers: bool = true
var current_toolbox_tool: String = "bolt"

# Transform mode colors
var transform_mode_colors: Dictionary = {
	"Move": Color(0.2, 0.8, 0.2),  # Green
	"Resize": Color(0.2, 0.6, 1.0),  # Blue
	"Rotate": Color(1.0, 0.6, 0.2)  # Orange
}

# Material definitions
var materials: Dictionary = {}


func _ready() -> void:
	# Create button groups for radio button behavior
	var tool_button_group = ButtonGroup.new()
	draw_dynamic_button.button_group = tool_button_group
	draw_static_button.button_group = tool_button_group
	eraser_button.button_group = tool_button_group
	select_button.button_group = tool_button_group
	toolbox_button.button_group = tool_button_group
	
	var material_button_group = ButtonGroup.new()
	wood_button.button_group = material_button_group
	stone_button.button_group = material_button_group
	metal_button.button_group = material_button_group
	brick_button.button_group = material_button_group
	
	var brush_shape_button_group = ButtonGroup.new()
	circle_brush_button.button_group = brush_shape_button_group
	square_brush_button.button_group = brush_shape_button_group
	
	var layer_button_group = ButtonGroup.new()
	layer1_button.button_group = layer_button_group
	layer2_button.button_group = layer_button_group
	
	var toolbox_tool_button_group = ButtonGroup.new()
	bolt_tool_button.button_group = toolbox_tool_button_group
	
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
	
	# Hide toolbox panel initially
	if toolbox_panel:
		toolbox_panel.visible = false
	
	# Connect tool buttons
	draw_dynamic_button.pressed.connect(_on_draw_dynamic_pressed)
	draw_static_button.pressed.connect(_on_draw_static_pressed)
	eraser_button.pressed.connect(_on_eraser_pressed)
	select_button.pressed.connect(_on_select_pressed)
	toolbox_button.pressed.connect(_on_toolbox_pressed)
	
	# Connect material buttons
	wood_button.pressed.connect(_on_wood_pressed)
	stone_button.pressed.connect(_on_stone_pressed)
	metal_button.pressed.connect(_on_metal_pressed)
	brick_button.pressed.connect(_on_brick_pressed)
	
	# Connect cursor mode button
	cursor_mode_button.pressed.connect(_on_cursor_mode_button_pressed)
	
	# Connect pause button
	pause_button.pressed.connect(_on_pause_button_pressed)
	
	# Connect brush shape buttons
	circle_brush_button.pressed.connect(_on_circle_brush_pressed)
	square_brush_button.pressed.connect(_on_square_brush_pressed)
	
	# Connect layer buttons
	layer1_button.pressed.connect(_on_layer1_pressed)
	layer2_button.pressed.connect(_on_layer2_pressed)
	show_other_layers_button.pressed.connect(_on_show_other_layers_pressed)
	
	# Connect toolbox tool buttons
	bolt_tool_button.pressed.connect(_on_bolt_tool_pressed)
	
	# Find cursor and connect to mode changes
	await get_tree().process_frame
	var cursor = get_tree().get_first_node_in_group("cursor")
	if cursor:
		cursor.cursor_mode_changed.connect(_on_cursor_mode_changed)
	
	# Emit initial material
	material_changed.emit(current_material)
	
	# Emit initial brush shape
	brush_shape_changed.emit(current_brush_shape)
	
	# Emit initial layer
	layer_changed.emit(current_layer)


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


func _on_eraser_pressed() -> void:
	set_tool("eraser")


func _on_select_pressed() -> void:
	set_tool("select")


func _on_toolbox_pressed() -> void:
	set_tool("toolbox")


func _on_bolt_tool_pressed() -> void:
	set_toolbox_tool("bolt")


func _on_wood_pressed() -> void:
	set_material("wood")


func _on_stone_pressed() -> void:
	set_material("stone")


func _on_metal_pressed() -> void:
	set_material("metal")


func _on_brick_pressed() -> void:
	set_material("brick")


func _on_circle_brush_pressed() -> void:
	set_brush_shape("circle")


func _on_square_brush_pressed() -> void:
	set_brush_shape("square")


func _on_layer1_pressed() -> void:
	change_layer(1)


func _on_layer2_pressed() -> void:
	change_layer(2)


func _on_show_other_layers_pressed() -> void:
	show_other_layers = show_other_layers_button.button_pressed
	show_other_layers_changed.emit(show_other_layers)


func set_brush_shape(shape: String) -> void:
	current_brush_shape = shape
	
	# Update button states
	circle_brush_button.button_pressed = (shape == "circle")
	square_brush_button.button_pressed = (shape == "square")
	
	brush_shape_changed.emit(shape)


func get_current_brush_shape() -> String:
	return current_brush_shape


func set_tool(tool_name: String) -> void:
	current_tool = tool_name
	
	# Update button states
	draw_dynamic_button.button_pressed = (tool_name == "draw_dynamic")
	draw_static_button.button_pressed = (tool_name == "draw_static")
	eraser_button.button_pressed = (tool_name == "eraser")
	select_button.button_pressed = (tool_name == "select")
	toolbox_button.button_pressed = (tool_name == "toolbox")
	
	# Show/hide toolbox panel based on tool
	if toolbox_panel:
		toolbox_panel.visible = (tool_name == "toolbox")
	
	tool_changed.emit(tool_name)


func set_toolbox_tool(toolbox_tool: String) -> void:
	current_toolbox_tool = toolbox_tool
	toolbox_tool_changed.emit(toolbox_tool)


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


func change_layer(layer_number: int) -> void:
	current_layer = layer_number
	
	# Update button states
	layer1_button.button_pressed = (layer_number == 1)
	layer2_button.button_pressed = (layer_number == 2)
	
	# Update current layer label
	if layer_number == 1:
		current_layer_label.text = "Layer 1 (Front)"
	else:
		current_layer_label.text = "Layer 2 (Back)"
	
	layer_changed.emit(layer_number)


func get_current_layer() -> int:
	return current_layer


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_P:
		toggle_physics_pause()


func _on_pause_button_pressed() -> void:
	toggle_physics_pause()


func toggle_physics_pause() -> void:
	is_physics_paused = not is_physics_paused
	pause_button.button_pressed = is_physics_paused
	pause_indicator.visible = is_physics_paused
	physics_paused.emit(is_physics_paused)


func is_paused() -> bool:
	return is_physics_paused


func update_transform_mode_label(mode_name: String) -> void:
	if transform_mode_label:
		transform_mode_label.text = mode_name + " (Q to cycle)"
		if transform_mode_colors.has(mode_name):
			transform_mode_label.add_theme_color_override("font_color", transform_mode_colors[mode_name])


func show_transform_mode_label(visible: bool) -> void:
	if transform_mode_label:
		transform_mode_label.visible = visible
