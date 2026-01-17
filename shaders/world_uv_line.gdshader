shader_type canvas_item;

// World-space UV mapping shader for Line2D
// Makes all drawn objects share the same texture alignment in world space

uniform sampler2D wood_texture : source_color, repeat_enable;
uniform float texture_scale : hint_range(0.001, 0.5) = 0.02;  // How often texture repeats (smaller = larger texture)
uniform vec4 tint_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

// Pass world position from vertex to fragment shader
varying vec2 world_pos;

void vertex() {
	// Calculate world position in vertex shader where VERTEX is available
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	// Calculate UV based on world position
	vec2 world_uv = world_pos * texture_scale;
	
	// Sample the texture using world-space UVs
	vec4 tex_color = texture(wood_texture, world_uv);
	
	// Apply tint and preserve the original alpha from Line2D
	COLOR = tex_color * tint_color;
}
