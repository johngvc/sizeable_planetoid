extends CanvasLayer
## UI for toolbox mode - place tools like bolts to connect objects

signal tool_selected(tool_name: String)
signal toolbox_mode_changed(active: bool)

@onready var toolbox_button: Button = %ToolboxButton
@onready var tool_panel: PanelContainer = %ToolPanel
@onready var bolt_tool_button: CheckBox = %BoltToolButton

var current_tool: String = "bolt"
var is_toolbox_active: bool = false


func _ready() -> void:
	# Create button group for tools
	var tool_button_group = ButtonGroup.new()
	bolt_tool_button.button_group = tool_button_group
	
	# Connect button signals
	toolbox_button.pressed.connect(_on_toolbox_button_pressed)
	bolt_tool_button.pressed.connect(_on_bolt_tool_pressed)
	
	# Find cursor and connect to mode changes
	await get_tree().process_frame
	var cursor = get_tree().get_first_node_in_group("cursor")
	if cursor:
		cursor.toolbox_mode_changed.connect(_on_cursor_toolbox_mode_changed)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_T:
		toggle_toolbox()


func _on_toolbox_button_pressed() -> void:
	toggle_toolbox()


func toggle_toolbox() -> void:
	var cursor = get_tree().get_first_node_in_group("cursor")
	if cursor:
		cursor.toggle_toolbox()


func _on_cursor_toolbox_mode_changed(active: bool) -> void:
	is_toolbox_active = active
	tool_panel.visible = active
	toolbox_button.button_pressed = active
	toolbox_mode_changed.emit(active)
	
	if active:
		# Emit initial tool selection
		tool_selected.emit(current_tool)


func _on_bolt_tool_pressed() -> void:
	current_tool = "bolt"
	tool_selected.emit(current_tool)


func get_current_tool() -> String:
	return current_tool
