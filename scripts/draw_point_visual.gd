extends Node2D
## Visual representation of a single draw point (static, while cursor mode is on)
## NOTE: This script is deprecated - using drawn_object_visual.gd for merged preview instead


func _ready() -> void:
	queue_redraw()


func _draw() -> void:
	var size = get_meta("draw_size", 16.0)
	var half_size = size / 2.0
	var color = Color(0.6, 0.4, 0.2, 1.0)
	
	var rect = Rect2(-half_size, -half_size, size, size)
	draw_rect(rect, color)
	draw_rect(rect, color.darkened(0.3), false, 1.0)
