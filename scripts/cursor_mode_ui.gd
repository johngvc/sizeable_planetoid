extends CanvasLayer
## UI for cursor mode tools with tool-specific side panels
## Each tool (Draw, Select, Eraser, Toolbox) has its own settings panel

# Signals for tool state changes
signal tool_changed(tool_name: String)
signal material_changed(material: DrawMaterial)
signal physics_paused(paused: bool)
signal toolbox_tool_changed(toolbox_tool: String)

# Per-tool settings signals
signal draw_settings_changed(settings: Dictionary)
signal erase_settings_changed(settings: Dictionary)
signal select_settings_changed(settings: Dictionary)
signal transform_mode_changed(mode: String)

# Main toolbar references
@onready var cursor_mode_button: Button = %CursorModeButton
@onready var main_toolbar: PanelContainer = %MainToolbar
@onready var draw_button: CheckBox = %DrawButton
@onready var select_button: CheckBox = %SelectButton
@onready var eraser_button: CheckBox = %EraserButton
@onready var toolbox_button: CheckBox = %ToolboxButton
@onready var active_layer_label: Label = %ActiveLayerLabel

# Tool-specific panels
@onready var draw_panel: PanelContainer = %DrawPanel
@onready var select_panel: PanelContainer = %SelectPanel
@onready var eraser_panel: PanelContainer = %EraserPanel
@onready var toolbox_panel: PanelContainer = %ToolboxPanel

# Draw panel controls
@onready var draw_dynamic_button: CheckBox = %DrawDynamicButton
@onready var draw_static_button: CheckBox = %DrawStaticButton
@onready var wood_button: CheckBox = %WoodButton
@onready var stone_button: CheckBox = %StoneButton
@onready var metal_button: CheckBox = %MetalButton
@onready var brick_button: CheckBox = %BrickButton
@onready var plaster_button: CheckBox = %PlasterButton
@onready var draw_circle_brush_button: CheckBox = %DrawCircleBrushButton
@onready var draw_square_brush_button: CheckBox = %DrawSquareBrushButton
@onready var draw_brush_size_label: Label = %DrawBrushSizeLabel
@onready var draw_brush_size_slider: HSlider = %DrawBrushSizeSlider
@onready var draw_layer1_button: CheckBox = %DrawLayer1Button
@onready var draw_layer2_button: CheckBox = %DrawLayer2Button
@onready var draw_show_other_layers_button: Button = %DrawShowOtherLayersButton

# Select panel controls
@onready var move_button: CheckBox = %MoveButton
@onready var resize_button: CheckBox = %ResizeButton
@onready var rotate_button: CheckBox = %RotateButton

# Eraser panel controls
@onready var eraser_circle_brush_button: CheckBox = %EraserCircleBrushButton
@onready var eraser_square_brush_button: CheckBox = %EraserSquareBrushButton
@onready var eraser_brush_size_label: Label = %EraserBrushSizeLabel
@onready var eraser_brush_size_slider: HSlider = %EraserBrushSizeSlider
@onready var eraser_layer1_button: CheckBox = %EraserLayer1Button
@onready var eraser_layer2_button: CheckBox = %EraserLayer2Button

# Toolbox panel controls
@onready var bolt_tool_button: CheckBox = %BoltToolButton
@onready var string_tool_button: CheckBox = %StringToolButton
@onready var elastic_tool_button: CheckBox = %ElasticToolButton
@onready var rod_tool_button: CheckBox = %RodToolButton

# Other UI elements
@onready var pause_button: Button = %PauseButton
@onready var pause_indicator: PanelContainer = %PauseIndicator
@onready var transform_mode_label: Label = %TransformModeLabel
@onready var current_layer_label: Label = %CurrentLayerLabel
@onready var fly_mode_indicator: PanelContainer = %FlyModeIndicator

# Current active tool
var current_tool: String = "draw"
var current_toolbox_tool: String = "bolt"
var is_physics_paused: bool = false

# Per-tool settings storage
var draw_settings: Dictionary = {
	"is_static": false,
	"material": "wood",
	"brush_shape": "circle",
	"brush_size": 16.0,
	"layer": 1,
	"show_other_layers": true
}

var erase_settings: Dictionary = {
	"brush_shape": "circle",
	"brush_size": 16.0,
	"layer": 1
}

var select_settings: Dictionary = {
	"transform_mode": "move",
	"layer": 1
}

# Transform mode colors
var transform_mode_colors: Dictionary = {
	"Move": Color(0.2, 0.8, 0.2),  # Green
	"Resize": Color(0.2, 0.6, 1.0),  # Blue
	"Rotate": Color(1.0, 0.6, 0.2)  # Orange
}

# Material definitions
var materials: Dictionary = {}
var current_material: DrawMaterial = null


func _ready() -> void:
	# Create button groups for radio button behavior
	_setup_button_groups()
	
	# Disable space key activation for all buttons
	_disable_space_for_all_buttons()
	
	# Initialize materials
	_init_materials()
	
	# Hide all panels initially
	_hide_all_panels()
	
	# Connect all button signals
	_connect_signals()
	
	# Find cursor and connect to mode changes
	await get_tree().process_frame
	var cursor = get_tree().get_first_node_in_group("cursor")
	if cursor:
		cursor.cursor_mode_changed.connect(_on_cursor_mode_changed)
	
	# Find player and connect to fly mode changes
	var player = get_tree().get_first_node_in_group("player")
	if player:
		player.fly_mode_changed.connect(_on_fly_mode_changed)
	
	# Find select_move_manager and connect to transform mode cycling
	var select_move_manager = get_tree().get_first_node_in_group("select_move_manager")
	if select_move_manager and select_move_manager.has_signal("transform_mode_cycled"):
		select_move_manager.transform_mode_cycled.connect(_on_transform_mode_cycled)
	
	# Emit initial settings
	_emit_current_tool_settings()


func _setup_button_groups() -> void:
	# Main toolbar tool buttons
	var tool_button_group = ButtonGroup.new()
	draw_button.button_group = tool_button_group
	select_button.button_group = tool_button_group
	eraser_button.button_group = tool_button_group
	toolbox_button.button_group = tool_button_group
	
	# Draw panel - physics type
	var draw_physics_group = ButtonGroup.new()
	draw_dynamic_button.button_group = draw_physics_group
	draw_static_button.button_group = draw_physics_group
	
	# Draw panel - material
	var material_button_group = ButtonGroup.new()
	wood_button.button_group = material_button_group
	stone_button.button_group = material_button_group
	metal_button.button_group = material_button_group
	brick_button.button_group = material_button_group
	plaster_button.button_group = material_button_group
	
	# Draw panel - brush shape
	var draw_brush_shape_group = ButtonGroup.new()
	draw_circle_brush_button.button_group = draw_brush_shape_group
	draw_square_brush_button.button_group = draw_brush_shape_group
	
	# Draw panel - layer
	var draw_layer_group = ButtonGroup.new()
	draw_layer1_button.button_group = draw_layer_group
	draw_layer2_button.button_group = draw_layer_group
	
	# Select panel - transform mode
	var transform_mode_group = ButtonGroup.new()
	move_button.button_group = transform_mode_group
	resize_button.button_group = transform_mode_group
	rotate_button.button_group = transform_mode_group
	
	# Eraser panel - brush shape
	var eraser_brush_shape_group = ButtonGroup.new()
	eraser_circle_brush_button.button_group = eraser_brush_shape_group
	eraser_square_brush_button.button_group = eraser_brush_shape_group
	
	# Eraser panel - layer
	var eraser_layer_group = ButtonGroup.new()
	eraser_layer1_button.button_group = eraser_layer_group
	eraser_layer2_button.button_group = eraser_layer_group
	
	# Toolbox panel - tool selection
	var toolbox_tool_button_group = ButtonGroup.new()
	bolt_tool_button.button_group = toolbox_tool_button_group
	string_tool_button.button_group = toolbox_tool_button_group
	elastic_tool_button.button_group = toolbox_tool_button_group
	rod_tool_button.button_group = toolbox_tool_button_group


func _init_materials() -> void:
	materials["wood"] = DrawMaterial.create_wood()
	materials["stone"] = DrawMaterial.create_stone()
	materials["metal"] = DrawMaterial.create_metal()
	materials["brick"] = DrawMaterial.create_brick()
	materials["plaster"] = DrawMaterial.create_plaster()
	
	# Load textures
	for mat in materials.values():
		mat.load_texture()
	
	# Set default material
	current_material = materials["wood"]


func _hide_all_panels() -> void:
	main_toolbar.visible = false
	draw_panel.visible = false
	select_panel.visible = false
	eraser_panel.visible = false
	toolbox_panel.visible = false


func _connect_signals() -> void:
	# Main toolbar buttons
	cursor_mode_button.pressed.connect(_on_cursor_mode_button_pressed)
	draw_button.pressed.connect(_on_draw_pressed)
	select_button.pressed.connect(_on_select_pressed)
	eraser_button.pressed.connect(_on_eraser_pressed)
	toolbox_button.pressed.connect(_on_toolbox_pressed)
	
	# Draw panel controls
	draw_dynamic_button.pressed.connect(_on_draw_dynamic_pressed)
	draw_static_button.pressed.connect(_on_draw_static_pressed)
	wood_button.pressed.connect(func(): _set_draw_material("wood"))
	stone_button.pressed.connect(func(): _set_draw_material("stone"))
	metal_button.pressed.connect(func(): _set_draw_material("metal"))
	brick_button.pressed.connect(func(): _set_draw_material("brick"))
	plaster_button.pressed.connect(func(): _set_draw_material("plaster"))
	draw_circle_brush_button.pressed.connect(func(): _set_draw_brush_shape("circle"))
	draw_square_brush_button.pressed.connect(func(): _set_draw_brush_shape("square"))
	draw_brush_size_slider.value_changed.connect(_on_draw_brush_size_changed)
	draw_layer1_button.pressed.connect(func(): _set_draw_layer(1))
	draw_layer2_button.pressed.connect(func(): _set_draw_layer(2))
	draw_show_other_layers_button.pressed.connect(_on_draw_show_other_layers_pressed)
	
	# Select panel controls
	move_button.pressed.connect(func(): _set_transform_mode("move"))
	resize_button.pressed.connect(func(): _set_transform_mode("resize"))
	rotate_button.pressed.connect(func(): _set_transform_mode("rotate"))
	
	# Eraser panel controls
	eraser_circle_brush_button.pressed.connect(func(): _set_erase_brush_shape("circle"))
	eraser_square_brush_button.pressed.connect(func(): _set_erase_brush_shape("square"))
	eraser_brush_size_slider.value_changed.connect(_on_erase_brush_size_changed)
	eraser_layer1_button.pressed.connect(func(): _set_erase_layer(1))
	eraser_layer2_button.pressed.connect(func(): _set_erase_layer(2))
	
	# Toolbox panel controls
	bolt_tool_button.pressed.connect(func(): set_toolbox_tool("bolt"))
	string_tool_button.pressed.connect(func(): set_toolbox_tool("string"))
	elastic_tool_button.pressed.connect(func(): set_toolbox_tool("elastic"))
	rod_tool_button.pressed.connect(func(): set_toolbox_tool("rod"))
	
	# Pause button
	pause_button.pressed.connect(_on_pause_button_pressed)


func _disable_space_for_all_buttons() -> void:
	var buttons = [
		cursor_mode_button, draw_button, select_button, eraser_button, toolbox_button,
		draw_dynamic_button, draw_static_button,
		wood_button, stone_button, metal_button, brick_button, plaster_button,
		draw_circle_brush_button, draw_square_brush_button,
		draw_layer1_button, draw_layer2_button, draw_show_other_layers_button,
		move_button, resize_button, rotate_button,
		eraser_circle_brush_button, eraser_square_brush_button,
		eraser_layer1_button, eraser_layer2_button,
		bolt_tool_button, string_tool_button, elastic_tool_button, rod_tool_button,
		pause_button
	]
	for button in buttons:
		_disable_space_for_button(button)


func _disable_space_for_button(button: BaseButton) -> void:
	if button:
		button.shortcut_in_tooltip = false
		button.gui_input.connect(func(event: InputEvent):
			if event is InputEventKey and event.keycode == KEY_SPACE:
				get_viewport().set_input_as_handled()
		)


# ============================================================================
# CURSOR MODE CALLBACKS
# ============================================================================

func _on_cursor_mode_button_pressed() -> void:
	var cursor = get_tree().get_first_node_in_group("cursor")
	if cursor:
		cursor.toggle_cursor()


func _on_cursor_mode_changed(active: bool) -> void:
	main_toolbar.visible = active
	cursor_mode_button.button_pressed = active
	if active:
		# Reset to draw tool when opening cursor mode
		set_tool("draw")
	else:
		_hide_all_panels()
		main_toolbar.visible = false


func _on_fly_mode_changed(active: bool) -> void:
	if fly_mode_indicator:
		fly_mode_indicator.visible = active


# ============================================================================
# TOOL SWITCHING
# ============================================================================

func _on_draw_pressed() -> void:
	set_tool("draw")


func _on_select_pressed() -> void:
	set_tool("select")


func _on_eraser_pressed() -> void:
	set_tool("eraser")


func _on_toolbox_pressed() -> void:
	set_tool("toolbox")


func set_tool(tool_name: String) -> void:
	current_tool = tool_name
	
	# Update main toolbar button states
	draw_button.button_pressed = (tool_name == "draw")
	select_button.button_pressed = (tool_name == "select")
	eraser_button.button_pressed = (tool_name == "eraser")
	toolbox_button.button_pressed = (tool_name == "toolbox")
	
	# Show/hide appropriate panels
	draw_panel.visible = (tool_name == "draw")
	select_panel.visible = (tool_name == "select")
	eraser_panel.visible = (tool_name == "eraser")
	toolbox_panel.visible = (tool_name == "toolbox")
	
	# Update transform mode label visibility
	show_transform_mode_label(tool_name == "select")
	
	# Update active layer indicator based on current tool's layer
	_update_active_layer_indicator()
	
	# Emit tool changed signal with appropriate internal tool name
	var internal_tool_name = _get_internal_tool_name()
	tool_changed.emit(internal_tool_name)
	
	# Emit current tool's settings
	_emit_current_tool_settings()


func _get_internal_tool_name() -> String:
	match current_tool:
		"draw":
			return "draw_static" if draw_settings["is_static"] else "draw_dynamic"
		"select":
			return "select"
		"eraser":
			return "eraser"
		"toolbox":
			return "toolbox"
	return "draw_dynamic"


func get_current_tool() -> String:
	return _get_internal_tool_name()


# ============================================================================
# DRAW PANEL CALLBACKS
# ============================================================================

func _on_draw_dynamic_pressed() -> void:
	draw_settings["is_static"] = false
	tool_changed.emit("draw_dynamic")
	draw_settings_changed.emit(draw_settings)


func _on_draw_static_pressed() -> void:
	draw_settings["is_static"] = true
	tool_changed.emit("draw_static")
	draw_settings_changed.emit(draw_settings)


func _set_draw_material(material_name: String) -> void:
	draw_settings["material"] = material_name
	if materials.has(material_name):
		current_material = materials[material_name]
		material_changed.emit(current_material)
	draw_settings_changed.emit(draw_settings)


func _set_draw_brush_shape(shape: String) -> void:
	draw_settings["brush_shape"] = shape
	draw_settings_changed.emit(draw_settings)


func _on_draw_brush_size_changed(value: float) -> void:
	draw_settings["brush_size"] = value
	draw_brush_size_label.text = "📏 Brush Size: %d" % int(value)
	draw_settings_changed.emit(draw_settings)


func _set_draw_layer(layer: int) -> void:
	draw_settings["layer"] = layer
	_update_active_layer_indicator()
	_update_current_layer_label(layer)
	draw_settings_changed.emit(draw_settings)


func _on_draw_show_other_layers_pressed() -> void:
	draw_settings["show_other_layers"] = draw_show_other_layers_button.button_pressed
	draw_settings_changed.emit(draw_settings)


# ============================================================================
# SELECT PANEL CALLBACKS
# ============================================================================

func _set_transform_mode(mode: String) -> void:
	select_settings["transform_mode"] = mode
	
	# Update button states
	move_button.button_pressed = (mode == "move")
	resize_button.button_pressed = (mode == "resize")
	rotate_button.button_pressed = (mode == "rotate")
	
	# Update transform mode label
	var mode_name = mode.capitalize()
	update_transform_mode_label(mode_name)
	
	# Emit signal for select_move_manager
	transform_mode_changed.emit(mode)
	select_settings_changed.emit(select_settings)


func _on_transform_mode_cycled(mode_name: String) -> void:
	# Called when Q key cycles the transform mode - sync UI buttons
	select_settings["transform_mode"] = mode_name.to_lower()
	move_button.button_pressed = (mode_name == "Move")
	resize_button.button_pressed = (mode_name == "Resize")
	rotate_button.button_pressed = (mode_name == "Rotate")
	update_transform_mode_label(mode_name)


# ============================================================================
# ERASER PANEL CALLBACKS
# ============================================================================

func _set_erase_brush_shape(shape: String) -> void:
	erase_settings["brush_shape"] = shape
	erase_settings_changed.emit(erase_settings)


func _on_erase_brush_size_changed(value: float) -> void:
	erase_settings["brush_size"] = value
	eraser_brush_size_label.text = "📏 Brush Size: %d" % int(value)
	erase_settings_changed.emit(erase_settings)


func _set_erase_layer(layer: int) -> void:
	erase_settings["layer"] = layer
	_update_active_layer_indicator()
	_update_current_layer_label(layer)
	erase_settings_changed.emit(erase_settings)


# ============================================================================
# TOOLBOX CALLBACKS
# ============================================================================

func set_toolbox_tool(toolbox_tool: String) -> void:
	current_toolbox_tool = toolbox_tool
	toolbox_tool_changed.emit(toolbox_tool)


# ============================================================================
# UI HELPERS
# ============================================================================

func _update_active_layer_indicator() -> void:
	var layer = _get_current_tool_layer()
	active_layer_label.text = "📍 Active Layer: %d" % layer


func _get_current_tool_layer() -> int:
	match current_tool:
		"draw":
			return draw_settings["layer"]
		"eraser":
			return erase_settings["layer"]
	return 1


func _update_current_layer_label(layer: int) -> void:
	if layer == 1:
		current_layer_label.text = "Layer 1 (Front)"
	else:
		current_layer_label.text = "Layer 2 (Back)"


func update_transform_mode_label(mode_name: String) -> void:
	if transform_mode_label:
		transform_mode_label.text = mode_name + " (Q to cycle)"
		if transform_mode_colors.has(mode_name):
			transform_mode_label.add_theme_color_override("font_color", transform_mode_colors[mode_name])


func show_transform_mode_label(visible: bool) -> void:
	if transform_mode_label:
		transform_mode_label.visible = visible


func _emit_current_tool_settings() -> void:
	match current_tool:
		"draw":
			draw_settings_changed.emit(draw_settings)
			material_changed.emit(current_material)
		"select":
			select_settings_changed.emit(select_settings)
		"eraser":
			erase_settings_changed.emit(erase_settings)


# ============================================================================
# PAUSE FUNCTIONALITY
# ============================================================================

func _on_pause_button_pressed() -> void:
	toggle_physics_pause()


func toggle_physics_pause() -> void:
	is_physics_paused = not is_physics_paused
	pause_button.button_pressed = is_physics_paused
	pause_indicator.visible = is_physics_paused
	physics_paused.emit(is_physics_paused)


func is_paused() -> bool:
	return is_physics_paused


# ============================================================================
# INPUT HANDLING
# ============================================================================

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_P:
				toggle_physics_pause()
				get_viewport().set_input_as_handled()
			KEY_1:
				_change_current_tool_layer(1)
				get_viewport().set_input_as_handled()
			KEY_2:
				_change_current_tool_layer(2)
				get_viewport().set_input_as_handled()


func _change_current_tool_layer(layer: int) -> void:
	match current_tool:
		"draw":
			draw_layer1_button.button_pressed = (layer == 1)
			draw_layer2_button.button_pressed = (layer == 2)
			_set_draw_layer(layer)
		"eraser":
			eraser_layer1_button.button_pressed = (layer == 1)
			eraser_layer2_button.button_pressed = (layer == 2)
			_set_erase_layer(layer)


# ============================================================================
# GETTER METHODS FOR EXTERNAL ACCESS
# ============================================================================

func get_current_material() -> DrawMaterial:
	return current_material


func get_draw_settings() -> Dictionary:
	return draw_settings


func get_erase_settings() -> Dictionary:
	return erase_settings


func get_select_settings() -> Dictionary:
	return select_settings


func get_current_brush_shape() -> String:
	match current_tool:
		"draw":
			return draw_settings["brush_shape"]
		"eraser":
			return erase_settings["brush_shape"]
	return "circle"


func get_current_layer() -> int:
	return _get_current_tool_layer()


func get_current_brush_size() -> float:
	match current_tool:
		"draw":
			return draw_settings["brush_size"]
		"eraser":
			return erase_settings["brush_size"]
	return 16.0
