extends Resource
class_name DrawMaterial
## Defines a material type for drawing with texture and physics properties

@export var name: String = "Wood"
@export var texture_path: String = ""
@export var texture: Texture2D = null

# Physics properties
@export var density: float = 1.0  # Mass multiplier per point
@export var friction: float = 0.5
@export var bounce: float = 0.1

# Visual tint (optional)
@export var tint: Color = Color.WHITE


static func create_wood() -> DrawMaterial:
	var mat = DrawMaterial.new()
	mat.name = "Wood"
	mat.texture_path = "res://assets/Textures/SBS - Tiny Texture Pack 2 - 256x256/256x256/Wood/Wood_01-256x256.png"
	mat.density = 0.6  # Light
	mat.friction = 0.7
	mat.bounce = 0.2
	return mat


static func create_stone() -> DrawMaterial:
	var mat = DrawMaterial.new()
	mat.name = "Stone"
	mat.texture_path = "res://assets/Textures/SBS - Tiny Texture Pack 2 - 256x256/256x256/Stone/Stone_01-256x256.png"
	mat.density = 2.5  # Heavy
	mat.friction = 0.8
	mat.bounce = 0.05
	return mat


static func create_metal() -> DrawMaterial:
	var mat = DrawMaterial.new()
	mat.name = "Metal"
	mat.texture_path = "res://assets/Textures/SBS - Tiny Texture Pack 2 - 256x256/256x256/Metal/Metal_01-256x256.png"
	mat.density = 4.0  # Very heavy
	mat.friction = 0.4
	mat.bounce = 0.3
	return mat


static func create_brick() -> DrawMaterial:
	var mat = DrawMaterial.new()
	mat.name = "Brick"
	mat.texture_path = "res://assets/Textures/SBS - Tiny Texture Pack 2 - 256x256/256x256/Brick/Brick_01-256x256.png"
	mat.density = 1.8  # Medium-heavy
	mat.friction = 0.75
	mat.bounce = 0.1
	return mat


func load_texture() -> void:
	if texture == null and texture_path != "":
		texture = load(texture_path)
