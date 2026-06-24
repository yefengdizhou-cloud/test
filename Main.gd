extends Node3D

const PORT := 12345
const CALIBRATION_PATH := "user://glove_calibration_test.json"
const CALIBRATION_VERSION := 16
# 伸直实测均值（未按 C 校准时作为默认 open）
const DEFAULT_FLEX_OPEN: Array[float] = [988.0, 907.0, 925.0, 829.0, 961.0]

# 右手零位：掌心朝下 (-Y)，手指朝前 (-Z)，拇指朝身体左侧 (-X)

var udp_peer := PacketPeerUDP.new()

@onready var hand_model: Node3D = $HandModel
@onready var debug_label: Label3D = $DebugLabel

# --- 模型对齐（auto 时按骨骼自动计算，使零位指尖朝 -Z）---
@export var auto_model_align: bool = true
@export var model_align_euler_deg: Vector3 = Vector3.ZERO
@export var model_scale: float = 1.0

# --- 只显示右手掌 ---
@export var hide_left_arm: bool = true
@export var hide_right_upper_arm: bool = true
@export var hide_reference_mesh: bool = true

# --- 手指弯曲（flex0~4 = 拇指/食指/中指/无名指/小指）---
# 握拳标定值来自实测；伸直值在按 C 时自动记录
@export var flex_closed_thumb: float = 680.0
@export var flex_closed_index: float = 422.0
@export var flex_closed_middle: float = 624.0
@export var flex_closed_ring: float = 540.0
@export var flex_closed_pinky: float = 535.0
@export var flex_dead_zone_ratio: float = 0.06  # 每指死区 = span * 此比例
@export var flex_dead_zone_min: float = 18.0
@export var flex_smooth_time: float = 0.08
@export var flex_bend_range_ratios: Array[float] = [1.0, 1.0, 0.68, 0.68, 0.80]
@export var curl_dead_zone_deg: float = 2.5
@export var finger_curl_deg: float = 95.0
@export var finger_chain_weights: Array[float] = [0.22, 0.12, 0.48, 0.18]
@export var finger_mcp_boost_max: float = 1.20
@export var finger_abduct_curl_mix: float = 0.55
@export var finger_curl_target_fan: float = 0.0  # 已弃用，保留兼容
# 各指弯向掌心沟槽偏移（负=食指向拇指侧，正=无名/小指侧）
@export var finger_column_blends: Array[float] = [0.35, -0.42, 0.58, 0.72, 0.82]
# 弯拢慢起步（smoothstep 幂次，越大起步越柔）
@export var finger_curl_ease_power: float = 2.0
# 握拳时各指最大弯曲比例
@export var finger_curl_scales: Array[float] = [1.0, 1.0, 1.0, 0.96, 0.92]
# 掌指横向展开幅度（中指=0；弯曲过程先满展开再弯拢）
@export var finger_fist_splay_deg: Array[float] = [0.0, 12.0, 0.0, 15.0, 22.0]

# --- 骨骼名（scene.gltf 右手 deform 骨骼）---
@export var wrist_bone_name: String = "hand.R"
@export var thumb_bone_name: String = "thumb_base.R"
@export var index_bone_name: String = "index_base.R"
@export var middle_bone_name: String = "middle_base.R"
@export var ring_bone_name: String = "ring_base.R"
@export var pinky_bone_name: String = "pinky_base.R"

var hand_quat_raw := Quaternion.IDENTITY
var motion_acc_raw := Vector3.ZERO
var flex_raw: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0]

var is_calibrated := false
var rest_quat_inv := Quaternion.IDENTITY
var acc_bias := Vector3.ZERO
var flex_rest: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0]
var flex_closed_finger: Array[float] = [680.0, 422.0, 624.0, 540.0, 535.0]
var _flex_filtered: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0]
var _flex_recent: Array = []
const _FLEX_RECENT_MAX := 15

@export var mount_euler_deg: Vector3 = Vector3.ZERO

var _mount_quat := Quaternion.IDENTITY
var _model_align_quat := Quaternion.IDENTITY
var _packet_count := 0
var _udp_ready := false
var _udp_error := ""
var _wait_seconds := 0.0
var _help_refresh_timer := 0.0

var _skeleton: Skeleton3D
var _wrist_bone_idx := -1
var _finger_bone_indices: Array[int] = [-1, -1, -1, -1, -1]
var _finger_chain_indices: Array = []
var _finger_chain_weight_sets: Array = []
var _bone_curl_axes: Dictionary = {}
var _bone_splay_axes: Dictionary = {}
var _finger_splay_signs: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0]
var _bones_ready := false
var _visibility_applied := false
var _wrist_bind_quat := Quaternion.IDENTITY
var _demo_mode := false
var _demo_bend := 0.0

const _DEFAULT_FLEX_CLOSED: Array[float] = [680.0, 422.0, 624.0, 540.0, 535.0]
const _MIN_FLEX_SPAN_WARN := 25.0

const _WRIST_CANDIDATES: Array[String] = [
	"hand.R", "hand.R_02", "hand.R.001", "RightHand", "mixamorig:RightHand",
	"Hand_R", "hand_r", "Wrist_R", "wrist_r", "RightWrist", "R_Hand",
]
const _FINGER_CANDIDATES: Array[Array] = [
	["thumb_base.R", "RightHandThumb1", "thumb_01.R", "mixamorig:RightThumb1"],
	["index_base.R", "RightHandIndex1", "index_01.R", "mixamorig:RightIndex1"],
	["middle_base.R", "RightHandMiddle1", "middle_01.R", "mixamorig:RightMiddle1"],
	["ring_base.R", "RightHandRing1", "ring_01.R", "mixamorig:RightRing1"],
	["pinky_base.R", "RightHandPinky1", "pinky_01.R", "mixamorig:RightPinky1"],
]

const _RIGHT_UPPER_ARM_BONES: Array[String] = ["pulse.R", "pulse.R_01", "RightShoulder", "RightArm"]
const _REFERENCE_BONES: Array[String] = ["Reference", "FpsArms.2", "_rootJoint"]
const _HIDDEN_BONE_SUBSTRINGS: Array[String] = ["_Ctrl", "_end_", "_tip"]

# scene.gltf deform 链：base(MCP) + 01 + 02 + 03，不含 Ctrl/end
const _FINGER_DEFORM_CHAINS: Array[Array] = [
	["thumb_base.R", "thumb_01.R", "thumb_02.R", "thumb_03.R"],
	["index_base.R", "index_01.R", "index_02.R", "index_03.R"],
	["middle_base.R", "middle_01.R", "middle_02.R", "middle_03.R"],
	["ring_base.R", "ring_01.R", "ring_02.R", "ring_03.R"],
	["pinky_base.R", "pinky_01.R", "pinky_02.R", "pinky_03.R"],
]
const _DEFAULT_FINGER_CURL_SCALES: Array[float] = [1.0, 1.0, 1.0, 0.96, 0.92]
const _DEFAULT_CHAIN_WEIGHTS: Array[float] = [0.22, 0.12, 0.48, 0.18]
const _DEFAULT_FINGER_SPLAY_DEG: Array[float] = [0.0, 12.0, 0.0, 15.0, 22.0]
const _DEFAULT_FINGER_COLUMN_BLENDS: Array[float] = [0.35, -0.42, 0.58, 0.72, 0.82]
const _FINGER_SPREAD_DESIRED_X: Array[float] = [0.0, -1.0, 0.0, 1.0, 1.0]
const _DEFAULT_BEND_RANGE_RATIOS: Array[float] = [1.0, 1.0, 0.68, 0.68, 0.80]
const _MIN_CHILD_LEN_FOR_AXIS := 0.008  # 短指节继承掌指关节弯曲轴


func _ready() -> void:
	_sync_flex_closed_from_exports()
	hand_model.scale = Vector3.ONE * model_scale
	_update_mount_quat()
	_update_model_align_quat()
	_start_udp_listener()
	_load_calibration()
	_setup_skeleton()
	_update_help_text()


func _exit_tree() -> void:
	if udp_peer.is_bound():
		udp_peer.close()


func _start_udp_listener() -> void:
	if udp_peer.is_bound():
		udp_peer.close()

	var err := udp_peer.bind(PORT, "127.0.0.1")
	if err == OK:
		_udp_ready = true
		_udp_error = ""
		print("UDP listening on 127.0.0.1:", PORT)
	else:
		_udp_ready = false
		_udp_error = error_string(err)
		push_error("UDP bind failed on port %d: %s" % [PORT, _udp_error])
	_update_help_text()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_C:
				calibrate_now()
			KEY_F:
				calibrate_fist_closed()
			KEY_R:
				reset_calibration()
			KEY_M:
				_cycle_mount_preset()
			KEY_P:
				_print_bone_names()
			KEY_T:
				_toggle_demo_mode()
			KEY_EQUAL, KEY_KP_ADD:
				_adjust_demo_bend(0.05)
			KEY_MINUS, KEY_KP_SUBTRACT:
				_adjust_demo_bend(-0.05)


func _process(delta: float) -> void:
	if _demo_mode:
		_drain_udp_packets()
		_apply_demo_scene(delta)
		return

	if not _udp_ready:
		return

	while udp_peer.get_available_packet_count() > 0:
		var packet := udp_peer.get_packet()
		_parse_packet(packet.get_string_from_utf8())

	if _packet_count > 0:
		_apply_to_scene(delta)
	else:
		_wait_seconds += delta
		_help_refresh_timer += delta
		if _help_refresh_timer >= 1.0:
			_help_refresh_timer = 0.0
			_update_help_text()


func _parse_packet(data_str: String) -> void:
	var parts := data_str.strip_edges().split(",")
	if parts.size() < 12:
		return

	for i in 5:
		flex_raw[i] = float(parts[i])

	var qw := float(parts[5])
	var qx := float(parts[6])
	var qy := float(parts[7])
	var qz := float(parts[8])
	hand_quat_raw = Quaternion(qx, qy, qz, qw).normalized()

	motion_acc_raw = Vector3(
		float(parts[9]),
		float(parts[10]),
		float(parts[11])
	)
	_packet_count += 1
	_flex_recent.append(flex_raw.duplicate())
	if _flex_recent.size() > _FLEX_RECENT_MAX:
		_flex_recent.pop_front()
	if _packet_count == 1:
		print("First UDP packet received")


func _drain_udp_packets() -> void:
	if not _udp_ready:
		return
	while udp_peer.get_available_packet_count() > 0:
		udp_peer.get_packet()


func _setup_skeleton() -> void:
	_skeleton = hand_model.find_child("Skeleton3D", true, false) as Skeleton3D
	if _skeleton == null:
		push_warning("HandModel 下未找到 Skeleton3D，请先导入手掌模型")
		return

	_wrist_bone_idx = _resolve_bone_index(wrist_bone_name, _WRIST_CANDIDATES)
	var export_names := [
		thumb_bone_name, index_bone_name, middle_bone_name, ring_bone_name, pinky_bone_name
	]
	_finger_bone_indices.clear()
	_finger_chain_indices.clear()
	for i in 5:
		var idx := _resolve_bone_index(export_names[i], _FINGER_CANDIDATES[i])
		_finger_bone_indices.append(idx)
	_build_finger_chains()
	_build_finger_curl_axes()
	_build_finger_splay_axes()

	_bones_ready = _wrist_bone_idx >= 0
	_apply_mesh_visibility()
	_recenter_on_palm()
	_capture_wrist_bind_quat()
	_print_bone_mapping()


func _build_finger_chains() -> void:
	_finger_chain_indices.clear()
	_finger_chain_weight_sets.clear()
	for fi in 5:
		var chain: Array[int] = []
		for prefix in _FINGER_DEFORM_CHAINS[fi]:
			var idx := _find_bone_by_prefix(prefix)
			if idx >= 0:
				chain.append(idx)
		_finger_chain_indices.append(chain)
		_finger_chain_weight_sets.append(_weights_from_bone_lengths(chain))
		if chain.is_empty():
			push_warning("Finger deform chain not found: finger %d" % fi)
		else:
			var names: Array[String] = []
			for idx in chain:
				names.append(_skeleton.get_bone_name(idx))
			print("Finger chain %d: %s" % [fi, ", ".join(names)])


func _weights_from_bone_lengths(chain: Array[int]) -> Array[float]:
	if chain.is_empty():
		return _DEFAULT_CHAIN_WEIGHTS.duplicate()
	var lengths: Array[float] = []
	var total := 0.0
	for idx in chain:
		var length := _bone_child_length_local(idx)
		lengths.append(length)
		total += length
	if total <= 0.001:
		return _DEFAULT_CHAIN_WEIGHTS.duplicate()
	var weights: Array[float] = []
	for length in lengths:
		weights.append(length / total)
	return weights


func _build_finger_curl_axes() -> void:
	_bone_curl_axes.clear()
	if _wrist_bone_idx < 0:
		return
	var wrist_sk := _skeleton.get_bone_global_rest(_wrist_bone_idx).origin
	var palm_hub := _palm_hub_sk(wrist_sk)
	for fi in 5:
		if _finger_chain_indices.size() <= fi or _finger_chain_indices[fi].is_empty():
			continue
		var chain: Array = _finger_chain_indices[fi]
		var curl_target_sk := _finger_curl_target_sk(chain[0], palm_hub, fi)
		var prev_axis := Vector3.RIGHT
		var has_prev := false
		for idx in chain:
			var axis: Vector3
			if has_prev and _bone_child_length_local(idx) < _MIN_CHILD_LEN_FOR_AXIS:
				axis = prev_axis
			else:
				axis = _detect_bone_curl_axis(idx, curl_target_sk)
			_bone_curl_axes[idx] = axis
			prev_axis = axis
			has_prev = true
	print("Finger curl axes built: %d bones (palm-hub columns)" % _bone_curl_axes.size())


func _palm_hub_sk(wrist_sk: Vector3) -> Vector3:
	var mcp_sum := Vector3.ZERO
	var mcp_count := 0
	for fi in [1, 2, 3, 4]:
		if _finger_bone_indices.size() <= fi:
			continue
		var idx := _finger_bone_indices[fi]
		if idx >= 0:
			mcp_sum += _skeleton.get_bone_global_rest(idx).origin
			mcp_count += 1
	if mcp_count == 0:
		return wrist_sk
	return wrist_sk.lerp(mcp_sum / float(mcp_count), 0.58)


func _finger_column_blend(finger_idx: int) -> float:
	if finger_column_blends.size() > finger_idx:
		return finger_column_blends[finger_idx]
	if finger_idx < _DEFAULT_FINGER_COLUMN_BLENDS.size():
		return _DEFAULT_FINGER_COLUMN_BLENDS[finger_idx]
	return 0.55


func _finger_curl_target_sk(mcp_bone_idx: int, palm_hub_sk: Vector3, finger_idx: int) -> Vector3:
	if mcp_bone_idx < 0:
		return palm_hub_sk
	var mcp_sk := _skeleton.get_bone_global_rest(mcp_bone_idx).origin
	return palm_hub_sk.lerp(mcp_sk, _finger_column_blend(finger_idx))


func _build_finger_splay_axes() -> void:
	_bone_splay_axes.clear()
	_finger_splay_signs = [0.0, 0.0, 0.0, 0.0, 0.0]
	for fi in 5:
		var idx := _finger_bone_indices[fi] if fi < _finger_bone_indices.size() else -1
		if idx >= 0:
			_bone_splay_axes[idx] = _detect_finger_splay_axis(idx)
			_finger_splay_signs[fi] = _detect_finger_splay_sign(
				idx, _FINGER_SPREAD_DESIRED_X[fi]
			)
	print(
		"Finger splay: signs (thumb→pinky) %.0f, %.0f, %.0f, %.0f, %.0f"
		% [
			_finger_splay_signs[0], _finger_splay_signs[1], _finger_splay_signs[2],
			_finger_splay_signs[3], _finger_splay_signs[4],
		]
	)


func _detect_finger_splay_sign(bone_idx: int, desired_spread_x: float) -> float:
	if absf(desired_spread_x) < 0.001:
		return 0.0
	var axis := _detect_finger_splay_axis(bone_idx)
	var rest := _skeleton.get_bone_rest(bone_idx)
	var finger_dir_local := _bone_child_dir_local(bone_idx)
	var finger_dir_global := (rest.basis * finger_dir_local).normalized()
	var finger_dir_after := (
		rest.basis * (Quaternion(axis, deg_to_rad(5.0)) * finger_dir_local)
	).normalized()
	var delta_x := finger_dir_after.x - finger_dir_global.x
	if desired_spread_x < 0.0:
		return 1.0 if delta_x < 0.0 else -1.0
	return 1.0 if delta_x > 0.0 else -1.0


func _detect_finger_splay_axis(bone_idx: int) -> Vector3:
	var rest := _skeleton.get_bone_rest(bone_idx)
	var finger_dir := _bone_child_dir_local(bone_idx)
	if finger_dir.length_squared() < 0.0001:
		finger_dir = Vector3.FORWARD
	# 绕掌心法线（手背朝上）展开手指
	var palm_normal := (rest.basis.inverse() * Vector3.UP).normalized()
	var axis := finger_dir.cross(palm_normal)
	if axis.length_squared() < 0.0001:
		return Vector3.UP
	return axis.normalized()


func _bone_child_length_local(bone_idx: int) -> float:
	var rest := _skeleton.get_bone_rest(bone_idx)
	for c in _skeleton.get_bone_count():
		if _skeleton.get_bone_parent(c) == bone_idx:
			return (_skeleton.get_bone_rest(c).origin - rest.origin).length()
	return 0.0


func _bone_child_dir_local(bone_idx: int) -> Vector3:
	var rest := _skeleton.get_bone_rest(bone_idx)
	for c in _skeleton.get_bone_count():
		if _skeleton.get_bone_parent(c) == bone_idx:
			var delta := _skeleton.get_bone_rest(c).origin - rest.origin
			if delta.length_squared() > 0.000001:
				return (rest.basis.inverse() * delta).normalized()
	return Vector3.FORWARD


func _detect_bone_curl_axis(bone_idx: int, curl_target_sk: Vector3) -> Vector3:
	var rest := _skeleton.get_bone_rest(bone_idx)
	var finger_dir := _bone_child_dir_local(bone_idx)
	if finger_dir.length_squared() < 0.0001:
		finger_dir = Vector3.FORWARD

	# 弯曲方向：指尖朝向该指自己的掌骨通道（非共用腕心）
	var to_target_sk := curl_target_sk - rest.origin
	if to_target_sk.length_squared() < 0.0001:
		return Vector3.RIGHT
	var target_local := (rest.basis.inverse() * to_target_sk.normalized()).normalized()

	var axis := finger_dir.cross(target_local)
	if axis.length_squared() < 0.0001:
		return Vector3.RIGHT
	axis = axis.normalized()
	if (Quaternion(axis, 0.05) * finger_dir).dot(target_local) < finger_dir.dot(target_local):
		axis = -axis
	return axis


func _apply_mesh_visibility() -> void:
	if _skeleton == null or _visibility_applied:
		return
	if not hide_left_arm and not hide_right_upper_arm and not hide_reference_mesh:
		return
	_visibility_applied = true

	var visible_bones := _collect_visible_bone_set()
	var filtered_count := 0
	for node in hand_model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.skin == null or mi.mesh == null:
			continue
		var source := mi.mesh as ArrayMesh
		if source == null or source.get_surface_count() == 0:
			continue
		mi.mesh = _build_filtered_mesh(source, visible_bones)
		filtered_count += 1

	print(
		"Mesh filtered: %d skinned mesh(es), visible bones=%d (left=%s hand-only=%s ref=%s)"
		% [filtered_count, visible_bones.size(), hide_left_arm, hide_right_upper_arm, hide_reference_mesh]
	)


func _collect_visible_bone_set() -> Dictionary:
	var visible := {}
	for i in _skeleton.get_bone_count():
		var bone_name := _skeleton.get_bone_name(i)
		if hide_left_arm and (bone_name.begins_with("Left") or bone_name.contains(".L")):
			continue
		if hide_reference_mesh and bone_name in _REFERENCE_BONES:
			continue
		if hide_right_upper_arm and _bone_name_matches_any(bone_name, _RIGHT_UPPER_ARM_BONES):
			continue
		if _bone_name_has_hidden_substring(bone_name):
			continue
		visible[i] = true
	return visible


func _vertex_visible_for_bones(
	vertex_idx: int,
	bones: PackedInt32Array,
	weights: PackedFloat32Array,
	visible_bones: Dictionary
) -> bool:
	var visible_sum := 0.0
	var hidden_sum := 0.0
	var base := vertex_idx * 4
	for j in 4:
		var w := weights[base + j]
		if w <= 0.0:
			continue
		if visible_bones.has(bones[base + j]):
			visible_sum += w
		else:
			hidden_sum += w
	return visible_sum >= hidden_sum


func _build_filtered_mesh(source: ArrayMesh, visible_bones: Dictionary) -> ArrayMesh:
	var arrays := source.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var bone_indices: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var bone_weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]

	var keep := PackedByteArray()
	keep.resize(vertices.size())
	for v in vertices.size():
		keep[v] = 1 if _vertex_visible_for_bones(v, bone_indices, bone_weights, visible_bones) else 0

	var remap := PackedInt32Array()
	remap.resize(vertices.size())
	remap.fill(-1)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var new_count := 0
	for v in vertices.size():
		if keep[v] == 0:
			continue
		remap[v] = new_count
		if normals.size() > v:
			st.set_normal(normals[v])
		if uvs.size() > v:
			st.set_uv(uvs[v])
		var skin_bones := PackedInt32Array()
		var skin_weights := PackedFloat32Array()
		skin_bones.resize(4)
		skin_weights.resize(4)
		var base := v * 4
		for j in 4:
			skin_bones[j] = bone_indices[base + j]
			skin_weights[j] = bone_weights[base + j]
		st.set_bones(skin_bones)
		st.set_weights(skin_weights)
		st.add_vertex(vertices[v])
		new_count += 1

	if indices.size() > 0:
		for i in range(0, indices.size(), 3):
			var i0: int = indices[i]
			var i1: int = indices[i + 1]
			var i2: int = indices[i + 2]
			if keep[i0] and keep[i1] and keep[i2]:
				st.add_index(remap[i0])
				st.add_index(remap[i1])
				st.add_index(remap[i2])

	var mesh: ArrayMesh = st.commit()
	var mat := source.surface_get_material(0)
	if mat:
		mesh.surface_set_material(0, mat)
	return mesh


func _recenter_on_palm() -> void:
	if _skeleton == null:
		return

	var palm_local := _compute_palm_center_local()
	for child in hand_model.get_children():
		if child is Node3D:
			child.position -= palm_local
	print("Recentered on palm center: offset=%s" % palm_local)


func _compute_palm_center_local() -> Vector3:
	var sum := Vector3.ZERO
	var count := 0
	for node in hand_model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var aabb := mi.get_aabb()
		if aabb.size.length_squared() < 0.000001:
			continue
		var center_world := mi.global_transform * aabb.get_center()
		sum += hand_model.to_local(center_world)
		count += 1
	if count > 0:
		return sum / float(count)
	return _compute_palm_center_bones_local()


func _compute_palm_center_bones_local() -> Vector3:
	if _skeleton == null or _wrist_bone_idx < 0:
		return Vector3.ZERO

	var wrist_sk := _skeleton.get_bone_global_rest(_wrist_bone_idx).origin
	var finger_sum := Vector3.ZERO
	var finger_count := 0
	for idx in _finger_bone_indices:
		if idx < 0:
			continue
		finger_sum += _skeleton.get_bone_global_rest(idx).origin
		finger_count += 1

	var palm_sk := wrist_sk
	if finger_count > 0:
		var finger_hub := finger_sum / float(finger_count)
		palm_sk = wrist_sk.lerp(finger_hub, 0.45)

	return hand_model.to_local(_skeleton.global_transform * palm_sk)


func _capture_wrist_bind_quat() -> void:
	if _skeleton == null or _wrist_bone_idx < 0:
		return
	_skeleton.reset_bone_pose(_wrist_bone_idx)
	var bind_pose := _skeleton.get_bone_global_pose(_wrist_bone_idx)
	_wrist_bind_quat = bind_pose.basis.get_rotation_quaternion().normalized()
	var e := _wrist_bind_quat.get_euler()
	print(
		"Wrist bind captured. Euler(deg): (%.1f, %.1f, %.1f)"
		% [rad_to_deg(e.x), rad_to_deg(e.y), rad_to_deg(e.z)]
	)
	if auto_model_align:
		_apply_auto_model_align()


func _apply_auto_model_align() -> void:
	if _skeleton == null or _wrist_bone_idx < 0:
		return

	var hand_p := _skeleton.get_bone_global_rest(_wrist_bone_idx).origin
	var mid_i := _finger_bone_indices[2] if _finger_bone_indices.size() > 2 else -1
	var thumb_i := _finger_bone_indices[0] if _finger_bone_indices.size() > 0 else -1
	if mid_i < 0 or thumb_i < 0:
		push_warning("Auto model align: missing finger bones")
		_model_align_quat = _wrist_bind_quat.inverse().normalized()
		return

	var finger := (_skeleton.get_bone_global_rest(mid_i).origin - hand_p).normalized()
	var thumb := (_skeleton.get_bone_global_rest(thumb_i).origin - hand_p).normalized()
	if finger.length_squared() < 0.0001 or thumb.length_squared() < 0.0001:
		push_warning("Auto model align: degenerate finger vectors")
		_model_align_quat = _wrist_bind_quat.inverse().normalized()
		return

	# 正交化手系：z=指尖, x=拇指(去掉沿指尖分量), y=z×x → 手背 +Y
	var z_axis := finger
	var x_axis := (thumb - z_axis * z_axis.dot(thumb)).normalized()
	if x_axis.length_squared() < 0.0001:
		_model_align_quat = _wrist_bind_quat.inverse().normalized()
		return
	var y_axis := z_axis.cross(x_axis).normalized()

	var model_q := Basis(x_axis, y_axis, z_axis).get_rotation_quaternion()
	var desired_q := Basis(
		Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, -1)
	).get_rotation_quaternion()
	_model_align_quat = (desired_q * model_q.inverse()).normalized()

	var aligned_finger := _model_align_quat * finger
	var aligned_back := _model_align_quat * y_axis
	print("Auto align finger -> %s, back -> %s" % [aligned_finger, aligned_back])

	var align_e := _model_align_quat.get_euler()
	model_align_euler_deg = Vector3(rad_to_deg(align_e.x), rad_to_deg(align_e.y), rad_to_deg(align_e.z))
	print("Auto model align euler deg: ", model_align_euler_deg)


func _resolve_bone_index(export_name: String, candidates: Array) -> int:
	if export_name != "":
		var idx := _find_bone_by_prefix(export_name)
		if idx >= 0:
			return idx
		push_warning("未找到导出骨骼: %s" % export_name)
	for name in candidates:
		var idx2 := _find_bone_by_prefix(str(name))
		if idx2 >= 0:
			return idx2
	return -1


func _find_bone_by_prefix(prefix: String) -> int:
	if _skeleton == null or prefix == "":
		return -1
	var exact := _skeleton.find_bone(prefix)
	if exact >= 0:
		return exact
	for i in _skeleton.get_bone_count():
		if _skeleton.get_bone_name(i).begins_with(prefix):
			return i
	return -1


func _bone_name_matches_any(bone_name: String, candidates: Array[String]) -> bool:
	for candidate in candidates:
		if bone_name == candidate or bone_name.begins_with(candidate):
			return true
	return false


func _bone_name_has_hidden_substring(bone_name: String) -> bool:
	for token in _HIDDEN_BONE_SUBSTRINGS:
		if bone_name.contains(token):
			return true
	return false


func _print_bone_names() -> void:
	if _skeleton == null:
		print("无 Skeleton3D")
		return
	print("=== Skeleton bones (%d) ===" % _skeleton.get_bone_count())
	for i in _skeleton.get_bone_count():
		print("  [%d] %s" % [i, _skeleton.get_bone_name(i)])


func _print_bone_mapping() -> void:
	if _skeleton == null:
		return
	print("=== Bone mapping ===")
	print("Wrist [%d]: %s" % [_wrist_bone_idx, _bone_name_or_none(_wrist_bone_idx)])
	var labels := ["Thumb", "Index", "Middle", "Ring", "Pinky"]
	for i in 5:
		print("%s [%d]: %s" % [labels[i], _finger_bone_indices[i], _bone_name_or_none(_finger_bone_indices[i])])
	if not _bones_ready:
		push_warning("手腕骨骼未映射，按 P 查看全部骨骼名并在 Inspector 填写")


func _bone_name_or_none(idx: int) -> String:
	if idx < 0:
		return "(none)"
	return _skeleton.get_bone_name(idx)


# Android ENU → Godot (Y上, -Z前)
func _enu_to_godot_basis() -> Basis:
	return Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0))


# Sensor X=拇指(-X), Y=指尖(-Z), Z=手背(+Y)
func _sensor_to_hand_basis() -> Basis:
	return Basis(Vector3(-1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0))


func _sensor_to_hand_quat() -> Quaternion:
	return _sensor_to_hand_basis().get_rotation_quaternion()


func _world_hand_quat_from_sensor(q_raw: Quaternion) -> Quaternion:
	var q_enu := (_enu_to_godot_basis().get_rotation_quaternion() * q_raw).normalized()
	return (q_enu * _sensor_to_hand_quat().inverse()).normalized()


func _remap_acc(acc: Vector3) -> Vector3:
	return _enu_to_godot_basis() * _sensor_to_hand_basis().inverse() * acc


func _aligned_sensor_quat() -> Quaternion:
	var q := _world_hand_quat_from_sensor(hand_quat_raw)
	return (_mount_quat * q).normalized()


func get_calibrated_quat() -> Quaternion:
	var q := _aligned_sensor_quat()
	if is_calibrated:
		q = rest_quat_inv * q
	# v11：Y 水平转取反；X↔Z 互换；翻掌方向再取反
	var euler := q.get_euler()
	return Quaternion.from_euler(Vector3(euler.z, -euler.y, euler.x)).normalized()


func get_calibrated_acc() -> Vector3:
	var acc := motion_acc_raw
	if is_calibrated:
		acc -= acc_bias
	acc = _remap_acc(acc)
	return _mount_quat * acc


func _sync_flex_closed_from_exports() -> void:
	flex_closed_finger = [
		flex_closed_thumb,
		flex_closed_index,
		flex_closed_middle,
		flex_closed_ring,
		flex_closed_pinky,
	]


func _default_flex_closed(finger: int) -> float:
	if finger < 0 or finger >= 5:
		return 600.0
	return _DEFAULT_FLEX_CLOSED[finger]


func _validate_flex_closed() -> void:
	var labels := ["thumb", "index", "middle", "ring", "pinky"]
	var repaired := false
	for i in 5:
		var open_v := _flex_open_value(i)
		var span := open_v - flex_closed_finger[i]
		if flex_closed_finger[i] >= open_v:
			var fallback := minf(_default_flex_closed(i), open_v - _MIN_FLEX_SPAN_WARN)
			push_warning(
				"Finger %s: flex_closed %.0f >= open %.0f, reset to %.0f"
				% [labels[i], flex_closed_finger[i], open_v, fallback]
			)
			flex_closed_finger[i] = fallback
			repaired = true
		elif span < _MIN_FLEX_SPAN_WARN:
			push_warning(
				"Finger %s: flex span only %.0f ADC — re-calibrate with F if bending is weak"
				% [labels[i], span]
			)
	if repaired and is_calibrated:
		_save_calibration()


func _flex_open_value(finger: int) -> float:
	if finger < 0 or finger >= 5:
		return 950.0
	if is_calibrated and flex_rest[finger] > 1.0:
		return flex_rest[finger]
	return DEFAULT_FLEX_OPEN[finger]


func _flex_span(finger: int) -> float:
	if finger < 0 or finger >= 5:
		return 1.0
	return maxf(_flex_open_value(finger) - flex_closed_finger[finger], 1.0)


func _flex_dead_zone_for(finger: int) -> float:
	return maxf(flex_dead_zone_min, _flex_span(finger) * flex_dead_zone_ratio)


func get_calibrated_flex() -> Array[float]:
	var out: Array[float] = []
	out.resize(5)
	for i in 5:
		if is_calibrated:
			out[i] = flex_raw[i] - flex_rest[i]
		else:
			out[i] = flex_raw[i]
	return out


func _filter_flex(raw_flex: Array[float], delta: float, apply_dead_zone: bool = true) -> Array[float]:
	var out: Array[float] = []
	out.resize(5)
	var alpha := 1.0
	if flex_smooth_time > 0.0001:
		alpha = 1.0 - exp(-delta / flex_smooth_time)
	for i in 5:
		var v := raw_flex[i]
		if is_calibrated and apply_dead_zone:
			var dz := _flex_dead_zone_for(i)
			if absf(v) < dz:
				v = 0.0
			elif v > 0.0:
				v = 0.0
		_flex_filtered[i] = lerpf(_flex_filtered[i], v, alpha)
		out[i] = _flex_filtered[i]
	return out


func _average_recent_flex(finger: int) -> float:
	if _flex_recent.is_empty():
		return flex_raw[finger]
	var sum := 0.0
	for sample in _flex_recent:
		sum += float(sample[finger])
	return sum / float(_flex_recent.size())


func _reset_flex_filter_state() -> void:
	for i in 5:
		_flex_filtered[i] = 0.0
	_flex_recent.clear()


func _flex_bend_range_ratio(finger_idx: int) -> float:
	if flex_bend_range_ratios.size() > finger_idx:
		return maxf(flex_bend_range_ratios[finger_idx], 0.35)
	if finger_idx < _DEFAULT_BEND_RANGE_RATIOS.size():
		return _DEFAULT_BEND_RANGE_RATIOS[finger_idx]
	return 1.0


func _flex_to_bend(flex_value: float, finger_idx: int, use_calibrated_delta: bool) -> float:
	var span := _flex_span(finger_idx)
	var effective_span := span * _flex_bend_range_ratio(finger_idx)
	# 仅拒绝 corrupt span（closed>=open 时 _flex_span 返回 1）；勿用 effective_span<1 判无效
	if span < 1.0:
		return 0.0
	if use_calibrated_delta:
		return clampf(-flex_value / effective_span, 0.0, 1.0)
	return clampf(
		inverse_lerp(
			_flex_open_value(finger_idx),
			_flex_open_value(finger_idx) - effective_span,
			flex_value
		),
		0.0,
		1.0
	)


func _finger_spread_phase(bend: float) -> float:
	return clampf(bend, 0.0, 1.0)


func _finger_curl_phase(bend: float) -> float:
	if bend <= 0.001:
		return 0.0
	var t := clampf(bend, 0.0, 1.0)
	var p := maxf(finger_curl_ease_power, 1.0)
	# smoothstep 慢起步，无弯拢阈值导致的导数突变
	if absf(p - 2.0) < 0.001:
		return t * t * (3.0 - 2.0 * t)
	if absf(p - 3.0) < 0.001:
		return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
	return pow(t, p)


func _finger_curl_scale(finger_idx: int) -> float:
	if finger_curl_scales.size() > finger_idx:
		return finger_curl_scales[finger_idx]
	if finger_idx < _DEFAULT_FINGER_CURL_SCALES.size():
		return _DEFAULT_FINGER_CURL_SCALES[finger_idx]
	return 1.0


func _finger_splay_sign(finger_idx: int) -> float:
	if finger_idx >= 0 and finger_idx < _finger_splay_signs.size():
		return _finger_splay_signs[finger_idx]
	return 0.0


func _finger_abduction_rad(finger_idx: int, spread_phase: float, curl_phase: float) -> float:
	var mag := absf(_finger_splay_deg(finger_idx))
	if mag <= 0.001 or spread_phase <= 0.001:
		return 0.0
	var sign := _finger_splay_sign(finger_idx)
	if finger_idx == 1:
		sign = -sign
	var mix := clampf(finger_abduct_curl_mix, 0.0, 1.0)
	return deg_to_rad(mag) * sign * spread_phase * lerpf(1.0, mix, curl_phase)


func _finger_flexion_rad(finger_idx: int, curl_phase: float) -> float:
	if curl_phase <= 0.001:
		return 0.0
	return deg_to_rad(finger_curl_deg) * _finger_curl_scale(finger_idx) * curl_phase


func _finger_splay_deg(finger_idx: int) -> float:
	if finger_fist_splay_deg.size() > finger_idx:
		return finger_fist_splay_deg[finger_idx]
	if finger_idx < _DEFAULT_FINGER_SPLAY_DEG.size():
		return _DEFAULT_FINGER_SPLAY_DEG[finger_idx]
	return 0.0


func _flex_to_curl_rad(flex_value: float, finger_idx: int, use_calibrated_delta: bool) -> float:
	var bend := _flex_to_bend(flex_value, finger_idx, use_calibrated_delta)
	return deg_to_rad(finger_curl_deg) * _finger_curl_scale(finger_idx) * bend


func _chain_weight(seg: int, finger_idx: int) -> float:
	if finger_idx >= 0 and finger_idx < _finger_chain_weight_sets.size():
		var per_finger: Array = _finger_chain_weight_sets[finger_idx]
		if seg < per_finger.size():
			return per_finger[seg]
	if finger_chain_weights.size() > seg:
		return finger_chain_weights[seg]
	if seg < _DEFAULT_CHAIN_WEIGHTS.size():
		return _DEFAULT_CHAIN_WEIGHTS[seg]
	return 0.0


func _chain_weight_for(finger_idx: int, seg: int, curl_phase: float) -> float:
	var w := _chain_weight(seg, finger_idx)
	if seg == 0 and curl_phase > 0.001 and finger_mcp_boost_max > 1.001:
		w *= lerpf(1.0, finger_mcp_boost_max, curl_phase * curl_phase)
	return w


func calibrate_now() -> void:
	if _demo_mode:
		print("Demo mode active — press T to exit before calibrating")
		return
	if hand_quat_raw.length_squared() < 0.1:
		print("Calibration skipped: no quaternion data yet")
		return

	var q_ref := _aligned_sensor_quat()
	rest_quat_inv = q_ref.inverse()
	acc_bias = motion_acc_raw
	for i in 5:
		flex_rest[i] = _average_recent_flex(i)
	is_calibrated = true
	_reset_flex_filter_state()
	_validate_flex_closed()
	_save_calibration()

	print(
		"Flex open  (thumb→pinky): %.0f, %.0f, %.0f, %.0f, %.0f"
		% [flex_rest[0], flex_rest[1], flex_rest[2], flex_rest[3], flex_rest[4]]
	)
	print(
		"Flex closed(thumb→pinky): %.0f, %.0f, %.0f, %.0f, %.0f"
		% [
			flex_closed_finger[0], flex_closed_finger[1], flex_closed_finger[2],
			flex_closed_finger[3], flex_closed_finger[4],
		]
	)
	print(
		"Flex span  (thumb→pinky): %.0f, %.0f, %.0f, %.0f, %.0f"
		% [_flex_span(0), _flex_span(1), _flex_span(2), _flex_span(3), _flex_span(4)]
	)

	var e := get_calibrated_quat().get_euler()
	print(
		"Calibrated. Euler(deg): (%.1f, %.1f, %.1f)"
		% [rad_to_deg(e.x), rad_to_deg(e.y), rad_to_deg(e.z)]
	)
	_update_debug_label(get_calibrated_quat(), get_calibrated_flex())


func calibrate_fist_closed() -> void:
	if _demo_mode:
		print("Demo mode active — press T to exit before calibrating")
		return
	for i in 5:
		flex_closed_finger[i] = _average_recent_flex(i)
	print(
		"Fist flex closed (thumb→pinky): %.0f, %.0f, %.0f, %.0f, %.0f"
		% [
			flex_closed_finger[0], flex_closed_finger[1], flex_closed_finger[2],
			flex_closed_finger[3], flex_closed_finger[4],
		]
	)
	_validate_flex_closed()
	if is_calibrated:
		_save_calibration()
	_reset_flex_filter_state()


func reset_calibration() -> void:
	is_calibrated = false
	rest_quat_inv = Quaternion.IDENTITY
	acc_bias = Vector3.ZERO
	for i in 5:
		flex_rest[i] = 0.0
	_reset_flex_filter_state()
	if FileAccess.file_exists(CALIBRATION_PATH):
		DirAccess.remove_absolute(CALIBRATION_PATH)
	print("Calibration reset")
	_update_help_text()


func _cycle_mount_preset() -> void:
	var presets := [
		Vector3.ZERO,
		Vector3(0, 180, 0),
		Vector3(0, 90, 0),
		Vector3(0, -90, 0),
		Vector3(180, 0, 0),
		Vector3(90, 0, 0),
		Vector3(-90, 0, 0),
	]
	var idx := 0
	for i in presets.size():
		if presets[i].is_equal_approx(mount_euler_deg):
			idx = (i + 1) % presets.size()
			break
	mount_euler_deg = presets[idx]
	_update_mount_quat()
	print("Mount preset: ", mount_euler_deg)
	if _packet_count > 0:
		_update_debug_label(get_calibrated_quat(), get_calibrated_flex())


func _update_mount_quat() -> void:
	_mount_quat = Quaternion.from_euler(
		Vector3(
			deg_to_rad(mount_euler_deg.x),
			deg_to_rad(mount_euler_deg.y),
			deg_to_rad(mount_euler_deg.z)
		)
	)


func _update_model_align_quat() -> void:
	_model_align_quat = Quaternion.from_euler(
		Vector3(
			deg_to_rad(model_align_euler_deg.x),
			deg_to_rad(model_align_euler_deg.y),
			deg_to_rad(model_align_euler_deg.z)
		)
	)


func _apply_to_scene(delta: float) -> void:
	var hand_quat := _model_align_quat * get_calibrated_quat()
	var flex := _filter_flex(get_calibrated_flex(), delta)

	_apply_wrist_pose(hand_quat)
	_apply_finger_poses(flex)
	_update_debug_label(hand_quat, flex)


func _toggle_demo_mode() -> void:
	_demo_mode = not _demo_mode
	if _demo_mode:
		_demo_bend = 0.0
		_reset_flex_filter_state()
		print("Demo mode ON — +/- adjust bend, T exit (no BLE needed)")
	else:
		_drain_udp_packets()
		_reset_flex_filter_state()
		print("Demo mode OFF — UDP backlog cleared")
	_update_help_text()


func _adjust_demo_bend(delta: float) -> void:
	if not _demo_mode:
		return
	_demo_bend = clampf(_demo_bend + delta, 0.0, 1.0)
	print("Demo bend: %.0f%%" % (_demo_bend * 100.0))


func _demo_flex_delta() -> Array[float]:
	var out: Array[float] = []
	out.resize(5)
	for i in 5:
		var effective_span := _flex_span(i) * _flex_bend_range_ratio(i)
		out[i] = -_demo_bend * effective_span
	return out


func _apply_demo_scene(delta: float) -> void:
	var flex := _filter_flex(_demo_flex_delta(), delta, false)
	var hand_quat := _model_align_quat * get_calibrated_quat()
	_apply_wrist_pose(hand_quat)
	_apply_finger_poses(flex)
	_update_debug_label(hand_quat, flex)


func _apply_wrist_pose(hand_quat: Quaternion) -> void:
	# 已 recenter 到掌心，整节点旋转 = 绕掌心旋转
	hand_model.quaternion = hand_quat


func _apply_finger_poses(flex: Array[float]) -> void:
	if _skeleton == null:
		return

	for chain in _finger_chain_indices:
		for bone_idx in chain:
			_skeleton.reset_bone_pose(bone_idx)

	for i in 5:
		if _finger_chain_indices.size() <= i:
			continue
		var chain: Array = _finger_chain_indices[i]
		if chain.is_empty():
			continue

		var bend := _flex_to_bend(flex[i], i, is_calibrated)
		var spread_phase := _finger_spread_phase(bend)
		var curl_phase := _finger_curl_phase(bend)
		if spread_phase <= 0.001 and curl_phase <= 0.001:
			continue

		var flexion := _finger_flexion_rad(i, curl_phase)
		if i > 0:
			flexion = -flexion
		var abduction := _finger_abduction_rad(i, spread_phase, curl_phase)
		var root_idx: int = chain[0]
		var abduct_axis: Vector3 = _bone_splay_axes.get(root_idx, Vector3.UP)

		for seg in chain.size():
			var bone_idx: int = chain[seg]
			var weight := _chain_weight_for(i, seg, curl_phase)
			var flex_axis: Vector3 = _bone_curl_axes.get(bone_idx, Vector3.RIGHT)
			var rot := Quaternion.IDENTITY
			if seg == 0:
				var flex_rot := Quaternion.IDENTITY
				var abduct_rot := Quaternion.IDENTITY
				if absf(flexion) > 0.001 and weight > 0.001:
					flex_rot = Quaternion(flex_axis, flexion * weight)
				if absf(abduction) > 0.001:
					abduct_rot = Quaternion(abduct_axis, abduction)
				# 先弯后展：在掌骨长节段承担主弯，减少展+弯非交换合成侧倾
				if flex_rot != Quaternion.IDENTITY and abduct_rot != Quaternion.IDENTITY:
					rot = flex_rot * abduct_rot
				elif flex_rot != Quaternion.IDENTITY:
					rot = flex_rot
				else:
					rot = abduct_rot
			else:
				if weight <= 0.001 or absf(flexion) <= 0.001:
					continue
				rot = Quaternion(flex_axis, flexion * weight)
			if rot != Quaternion.IDENTITY:
				_skeleton.set_bone_pose_rotation(bone_idx, rot)


func _zero_pose_hint() -> String:
	return "零位(右手): 掌心朝下(-Y), 手指朝前(-Z), 拇指朝身体左侧(-X)"


func _update_debug_label(hand_quat: Quaternion, flex: Array[float]) -> void:
	var calib_text := "已校准" if is_calibrated else "未校准（摆好零位后按 C）"
	if _demo_mode:
		calib_text = "演示模式 %.0f%%" % (_demo_bend * 100.0)
	var euler := hand_quat.get_euler()
	var skel_text := "骨骼: OK" if _bones_ready else "骨骼: 未就绪(按P查骨骼名)"
	debug_label.text = (
		(
			"%s | %s\n%s\n"
			+ "Packets: %d | Mount: (%.0f,%.0f,%.0f) | ModelAlign: (%.0f,%.0f,%.0f)\n"
			+ "Euler(deg): X=%.0f Y=%.0f Z=%.0f\n"
			+ "Flex delta: %.0f, %.0f, %.0f, %.0f, %.0f\n"
			+ "C=校准伸直 | F=校准握拳 | R=清除 | M=安装微调 | P=打印骨骼 | T=演示模式"
		)
		% [
			calib_text,
			skel_text,
			_zero_pose_hint(),
			_packet_count,
			mount_euler_deg.x, mount_euler_deg.y, mount_euler_deg.z,
			model_align_euler_deg.x, model_align_euler_deg.y, model_align_euler_deg.z,
			rad_to_deg(euler.x), rad_to_deg(euler.y), rad_to_deg(euler.z),
			flex[0], flex[1], flex[2], flex[3], flex[4],
		]
	)


func _update_help_text() -> void:
	if _packet_count > 0:
		return

	if not _udp_ready:
		debug_label.text = (
			"UDP 端口 %d 绑定失败: %s\n请关闭占用端口的 Godot 进程后重试"
		) % [PORT, _udp_error]
		return

	debug_label.text = (
		(
			"等待 UDP 端口 %d 数据... (%.0f 秒)\n"
			+ "%s\n\n"
			+ "1. 手模已使用 assets/scene.gltf\n"
			+ "2. 摆零位后按 C 校准；无手套时按 T 进入演示模式（+/- 调弯拢）\n"
			+ "3. 握紧拳后按 F 记录握拳 flex（可选，已有实测默认值）\n"
			+ "4. 骨骼不对时按 P 查看名称并在 Inspector 填写"
		)
		% [PORT, _wait_seconds, _zero_pose_hint()]
	)


func _save_calibration() -> void:
	var data := {
		"calibration_version": CALIBRATION_VERSION,
		"rest_quat_inv": [
			rest_quat_inv.x, rest_quat_inv.y, rest_quat_inv.z, rest_quat_inv.w
		],
		"acc_bias": [acc_bias.x, acc_bias.y, acc_bias.z],
		"flex_rest": flex_rest.duplicate(),
		"flex_closed": flex_closed_finger.duplicate(),
		"mount_euler_deg": [mount_euler_deg.x, mount_euler_deg.y, mount_euler_deg.z],
	}
	var file := FileAccess.open(CALIBRATION_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data))
		file.close()


func _load_calibration() -> void:
	if not FileAccess.file_exists(CALIBRATION_PATH):
		return

	var file := FileAccess.open(CALIBRATION_PATH, FileAccess.READ)
	if not file:
		return

	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return

	var data: Dictionary = parsed
	if (
		not data.has("calibration_version")
		or int(data["calibration_version"]) != CALIBRATION_VERSION
	):
		print("Old calibration ignored (need v%d) — press R then C" % CALIBRATION_VERSION)
		return

	if data.has("rest_quat_inv"):
		var q: Array = data["rest_quat_inv"]
		if q.size() == 4:
			rest_quat_inv = Quaternion(q[0], q[1], q[2], q[3]).normalized()
	if data.has("acc_bias"):
		var a: Array = data["acc_bias"]
		if a.size() == 3:
			acc_bias = Vector3(a[0], a[1], a[2])
	if data.has("flex_rest"):
		var f: Array = data["flex_rest"]
		for i in mini(5, f.size()):
			flex_rest[i] = float(f[i])
	if data.has("flex_closed"):
		var c: Array = data["flex_closed"]
		for i in mini(5, c.size()):
			flex_closed_finger[i] = float(c[i])
	if data.has("mount_euler_deg"):
		var m: Array = data["mount_euler_deg"]
		if m.size() == 3:
			mount_euler_deg = Vector3(float(m[0]), float(m[1]), float(m[2]))
			_update_mount_quat()

	is_calibrated = true
	_reset_flex_filter_state()
	_validate_flex_closed()
	print("Loaded glove calibration v", CALIBRATION_VERSION)
