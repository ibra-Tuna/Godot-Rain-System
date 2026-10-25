@tool
class_name WeatherParticles
extends Node2D
## Rain made of particles. One node, one preset. Builds all children at runtime
## (nothing is saved to the scene).
##   WeatherParticles (follows the camera)
##   ├─ Drops (GPUParticles2D)
##   ├─ Splash (GPUParticles2D, top_level, sub-emitter of Drops)
##   └─ RainColliders (Node2D, top_level) -> LightOccluder2D per tile / shape near the camera
##
## Collision comes ONLY from your level:
##   - every TileMapLayer / TileMap (tiles that have physics polygons)
##   - every CollisionShape2D / CollisionPolygon2D whose parent is a StaticBody2D or Area2D
##   - anything inside a node in the group `rain_collider` (any body type)
##   - anything in the group `rain_ignore` is skipped
##
## Usage:
##   add_child(WeatherParticles.new())
##   $Weather.preset = WeatherParticles.Preset.STORM
##   $Weather.custom_direction = true
##   $Weather.fall_angle = -30.0
##   $Weather.fade_in(3.0)   /   $Weather.stop(2.0)
##
## Real splashes need Godot 4.3+ and Forward+ or Mobile. On the Compatibility renderer
## it falls back to fake splashes automatically.

enum Preset { LIGHT_RAIN, RAIN, HEAVY_RAIN, STORM }

@export var preset: Preset = Preset.RAIN:
	set(value):
		preset = value
		_queue_rebuild()
## 0..1. Scales how many particles are emitted. Tween it, or use fade_in() / stop().
@export_range(0.0, 1.0, 0.01) var intensity := 1.0:
	set(value):
		intensity = value
		if _drops:
			_drops.amount_ratio = intensity
@export var autostart := true
## Particle density multiplier on top of the preset.
@export_range(0.1, 3.0, 0.05) var density := 1.0:
	set(value):
		density = value
		_queue_rebuild()
@export var follow_camera := true
## Drawn above the world. Raise it if your level uses higher z_index values.
@export var draw_z := 100:
	set(value):
		draw_z = value
		z_index = value
## How far above the screen drops spawn.
@export var spawn_margin := 60.0:
	set(value):
		spawn_margin = value
		_queue_rebuild()

@export_group("Direction")
## Tick this to use your own fall direction instead of the preset's.
@export var custom_direction := false:
	set(value):
		custom_direction = value
		_queue_rebuild()
## Degrees from straight down. Positive = falls toward the right, negative = toward the left.
@export_range(-80.0, 80.0, 1.0) var fall_angle := 20.0:
	set(value):
		fall_angle = value
		_queue_rebuild()

@export_group("Appearance")
## Override the preset's default color.
@export var use_custom_color := false:
	set(value):
		use_custom_color = value
		_queue_rebuild()
@export var custom_color := Color(0.8, 0.85, 0.92):
	set(value):
		custom_color = value
		if use_custom_color:
			_queue_rebuild()

@export_group("Collision")
## true: splashes where drops hit your level. false (or Compatibility renderer): fake splashes.
@export var use_collision := true:
	set(value):
		use_collision = value
		_queue_rebuild()
## Find TileMaps and StaticBody2D shapes automatically. Turn off to use only the group below.
@export var auto_detect := true:
	set(value):
		auto_detect = value
		_queue_rebuild()
## Anything in this group (and its CollisionShape2D / CollisionPolygon2D / TileMap children) collides.
@export var collider_group: StringName = &"rain_collider"
## Anything in this group is skipped, with its children.
@export var ignore_group: StringName = &"rain_ignore"
## Colliders are generated for the SDF area plus this margin (px) and refreshed as the camera moves.
@export var collider_margin := 256.0
## Every collider is extended this far downward so fast drops can't skip over thin shapes.
## Increased to 96 to prevent tunneling at lower framerates or very high storm speeds.
@export var collider_depth := 96.0
## Moves the collision surface up (+) or down (-) by this many px. 0 = the exact top of your
## tile collision polygons. Raise it only if splashes appear inside the ground.
@export var collider_lift := 0.0
## Skip tiles that have a solid tile directly above them (square grids only). Saves a lot of occluders.
@export var skip_buried_tiles := true
## Draw the real (thickened) colliders in translucent red to check them.
@export var debug_show_colliders := false

var _view := Vector2(1152, 648)
var _last_zoom := Vector2.ONE
var _drops: GPUParticles2D
var _splash: GPUParticles2D
var _colliders: Node2D
var _collide := false
var _collider_center := Vector2.ZERO
var _sources: Array[Node] = []
var _tween: Tween
var _running := true
var _rebuild_queued := false


func _ready() -> void:
	_running = autostart or Engine.is_editor_hint()
	get_viewport().size_changed.connect(_queue_rebuild)
	_rebuild_queued = true
	_rebuild.call_deferred()   # one frame later so the whole level is in the tree
	
	if collider_depth < 32.0:
		push_warning("WeatherParticles: collider_depth is very low (%s). Fast drops may tunnel through the collision. Recommended value is 96.0." % collider_depth)


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	var cam := get_viewport().get_camera_2d()
	if follow_camera:
		global_position = _screen_center()
	if cam and not cam.zoom.is_equal_approx(_last_zoom):
		_queue_rebuild()
	elif _collide:
		var target_center = _screen_center() if follow_camera else global_position
		if target_center.distance_to(_collider_center) > collider_margin * 0.5:
			_refresh_colliders()


# ================================================================ public API

## Starts (or restarts) the rain, ramping up over `duration` seconds.
func fade_in(duration := 2.0) -> void:
	_running = true
	if _drops:
		_drops.emitting = true
	_kill_tween()
	if duration <= 0.0:
		intensity = 1.0
		return
	intensity = 0.0
	_tween = create_tween()
	_tween.tween_property(self, "intensity", 1.0, duration)


## Ramps the rain down over `duration` seconds, then stops emitting.
func stop(duration := 2.0) -> void:
	_kill_tween()
	if duration <= 0.0:
		_halt()
		return
	_tween = create_tween()
	_tween.tween_property(self, "intensity", 0.0, duration)
	_tween.tween_callback(_halt)


## Call after changing tiles, or adding / moving collision shapes at runtime.
func rebuild_collision() -> void:
	if _collide:
		_scan_sources()
		_refresh_colliders()


func _halt() -> void:
	_running = false
	if _drops:
		_drops.emitting = false


func _kill_tween() -> void:
	if _tween:
		_tween.kill()
		_tween = null


func _screen_center() -> Vector2:
	var cam := get_viewport().get_camera_2d()
	return cam.get_screen_center_position() if cam else _view * 0.5


# ================================================================ SDF area

# Size of the SDF area relative to the screen (Project Settings > Rendering > 2D > SDF > Oversize).
func _sdf_factor() -> float:
	var idx := int(ProjectSettings.get_setting("rendering/2d/sdf/oversize", 1))
	var factors := [1.0, 1.2, 1.5, 2.0]
	return factors[clampi(idx, 0, 3)]


func _sdf_half_width() -> float:
	return _view.x * _sdf_factor() * 0.5


# How far past the screen the SDF reaches, in world px.
func _sdf_extra() -> float:
	return (_sdf_factor() - 1.0) * maxf(_view.x, _view.y) * 0.5


# ================================================================ presets

func _preset_data() -> Dictionary:
	match preset:
		Preset.LIGHT_RAIN:
			return {"amount": 150, "speed": Vector2(500, 800), "slant": 0.1,
				"length": 16, "width": 2, "scale": Vector2(0.5, 1.0), "alpha": Vector2(0.25, 0.6),
				"color": Color(0.8, 0.85, 0.95), "droplets": 2, "splash_scale": 0.7}
		Preset.HEAVY_RAIN:
			return {"amount": 900, "speed": Vector2(900, 1400), "slant": 0.3,
				"length": 30, "width": 2, "scale": Vector2(0.5, 1.2), "alpha": Vector2(0.4, 0.9),
				"color": Color(0.75, 0.8, 0.9), "droplets": 3, "splash_scale": 1.0}
		Preset.STORM:
			return {"amount": 1400, "speed": Vector2(1100, 1700), "slant": 0.5,
				"length": 36, "width": 3, "scale": Vector2(0.6, 1.3), "alpha": Vector2(0.4, 0.9),
				"color": Color(0.7, 0.75, 0.85), "droplets": 3, "splash_scale": 1.2}
		_: # RAIN
			return {"amount": 400, "speed": Vector2(700, 1100), "slant": 0.2,
				"length": 24, "width": 2, "scale": Vector2(0.5, 1.2), "alpha": Vector2(0.4, 1.0),
				"color": Color(0.8, 0.85, 0.92), "droplets": 3, "splash_scale": 1.0}


func _slant(d: Dictionary) -> float:
	if custom_direction:
		return tan(deg_to_rad(fall_angle))
	return d["slant"]


# ================================================================ build

func _queue_rebuild() -> void:
	if not is_node_ready() or _rebuild_queued:
		return
	_rebuild_queued = true
	_rebuild.call_deferred()


func _collision_available() -> bool:
	return use_collision \
		and not Engine.is_editor_hint() \
		and RenderingServer.get_current_rendering_method() != "gl_compatibility"


func _view_size() -> Vector2:
	if Engine.is_editor_hint():
		return Vector2(
			float(ProjectSettings.get_setting("display/window/size/viewport_width", 1152)),
			float(ProjectSettings.get_setting("display/window/size/viewport_height", 648)))
	var size := get_viewport_rect().size
	var cam := get_viewport().get_camera_2d()
	_last_zoom = cam.zoom if cam else Vector2.ONE
	return size / _last_zoom


func _rebuild() -> void:
	_rebuild_queued = false
	for n in [_drops, _splash, _colliders]:
		if is_instance_valid(n):
			remove_child(n)
			n.queue_free()
	_drops = null
	_splash = null
	_colliders = null

	z_index = draw_z
	_view = _view_size()
	var d := _preset_data()
	_collide = _collision_available()
	if use_collision and not _collide and not Engine.is_editor_hint():
		push_warning("WeatherParticles: real collision needs Forward+ or Mobile (this is '%s'). Using fake splashes, which appear mid-air." % RenderingServer.get_current_rendering_method())
	if _collide:
		_scan_sources()
		_refresh_colliders()
		if _sources.is_empty():
			push_warning("WeatherParticles: no TileMapLayer, TileMap or StaticBody2D collision shape found, so drops will fall through. Add nodes to the group '%s' if your level uses something else." % collider_group)

	_drops = _make_drops(d)
	add_child(_drops)

	var rate := float(_drops.amount) / _drops.lifetime   # drops per second
	var splash_life := 0.3
	var splash_amount := int(rate * float(d["droplets"]) * splash_life * 1.5) + 32
	_splash = _make_splash(d, splash_amount, splash_life)
	add_child(_splash)
	_splash.global_position = Vector2.ZERO   # identity transform: no offset can leak in
	_drops.sub_emitter = _drops.get_path_to(_splash)

	_drops.amount_ratio = intensity
	_drops.emitting = _running


# ---------------------------------------------------------------- drops

func _make_drops(d: Dictionary) -> GPUParticles2D:
	var speed: Vector2 = d["speed"]
	var slant := _slant(d)
	var fall_height := _view.y + spawn_margin * 2.0
	var fall_time := fall_height / ((speed.x + speed.y) * 0.5)
	var half_w := _view.x * 0.5
	
	# FIXED: Hardcoded spawn bounds to extend 2 full screens left/right.
	# This guarantees the edges of the screen are always covered, regardless of SDF or drift.
	var x_min: float
	var x_max: float
	if slant >= 0.0:
		x_min = -_view.x * 2.0
		x_max = half_w + spawn_margin
	else:
		x_min = -half_w - spawn_margin
		x_max = _view.x * 2.0
		
	var span := x_max - x_min

	var p := GPUParticles2D.new()
	p.name = "Drops"
	# Higher amount to compensate for the massive spawn area
	p.amount = maxi(8, int(float(d["amount"]) * density * 2.5))
	
	# FIXED: Reverted to false so SDF collision works in world space
	p.local_coords = false
	
	p.modulate = custom_color if use_custom_color else d["color"]
	p.position = Vector2((x_min + x_max) * 0.5, -_view.y * 0.5 - spawn_margin)
	
	# FIXED: Massive visibility rect to entirely disable culling
	p.visibility_rect = Rect2(-100000.0, -100000.0, 200000.0, 200000.0)
	
	p.lifetime = fall_time * (1.6 if _collide else 1.0)
	# Disable preprocess when collision is active so drops don't fall through uninitialized SDF.
	p.preprocess = 0.0 if _collide else p.lifetime
	p.texture = _streak_texture(d["length"], d["width"])

	var alpha: Vector2 = d["alpha"]
	var ag := Gradient.new()
	ag.colors = PackedColorArray([Color(1, 1, 1, alpha.x), Color(1, 1, 1, alpha.y)])
	var alpha_tex := GradientTexture1D.new()
	alpha_tex.gradient = ag

	var scale_range: Vector2 = d["scale"]
	var m := ParticleProcessMaterial.new()
	# Without collision, drops die in a band near the bottom = fake depth.
	m.lifetime_randomness = 0.0 if _collide else 0.3
	m.particle_flag_disable_z = true
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	m.emission_box_extents = Vector3(span * 0.5, 1, 0)
	m.direction = Vector3(slant, 1, 0).normalized()
	m.spread = 0.0
	m.gravity = Vector3.ZERO
	m.initial_velocity_min = speed.x
	m.initial_velocity_max = speed.y
	m.scale_min = scale_range.x
	m.scale_max = scale_range.y
	m.color_initial_ramp = alpha_tex
	m.angle_min = rad_to_deg(atan(slant))   # tilt the streak along the fall
	m.angle_max = m.angle_min

	if _collide:
		m.collision_mode = ParticleProcessMaterial.COLLISION_HIDE_ON_CONTACT
		m.sub_emitter_mode = ParticleProcessMaterial.SUB_EMITTER_AT_COLLISION
		m.sub_emitter_amount_at_collision = d["droplets"]
	else:
		m.sub_emitter_mode = ParticleProcessMaterial.SUB_EMITTER_AT_END
		m.sub_emitter_amount_at_end = d["droplets"]
	m.sub_emitter_keep_velocity = false

	p.process_material = m
	return p


func _make_splash(d: Dictionary, splash_amount: int, splash_life: float) -> GPUParticles2D:
	var k: float = d["splash_scale"]
	var p := GPUParticles2D.new()
	p.name = "Splash"
	p.top_level = true               # sits at the world origin, so it never inherits an offset
	p.emitting = false               # the drops trigger it
	p.amount = splash_amount         # must cover many simultaneous hits
	p.lifetime = splash_life
	
	# FIXED: Reverted to false to align with world space collisions
	p.local_coords = false
	
	p.modulate = custom_color if use_custom_color else d["color"]
	
	# Massive visibility rect
	p.visibility_rect = Rect2(-100000.0, -100000.0, 200000.0, 200000.0)

	var g := Gradient.new()
	g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	# Larger texture for better visibility
	tex.width = 8
	tex.height = 8
	p.texture = tex

	var fade := Gradient.new()
	fade.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	var fade_tex := GradientTexture1D.new()
	fade_tex.gradient = fade

	var m := ParticleProcessMaterial.new()
	m.particle_flag_disable_z = true
	m.direction = Vector3(0, -1, 0)  # droplets pop upward
	m.spread = 75.0
	# Faster initial velocity for a sharper pop
	m.initial_velocity_min = 150.0 * k
	m.initial_velocity_max = 300.0 * k
	# Reduced gravity so the droplets fade out before falling deep into the ground
	m.gravity = Vector3(0, 250, 0)
	m.lifetime_randomness = 0.3
	m.scale_min = 0.4 * k
	m.scale_max = 1.0 * k
	m.color_ramp = fade_tex
	p.process_material = m
	return p


# The particle's origin (the point that collides) is the HEAD of the streak: the texture is
# twice as tall as the streak, with the streak in the top half and transparent padding below.
func _streak_texture(length: int, width: int) -> Texture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.5, 0.501, 1.0])
	g.colors = PackedColorArray([
		Color(1, 1, 1, 0),   # tail (transparent)
		Color(1, 1, 1, 1),   # head (opaque), sits at the texture center = particle origin
		Color(1, 1, 1, 0),   # padding below the head
		Color(1, 1, 1, 0),
	])
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill_from = Vector2(0, 0)
	tex.fill_to = Vector2(0, 1)
	tex.width = width
	tex.height = length * 2
	return tex


# ================================================================ finding colliders

# Finds every TileMapLayer / TileMap / collision shape that should stop rain.
func _scan_sources() -> void:
	_sources.clear()
	var seen := {}
	if auto_detect:
		var root := get_tree().current_scene
		if root:
			_scan_node(root, seen, false)
	for n in get_tree().get_nodes_in_group(collider_group):
		_scan_node(n, seen, true)


func _scan_node(node: Node, seen: Dictionary, forced: bool) -> void:
	if node == self or node.is_in_group(ignore_group):
		return
	var is_tiles := node is TileMapLayer or node is TileMap
	var is_shape := node is CollisionShape2D or node is CollisionPolygon2D
	if is_tiles or is_shape:
		# Expanded to support Area2D shapes automatically alongside StaticBody2D
		var ok := forced or is_tiles or node.get_parent() is StaticBody2D or node.get_parent() is Area2D
		if ok and not seen.has(node.get_instance_id()):
			seen[node.get_instance_id()] = true
			_sources.append(node)
	for child in node.get_children():
		_scan_node(child, seen, forced)


# ================================================================ building colliders

# Rebuilds the occluders for the SDF area plus a margin. Cheap enough to repeat as the camera moves.
func _refresh_colliders() -> void:
	if is_instance_valid(_colliders):
		remove_child(_colliders)
		_colliders.queue_free()
	_colliders = Node2D.new()
	_colliders.name = "RainColliders"
	_colliders.top_level = true      # stays in world space while this node follows the camera
	add_child(_colliders)
	_colliders.global_position = Vector2.ZERO

	# Generate colliders around the node's position if it doesn't follow the camera.
	_collider_center = _screen_center() if follow_camera else global_position
	var rect := Rect2(_collider_center - _view * 0.5, _view).grow(_sdf_extra() + collider_margin)
	for n in _sources:
		if is_instance_valid(n) and n.is_inside_tree():
			_collect(n, rect)


func _collect(node: Node, rect: Rect2) -> void:
	if node is TileMapLayer:
		_collect_layer(node as TileMapLayer, rect)
	elif node is TileMap:
		_collect_tilemap(node as TileMap, rect)
	elif node is CollisionShape2D:
		var cs := node as CollisionShape2D
		if not cs.disabled and cs.shape:
			_add_polygon(_shape_to_polygon(cs.shape, cs.global_transform), rect)
	elif node is CollisionPolygon2D:
		var cp := node as CollisionPolygon2D
		if not cp.disabled:
			_add_polygon(_transform_points(cp.polygon, cp.global_transform), rect)


# ---- tiles

func _collect_layer(layer: TileMapLayer, rect: Rect2) -> void:
	var ts := layer.tile_set
	if ts == null or ts.get_physics_layers_count() == 0 or not layer.collision_enabled:
		return
	var cells := _cell_range(rect, func(p: Vector2) -> Vector2i:
		return layer.local_to_map(layer.to_local(p)))
	if cells.get_area() > 250000:
		push_warning("WeatherParticles: view too large for tile colliders, skipping %s" % layer.name)
		return
	var can_skip := skip_buried_tiles and ts.tile_shape == TileSet.TILE_SHAPE_SQUARE
	for y in range(cells.position.y, cells.end.y):
		for x in range(cells.position.x, cells.end.x):
			var coords := Vector2i(x, y)
			var td := layer.get_cell_tile_data(coords)
			if td == null:
				continue
			if can_skip and _is_solid(layer.get_cell_tile_data(coords + Vector2i(0, -1)), ts):
				continue
			var xf := layer.global_transform * Transform2D(0.0, layer.map_to_local(coords))
			_add_tile(td, layer.get_cell_alternative_tile(coords), xf, ts, rect)


func _collect_tilemap(map: TileMap, rect: Rect2) -> void:
	var ts := map.tile_set
	if ts == null or ts.get_physics_layers_count() == 0:
		return
	var cells := _cell_range(rect, func(p: Vector2) -> Vector2i:
		return map.local_to_map(map.to_local(p)))
	if cells.get_area() > 250000:
		push_warning("WeatherParticles: view too large for tile colliders, skipping %s" % map.name)
		return
	var can_skip := skip_buried_tiles and ts.tile_shape == TileSet.TILE_SHAPE_SQUARE
	for layer_id in map.get_layers_count():
		for y in range(cells.position.y, cells.end.y):
			for x in range(cells.position.x, cells.end.x):
				var coords := Vector2i(x, y)
				var td := map.get_cell_tile_data(layer_id, coords)
				if td == null:
					continue
				if can_skip and _is_solid(map.get_cell_tile_data(layer_id, coords + Vector2i(0, -1)), ts):
					continue
				var xf := map.global_transform * Transform2D(0.0, map.map_to_local(coords))
				_add_tile(td, map.get_cell_alternative_tile(layer_id, coords), xf, ts, rect)


func _is_solid(td: TileData, ts: TileSet) -> bool:
	if td == null:
		return false
	for physics_layer in ts.get_physics_layers_count():
		if td.get_collision_polygons_count(physics_layer) > 0:
			return true
	return false


# Cell bounds covering a world-space rectangle (works for square, iso and hex grids).
func _cell_range(rect: Rect2, world_to_cell: Callable) -> Rect2i:
	var corners := [rect.position, Vector2(rect.end.x, rect.position.y),
			rect.end, Vector2(rect.position.x, rect.end.y)]
	var lo: Vector2i = world_to_cell.call(corners[0])
	var hi := lo
	for c in corners:
		var cell: Vector2i = world_to_cell.call(c)
		lo = Vector2i(mini(lo.x, cell.x), mini(lo.y, cell.y))
		hi = Vector2i(maxi(hi.x, cell.x), maxi(hi.y, cell.y))
	return Rect2i(lo - Vector2i.ONE, hi - lo + Vector2i(3, 3))


func _add_tile(td: TileData, alt: int, xf: Transform2D, ts: TileSet, rect: Rect2) -> void:
	var flip_h := (alt & TileSetAtlasSource.TRANSFORM_FLIP_H) != 0
	var flip_v := (alt & TileSetAtlasSource.TRANSFORM_FLIP_V) != 0
	var transpose := (alt & TileSetAtlasSource.TRANSFORM_TRANSPOSE) != 0
	for physics_layer in ts.get_physics_layers_count():
		for i in td.get_collision_polygons_count(physics_layer):
			var pts := td.get_collision_polygon_points(physics_layer, i)
			if pts.size() < 3:
				continue
			var out := PackedVector2Array()
			for p in pts:
				var q: Vector2 = p
				if transpose:
					q = Vector2(q.y, q.x)
				if flip_h:
					q.x = -q.x
				if flip_v:
					q.y = -q.y
				out.append(xf * q)
			_add_polygon(out, rect)


# ---- shapes

func _shape_to_polygon(shape: Shape2D, xf: Transform2D) -> PackedVector2Array:
	var pts := PackedVector2Array()
	if shape is RectangleShape2D:
		var h := (shape as RectangleShape2D).size * 0.5
		pts = PackedVector2Array([Vector2(-h.x, -h.y), Vector2(h.x, -h.y),
				Vector2(h.x, h.y), Vector2(-h.x, h.y)])
	elif shape is CircleShape2D:
		var radius := (shape as CircleShape2D).radius
		for i in 16:
			pts.append(Vector2.RIGHT.rotated(TAU * i / 16.0) * radius)
	elif shape is CapsuleShape2D:    # approximated by its bounding box
		var cap := shape as CapsuleShape2D
		var h := Vector2(cap.radius, cap.height * 0.5)
		pts = PackedVector2Array([Vector2(-h.x, -h.y), Vector2(h.x, -h.y),
				Vector2(h.x, h.y), Vector2(-h.x, h.y)])
	elif shape is ConvexPolygonShape2D:
		pts = (shape as ConvexPolygonShape2D).points
	elif shape is SegmentShape2D:    # thin quad so the SDF can see it
		var seg := shape as SegmentShape2D
		var n := (seg.b - seg.a).orthogonal().normalized() * 4.0 # Thickened for SDF visibility
		pts = PackedVector2Array([seg.a - n, seg.b - n, seg.b + n, seg.a + n])
	else:
		push_warning("WeatherParticles: unsupported collision shape %s" % shape.get_class())
	return _transform_points(pts, xf)


func _transform_points(points: PackedVector2Array, xf: Transform2D) -> PackedVector2Array:
	var out := PackedVector2Array()
	for pt in points:
		out.append(xf * pt)
	return out


# ---- occluder output

# Moves the surface by collider_lift and extends the shape downward by collider_depth,
# so a fast drop can't skip over it between two frames. Works on convex pieces.
func _solidify(piece: PackedVector2Array) -> PackedVector2Array:
	var all := PackedVector2Array()
	# Force a minimum depth of 32.0 to absolutely prevent tunneling, even if the Inspector is set to 0.0.
	var depth := maxf(collider_depth, 32.0)
	for pt in piece:
		var top := pt + Vector2(0.0, -collider_lift)
		all.append(top)
		all.append(top + Vector2(0.0, depth))
	var hull := Geometry2D.convex_hull(all)
	if hull.size() > 1 and hull[0].is_equal_approx(hull[hull.size() - 1]):
		hull.remove_at(hull.size() - 1)
	return hull


func _add_polygon(points: PackedVector2Array, rect: Rect2) -> void:
	if points.size() < 3:
		return
	# Skip anything outside the generated area.
	var lo := points[0]
	var hi := points[0]
	for pt in points:
		lo = Vector2(minf(lo.x, pt.x), minf(lo.y, pt.y))
		hi = Vector2(maxf(hi.x, pt.x), maxf(hi.y, pt.y))
	if not rect.intersects(Rect2(lo, hi - lo)):
		return

	# Concave shapes are split into convex pieces first, so they aren't filled in.
	var pieces: Array = Geometry2D.decompose_polygon_in_convex(points)
	if pieces.is_empty():
		pieces = [points]
	for piece in pieces:
		var solid := _solidify(piece)
		if solid.size() < 3:
			continue
		var poly := OccluderPolygon2D.new()
		poly.closed = true
		poly.cull_mode = OccluderPolygon2D.CULL_DISABLED
		poly.polygon = solid
		var occ := LightOccluder2D.new()
		occ.occluder = poly
		occ.sdf_collision = true
		_colliders.add_child(occ)
		if debug_show_colliders:
			var dbg := Polygon2D.new()
			dbg.polygon = solid
			dbg.color = Color(1, 0, 0, 0.35)
			_colliders.add_child(dbg)
