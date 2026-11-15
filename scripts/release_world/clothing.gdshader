shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec4 cloth_color : source_color = vec4(0.4,0.6,0.6,1.0);
uniform vec4 accent_color : source_color = vec4(0.88,0.85,0.74,1.0);
uniform int outfit = 0;
uniform sampler2D fabric_map : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_map : hint_normal, filter_linear_mipmap, repeat_enable;

void fragment() {
	vec3 fabric = texture(fabric_map, UV * 7.0).rgb;
	float weave = mix(0.88, 1.08, dot(fabric, vec3(0.333)));
	vec3 color = cloth_color.rgb;
	if (outfit == 1) {
		float stripe = step(0.66, fract(UV.y * 11.0));
		color = mix(color, accent_color.rgb, stripe * 0.88);
	} else if (outfit == 2) {
		float center = 1.0 - smoothstep(0.04,0.10,abs(fract(UV.x * 2.0)-0.5));
		float piping = 1.0 - smoothstep(0.008,0.021,abs(fract(UV.y * 1.9)-0.62));
		color = mix(color * 0.48, accent_color.rgb, center * 0.76 + piping * 0.22);
	} else if (outfit == 3) {
		float panel = smoothstep(0.45,0.48,fract(UV.x + UV.y * 0.6));
		color = mix(color, accent_color.rgb, panel * 0.65);
	}
	ALBEDO = color * weave;
	ROUGHNESS = 0.87;
	NORMAL_MAP = texture(normal_map, UV * 7.0).rgb;
	NORMAL_MAP_DEPTH = 0.3;
}
