extends RefCounted
## Fixed solar positions and light color come from the displayed session minute.

const TIMES := [0.0, 240.0, 480.0, 600.0, 720.0]
const SUN_PITCH := [-31.0, -59.0, -36.0, -20.0, -6.0]
const SUN_AZIMUTH := [-66.0, -24.0, 26.0, 49.0, 66.0]
const KEY_COLOR := [Color("ffe3bf"), Color("fff5e8"), Color("ffe7c7"), Color("ffc394"), Color("d99592")]
const KEY_DESKTOP := [1.09, 1.25, 1.13, 0.88, 0.25]
const KEY_COMPATIBILITY := [0.53, 0.62, 0.55, 0.43, 0.16]
const SKY_TOP := [Color("6689b5"), Color("5d92c6"), Color("6896b9"), Color("647fa6"), Color("2f466c")]
const HORIZON := [Color("dfc5ae"), Color("c1d5e2"), Color("d9c7b4"), Color("dfad92"), Color("8e788b")]
const SKYLIGHT := [Color("d4def0"), Color("dde9f6"), Color("dfdcec"), Color("d2d3e7"), Color("9caacb")]
const AMBIENT := [0.36, 0.34, 0.36, 0.31, 0.25]
const FIXTURES := [0.92, 0.75, 0.92, 1.30, 1.54]

var _sun: DirectionalLight3D
var _fill: DirectionalLight3D
var _environment: Environment
var _sky: ProceduralSkyMaterial
var _desktop: bool
var _sample := -1.0
var _fixtures: Array[OmniLight3D] = []
var _fixture_energy := PackedFloat32Array()

func configure(environment: Environment, sun: DirectionalLight3D, fill: DirectionalLight3D) -> void:
	_sun = sun
	_fill = fill
	_environment = environment
	_sky = environment.sky.sky_material as ProceduralSkyMaterial
	_desktop = RenderingServer.get_current_rendering_method() == "forward_plus"

func bind_fixtures(scenery: Node3D) -> void:
	if scenery == null:
		return
	for node in scenery.get_children():
		var fixture := node as OmniLight3D
		if fixture == null:
			continue
		_fixtures.append(fixture)
		_fixture_energy.append(fixture.light_energy)

func set_quality(preset: String) -> void:
	if not _desktop:
		return
	_environment.ssao_enabled = preset != "low"
	_environment.ssil_enabled = preset == "high"

func apply(minute: float) -> void:
	# Shared sky radiance is expensive to rebuild on every 0.05-minute logic tick.
	var interval := 2.0 if _desktop else 4.0
	var sample := floorf(clampf(minute, 0.0, TIMES[-1]) / interval) * interval
	if is_equal_approx(sample, _sample):
		return
	_sample = sample
	var lower := 0
	while lower < TIMES.size() - 2 and sample > TIMES[lower + 1]:
		lower += 1
	var upper := lower + 1
	var progress := inverse_lerp(TIMES[lower], TIMES[upper], sample)
	var key: Array = KEY_DESKTOP if _desktop else KEY_COMPATIBILITY
	_sun.rotation_degrees = Vector3(lerpf(SUN_PITCH[lower], SUN_PITCH[upper], progress), lerpf(SUN_AZIMUTH[lower], SUN_AZIMUTH[upper], progress), 0.0)
	_sun.light_color = KEY_COLOR[lower].lerp(KEY_COLOR[upper], progress)
	_sun.light_energy = lerpf(key[lower], key[upper], progress)
	_fill.light_color = SKYLIGHT[lower].lerp(SKYLIGHT[upper], progress)
	_fill.light_energy = 0.10 if _desktop else 0.075
	_environment.ambient_light_color = _fill.light_color.lerp(Color("ded7c6"), 0.32)
	_environment.ambient_light_energy = lerpf(AMBIENT[lower], AMBIENT[upper], progress)
	var fixture_strength := lerpf(FIXTURES[lower], FIXTURES[upper], progress)
	for index in _fixtures.size():
		_fixtures[index].light_energy = _fixture_energy[index] * fixture_strength
	_sky.sky_top_color = SKY_TOP[lower].lerp(SKY_TOP[upper], progress)
	_sky.sky_horizon_color = HORIZON[lower].lerp(HORIZON[upper], progress)
	_sky.ground_horizon_color = _sky.sky_horizon_color.darkened(0.17)
	_environment.fog_light_color = _sky.sky_horizon_color.lerp(_sky.sky_top_color, 0.40)
