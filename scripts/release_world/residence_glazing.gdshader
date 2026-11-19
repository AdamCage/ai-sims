shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec4 tint : source_color = vec4(0.33, 0.41, 0.40, 1.0);
varying vec3 window_local;
varying vec3 camera_local;

void vertex() {
	window_local = VERTEX;
	camera_local = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
}

void fragment() {
	vec3 direction = normalize(camera_local - window_local);
	// Sample the recess behind the plane at the current viewing angle.
	vec2 recess = window_local.xy - direction.xy * 0.18 / max(abs(direction.z), 0.37);
	float shade = smoothstep(1.49, 2.23, recess.y);
	float fold = 0.5 + 0.5 * sin(recess.x * 39.0 + sin(recess.x * 8.0) * 0.6);
	float reveal = 1.0 - smoothstep(0.30, 0.88, abs(recess.x));
	vec3 room = mix(vec3(0.070, 0.077, 0.068), vec3(0.42, 0.34, 0.25), shade * reveal);
	room *= mix(0.72, 0.96, fold);
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	ALBEDO = mix(room, tint.rgb, mix(0.28, 0.80, fresnel));
	METALLIC = mix(0.28, 0.71, fresnel);
	ROUGHNESS = 0.19 + 0.065 * fold;
	SPECULAR = 0.46;
}
