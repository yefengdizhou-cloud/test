extends SceneTree

const PREFIXES: Array[String] = [
	"RightHandThumb", "RightHandIndex", "RightHandMiddle", "RightHandRing", "RightHandPinky",
]
const NAMES: Array[String] = ["thumb", "index", "middle", "ring", "pinky"]


func _init() -> void:
	var main: Node = load("res://test.tscn").instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	main.set("is_calibrated", true)
	main.set("flex_rest", [988.0, 907.0, 925.0, 829.0, 961.0])

	var sk: Skeleton3D = main.find_child("Skeleton3D", true, false) as Skeleton3D
	print("=== Bone lengths & joint angle diagnostic ===")
	for fi in 5:
		_print_bone_lengths(sk, fi)

	print("\n=== Current weights at bend=1 (index finger) ===")
	_apply_bend(main, sk, 1, 1.0)
	_print_joint_angles(sk, 1)

	print("\n=== Compare weight schemes (index, bend=1) ===")
	for scheme in _weight_schemes():
		_apply_bend_with_weights(main, sk, 1, 1.0, scheme.weights, scheme.mcp_boost_seg)
		var angles := _collect_joint_angles(sk, 1)
		print(
			"%s | MCP=%.1f PIP=%.1f DIP=%.1f TIP=%.1f | tip=%s"
			% [scheme.name, angles[0], angles[1], angles[2], angles[3], _tip(sk, 1)]
		)

	quit()


func _weight_schemes() -> Array:
	return [
		{"name": "v14_mcp0", "weights": [0.0, 0.72, 0.66, 0.32], "mcp_boost_seg": 1},
		{"name": "orig_v12", "weights": [0.52, 0.58, 0.54, 0.26], "mcp_boost_seg": 0},
		{"name": "length_prop", "weights": [], "mcp_boost_seg": 0},  # computed
		{"name": "mcp_flex_then_splay", "weights": [0.45, 0.55, 0.50, 0.22], "mcp_boost_seg": 0},
	]


func _print_bone_lengths(sk: Skeleton3D, fi: int) -> void:
	var prefix := PREFIXES[fi]
	var lens: PackedFloat32Array = PackedFloat32Array()
	for seg in 4:
		var idx := sk.find_bone("%s%d" % [prefix, seg + 1])
		if idx < 0:
			lens.append(0.0)
			continue
		var rest := sk.get_bone_rest(idx)
		var child_len := 0.0
		for c in sk.get_bone_count():
			if sk.get_bone_parent(c) == idx:
				child_len = (sk.get_bone_rest(c).origin - rest.origin).length()
				break
		lens.append(child_len)
	print("%s bone lens: %.4f %.4f %.4f %.4f" % [NAMES[fi], lens[0], lens[1], lens[2], lens[3]])


func _apply_bend(main: Node, sk: Skeleton3D, fi: int, bend: float) -> void:
	var flex: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0]
	flex[fi] = -bend * main.call("_flex_span", fi) * main.call("_flex_bend_range_ratio", fi)
	main.call("_apply_finger_poses", flex)
	_update_sk(sk)


func _apply_bend_with_weights(
	main: Node, sk: Skeleton3D, fi: int, bend: float, weights: Array, boost_seg: int
) -> void:
	main.set("finger_chain_weights", weights if not weights.is_empty() else _length_proportional_weights(sk, fi))
	main.set("finger_mcp_boost_max", 1.5)
	# Temporarily patch boost seg via custom apply
	_apply_custom_pose(main, sk, fi, bend, boost_seg)
	_update_sk(sk)


func _length_proportional_weights(sk: Skeleton3D, fi: int) -> Array[float]:
	var prefix := PREFIXES[fi]
	var lens: Array[float] = []
	var total := 0.0
	for seg in 4:
		var idx := sk.find_bone("%s%d" % [prefix, seg + 1])
		var l := 0.0
		if idx >= 0:
			var rest := sk.get_bone_rest(idx)
			for c in sk.get_bone_count():
				if sk.get_bone_parent(c) == idx:
					l = (sk.get_bone_rest(c).origin - rest.origin).length()
					break
		lens.append(l)
		total += l
	var w: Array[float] = []
	for l in lens:
		w.append(l / total if total > 0.001 else 0.25)
	return w


func _apply_custom_pose(main: Node, sk: Skeleton3D, fi: int, bend: float, boost_seg: int) -> void:
	for chain in main.get("_finger_chain_indices"):
		for bone_idx in chain:
			sk.reset_bone_pose(bone_idx)

	var flex: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0]
	flex[fi] = -bend * main.call("_flex_span", fi) * main.call("_flex_bend_range_ratio", fi)
	var bend_v: float = main.call("_flex_to_bend", flex[fi], fi, true)
	var spread_p: float = main.call("_finger_spread_phase", bend_v)
	var curl_p: float = main.call("_finger_curl_phase", bend_v)
	var flexion: float = main.call("_finger_flexion_rad", fi, curl_p)
	if fi > 0:
		flexion = -flexion
	var abduction: float = main.call("_finger_abduction_rad", fi, spread_p)
	var chain: Array = main.get("_finger_chain_indices")[fi]
	var splay_axes: Dictionary = main.get("_bone_splay_axes")
	var curl_axes: Dictionary = main.get("_bone_curl_axes")
	var weights: Array = main.get("finger_chain_weights")
	var boost_max: float = main.get("finger_mcp_boost_max")

	for seg in chain.size():
		var bone_idx: int = chain[seg]
		var w: float = weights[seg] if seg < weights.size() else 0.0
		if seg == boost_seg and curl_p > 0.001 and boost_max > 1.001:
			w *= lerpf(1.0, boost_max, curl_p * curl_p)
		var rot := Quaternion.IDENTITY
		if seg == 0:
			if absf(abduction) > 0.001:
				rot = Quaternion(splay_axes.get(bone_idx, Vector3.UP), abduction)
			if absf(flexion) > 0.001 and w > 0.001:
				var flex_rot := Quaternion(curl_axes.get(bone_idx, Vector3.RIGHT), flexion * w)
				rot = flex_rot * rot if rot != Quaternion.IDENTITY else flex_rot
		else:
			if w > 0.001 and absf(flexion) > 0.001:
				rot = Quaternion(curl_axes.get(bone_idx, Vector3.RIGHT), flexion * w)
		if rot != Quaternion.IDENTITY:
			sk.set_bone_pose_rotation(bone_idx, rot)


func _update_sk(sk: Skeleton3D) -> void:
	for bi in sk.get_bone_count():
		sk.force_update_bone_child_transform(bi)


func _collect_joint_angles(sk: Skeleton3D, fi: int) -> Array[float]:
	var prefix := PREFIXES[fi]
	var out: Array[float] = []
	for seg in 4:
		var idx := sk.find_bone("%s%d" % [prefix, seg + 1])
		if idx < 0:
			out.append(0.0)
			continue
		var q := sk.get_bone_pose_rotation(idx)
		out.append(absf(rad_to_deg(q.get_angle())))
	return out


func _print_joint_angles(sk: Skeleton3D, fi: int) -> void:
	var a := _collect_joint_angles(sk, fi)
	print("MCP=%.1f PIP=%.1f DIP=%.1f TIP=%.1f" % [a[0], a[1], a[2], a[3]])


func _tip(sk: Skeleton3D, fi: int) -> Vector3:
	var idx := sk.find_bone("%s4" % PREFIXES[fi])
	if idx < 0:
		idx = sk.find_bone("%s3" % PREFIXES[fi])
	return sk.get_bone_global_pose(idx).origin if idx >= 0 else Vector3.ZERO
