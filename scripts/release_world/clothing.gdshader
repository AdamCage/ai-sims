shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec4 cloth_color : source_color = vec4(0.4,0.6,0.6,1.0);
uniform vec4 accent_color : source_color = vec4(0.88,0.85,0.74,1.0);
uniform int outfit = 0;
uniform sampler2D fabric_map : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_map : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;

void fragment() {
	float frequency = 3.6;
	float roughness = 0.82;
	float relief = 0.22;
	float fiber_sheen = 0.14;
	vec3 dyed = cloth_color.rgb;
	if (outfit == 1) { // Heavy brushed hoodie.
		frequency = 2.5;
		roughness = 0.91;
		relief = 0.28;
		fiber_sheen = 0.24;
		dyed *= 0.88;
	} else if (outfit == 2) { // Dense workwear twill.
		frequency = 3.2;
		roughness = 0.76;
		relief = 0.24;
		fiber_sheen = 0.09;
		dyed *= 0.76;
	} else if (outfit == 3) { // Lighter cotton overcoat.
		frequency = 4.0;
		roughness = 0.88;
		relief = 0.17;
		fiber_sheen = 0.17;
		dyed = mix(dyed, accent_color.rgb, 0.19);
	}
	vec2 weave_uv = UV * frequency;
	vec3 threads = texture(fabric_map, weave_uv).rgb;
	float weave = dot(threads, vec3(0.299, 0.587, 0.114));
	float fiber_variation = texture(fabric_map, UV * 0.65 + vec2(0.11, 0.43)).g - 0.5;
	ALBEDO = dyed * (0.88 + 0.18 * weave + 0.08 * fiber_variation);
	ROUGHNESS = roughness + (0.5 - weave) * 0.08;
	SPECULAR = 0.25;
	RIM = fiber_sheen;
	RIM_TINT = 0.72;
	NORMAL_MAP = texture(normal_map, weave_uv).rgb;
	NORMAL_MAP_DEPTH = relief;
}
