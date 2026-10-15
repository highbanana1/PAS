shader_type canvas_item;
render_mode unshaded;
varying vec4 sprite_tint;
void vertex() { sprite_tint = COLOR; }
void fragment() {
	vec4 original = texture(TEXTURE, UV);
	vec2 texel = UV / TEXTURE_PIXEL_SIZE;
	// Foreend is rendered by the movable Pump sprite, reusing the same asset.
	if (texel.x >= 1280.0 && texel.x < 1600.0 && texel.y >= 960.0 && texel.y < 1152.0) {
		original = vec4(vec3(0.22), texel.y < 1024.0 ? 1.0 : 0.0);
	}
	COLOR = original * sprite_tint;
}
