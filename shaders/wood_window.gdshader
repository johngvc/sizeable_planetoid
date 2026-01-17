shader_type canvas_item;

uniform sampler2D wood_texture : repeat_enable, filter_nearest;
uniform float texture_scale = 0.05;

void fragment() {
	// Use screen/world position for fixed texture orientation
	// This makes the texture appear as a window into an infinite tiled background
	vec2 world_uv = (UV + VERTEX) * texture_scale;
	COLOR = texture(wood_texture, world_uv);
}
