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
	mat.density = 1.0  # Base reference - player can push 1x their size easily
	mat.friction = 0.4  # Smooth wood surface
	mat.bounce = 0.15  # Slight bounce on impact
	return mat


static func create_stone() -> DrawMaterial:
	var mat = DrawMaterial.new()
	mat.name = "Stone"
	mat.texture_path = "res://assets/Textures/SBS - Tiny Texture Pack 2 - 256x256/256x256/Stone/Stone_01-256x256.png"
	mat.density = 3.5  # Very heavy
	mat.friction = 0.4
	mat.bounce = 0.05
	return mat


static func create_metal() -> DrawMaterial:
	var mat = DrawMaterial.new()
	mat.name = "Metal"
	mat.texture_path = "res://assets/Textures/SBS - Tiny Texture Pack 2 - 256x256/256x256/Metal/Metal_01-256x256.png"
	mat.density = 12.0  # Very heavy (~12x wood) - player can push 0.1x their size easily
	mat.friction = 0.3  # Smooth polished metal surface
	mat.bounce = 0.4  # Metal bounces well on impact
	return mat


static func create_brick() -> DrawMaterial:
	var mat = DrawMaterial.new()
	mat.name = "Brick"
	mat.texture_path = "res://assets/Textures/SBS - Tiny Texture Pack 2 - 256x256/256x256/Brick/Brick_01-256x256.png"
	mat.density = 1.5  # Medium weight
	mat.friction = 0.35
	mat.bounce = 0.1
	return mat


static func create_plaster() -> DrawMaterial:
	var mat = DrawMaterial.new()
	mat.name = "Plaster"
	mat.texture_path = "res://assets/Textures/SBS - Tiny Texture Pack 2 - 256x256/256x256/Plaster/Plaster_01-256x256.png"
	mat.density = 0.5  # Lighter than wood - player can push 2x their size easily
	mat.friction = 0.5  # Rough drywall-like surface
	mat.bounce = 0.05  # Absorbs impact, minimal bounce
	return mat


func load_texture() -> void:
	if texture == null and texture_path != "":
		texture = load(texture_path)
