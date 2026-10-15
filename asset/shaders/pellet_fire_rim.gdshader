shader_type canvas_item;
render_mode unshaded;

// Reuse bullet_standred.png alpha and shading; color only the existing silhouette.
uniform float rim_width_texels : hint_range(64.0, 256.0, 64.0) = 192.0;
uniform vec4 warm_gold : source_color = vec4(1.0, 0.72, 0.12, 1.0);
uniform vec4 hot_highlight : source_color = vec4(1.0, 0.96, 0.58, 1.0);
uniform vec4 amber_shadow : source_color = vec4(0.94, 0.43, 0.06, 1.0);

uniform vec2 light_direction = vec2(-1.0, 0.0);
uniform float shading_cells : hint_range(4.0, 24.0, 1.0) = 12.0;

varying vec4 sprite_tint;

void vertex() {
	sprite_tint = COLOR;
}

void fragment() {
	vec4 original = texture(TEXTURE, UV);
	vec2 step_uv = TEXTURE_PIXEL_SIZE * rim_width_texels;
	float interior = min(min(texture(TEXTURE, UV + vec2(step_uv.x, 0.0)).a,
		texture(TEXTURE, UV - vec2(step_uv.x, 0.0)).a),
		min(texture(TEXTURE, UV + vec2(0.0, step_uv.y)).a,
		texture(TEXTURE, UV - vec2(0.0, step_uv.y)).a));
	vec2 diagonal = step_uv * 0.70710678;
	interior = min(interior, min(min(texture(TEXTURE, UV + diagonal).a, texture(TEXTURE, UV - diagonal).a),
		min(texture(TEXTURE, UV + vec2(diagonal.x,-diagonal.y)).a, texture(TEXTURE, UV + vec2(-diagonal.x,diagonal.y)).a)));
	float edge = 1.0 - step(0.5, interior);
	vec2 pellet_uv = (UV - REGION_RECT.xy) / REGION_RECT.zw;
	// Quantized surface normals produce actual directional pixel shading.
	vec2 pixel_uv = (floor(pellet_uv * shading_cells) + 0.5) / shading_cells;
	vec2 sphere_xy = (pixel_uv - 0.5) * 2.0;
	float sphere_z = sqrt(max(0.02, 1.0 - dot(sphere_xy, sphere_xy)));
	vec3 normal = normalize(vec3(sphere_xy, sphere_z));
	vec2 incoming = length(light_direction) > 0.001 ? normalize(light_direction) : vec2(-1.0, 0.0);
	vec3 light = normalize(vec3(incoming, 0.75));
	float diffuse = max(dot(normal, light), 0.0);
	float shade_band = floor(diffuse * 3.0 + 0.0001) / 3.0;
	float rim_facing = dot(normalize(sphere_xy + vec2(0.0001)), incoming);
	vec3 rim = rim_facing > 0.45 ? hot_highlight.rgb : (rim_facing < -0.2 ? amber_shadow.rgb * 0.65 : warm_gold.rgb);
	vec3 metal = original.rgb * (0.62 + shade_band * 0.55);
	metal = mix(metal, hot_highlight.rgb, step(0.86, diffuse) * 0.68);
	vec2 outline_step = TEXTURE_PIXEL_SIZE * 64.0;
	float border_interior = min(min(texture(TEXTURE, UV + vec2(outline_step.x, 0.0)).a,
		texture(TEXTURE, UV - vec2(outline_step.x, 0.0)).a),
		min(texture(TEXTURE, UV + vec2(0.0, outline_step.y)).a, texture(TEXTURE, UV - vec2(0.0, outline_step.y)).a));
	vec3 lit_color = mix(metal, rim, edge);
	// A thin dark pixel boundary keeps the yellow rim readable on bright terrain.
	lit_color = mix(lit_color, vec3(0.22, 0.13, 0.045), (1.0 - step(0.5, border_interior)) * 0.88);
	COLOR = vec4(lit_color, original.a) * sprite_tint;
}
