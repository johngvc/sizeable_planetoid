extends RefCounted
class_name MaterialRegion
## Represents a region within a multi-material physics body
## Each region has its own polygon, material, and collision data

var polygon: PackedVector2Array = PackedVector2Array()  # The polygon vertices in local space
var material: DrawMaterial = null  # The DrawMaterial for this region
var shader_material: ShaderMaterial = null  # Cached shader material for rendering
var convex_pieces: Array[PackedVector2Array] = []  # Pre-computed convex decomposition for physics


func _init(poly: PackedVector2Array = PackedVector2Array(), mat: DrawMaterial = null, shader_mat: ShaderMaterial = null) -> void:
	polygon = poly
	material = mat
	shader_material = shader_mat
	if polygon.size() >= 3:
		update_convex_pieces()


func update_convex_pieces() -> void:
	"""Updates the convex decomposition for this region's polygon"""
	convex_pieces.clear()
	if polygon.size() < 3:
		return
	
	var decomposed = Geometry2D.decompose_polygon_in_convex(polygon)
	for piece in decomposed:
		convex_pieces.append(piece)


func get_area() -> float:
	"""Calculates the area of this region's polygon"""
	if polygon.size() < 3:
		return 0.0
	
	var area = 0.0
	var n = polygon.size()
	for i in range(n):
		var j = (i + 1) % n
		area += polygon[i].x * polygon[j].y
		area -= polygon[j].x * polygon[i].y
	
	return abs(area) / 2.0


func get_mass_contribution() -> float:
	"""Returns the mass contribution of this region (area * density)"""
	var density = 1.0
	if material != null:
		density = material.density
	return get_area() * density * 0.008  # Mass = area × density × 0.008


func get_centroid() -> Vector2:
	"""Calculates the centroid of this region's polygon"""
	if polygon.size() < 3:
		return Vector2.ZERO
	
	var centroid = Vector2.ZERO
	var area = 0.0
	var n = polygon.size()
	
	for i in range(n):
		var j = (i + 1) % n
		var cross = polygon[i].x * polygon[j].y - polygon[j].x * polygon[i].y
		centroid.x += (polygon[i].x + polygon[j].x) * cross
		centroid.y += (polygon[i].y + polygon[j].y) * cross
		area += cross
	
	area *= 0.5
	if abs(area) < 0.001:
		for point in polygon:
			centroid += point
		return centroid / polygon.size()
	
	centroid /= (6.0 * area)
	return centroid


func duplicate_region() -> MaterialRegion:
	"""Creates a deep copy of this region"""
	var new_region = MaterialRegion.new()
	new_region.polygon = polygon.duplicate()
	new_region.material = material
	new_region.shader_material = shader_material
	new_region.convex_pieces.clear()
	for piece in convex_pieces:
		new_region.convex_pieces.append(piece.duplicate())
	return new_region


func is_valid() -> bool:
	"""Checks if this region has a valid polygon"""
	return polygon.size() >= 3 and get_area() > 0
