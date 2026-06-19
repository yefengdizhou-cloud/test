extends SceneTree

const PREFIXES: Array[String] = [
	"RightHandThumb", "RightHandIndex", "RightHandMiddle", "RightHandRing", "RightHandPinky",
]


func _init() -> void:
	var main: Node = load("res://test.tscn").instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	main.set("is_calibrated", true)
	main.set("flex_rest", [988.0, 907.0, 925.0, 829.0, 961.0])
	var sk: Skeleton3D = main.find_child("Skeleton3D", true, false) as Skeleton3D

	print("=== Scheme comparison (index finger) ===")
	for scheme in _schemes():
		var snap := _max_onset_snap(main, sk, 1, scheme)
		_apply_scheme(main, sk, 1, 1.0, scheme)
		var ang := _joint_angles(sk, 1)
		print(
			"%s | snap=%.5f | MCP=%.1f PIP=%.1f DIP=%.1f TIP=%.1f | tip=%s"
			% [scheme.name, snap, ang[0], ang[1], ang[2], ang[3], _tip(sk, 1)]
		)
	quit()


func _schemes() -> Array:
	return [
		{"name": "v14_broken", "w": [0.0, 0.72, 0.66, 0.32], "boost_seg": 1, "order": "mcp_abduct_only", "abduct_curl_mix": 1.0},
		{"name": "v12_orig", "w": [0.52, 0.58, 0.54, 0.26], "boost_seg": 0, "order": "abduct*flex", "abduct_curl_mix": 1.0},
		{"name": "mcp_heavy", "w": [0.52, 0.30, 0.26, 0.12], "boost_seg": 0, "order": "flex*abduct", "abduct_curl_mix": 1.0},
		{"name": "mcp_heavy_mix", "w": [0.52, 0.30, 0.26, 0.12], "boost_seg": 0, "order": "flex*abduct", "abduct_curl_mix": 0.55},
		{"name": "anatomy", "w": [0.55, 0.28, 0.22, 0.10], "boost_seg": 0, "order": "flex*abduct", "abduct_curl_mix": 0.50},
	]


func _max_onset_snap(main: Node, sk: Skeleton3D, fi: int, scheme: Dictionary) -> float:
	var prev := Vector3.ZERO
	var max_jump := 0.0
	for step in 60:
		var bend := float(step) * 0.005
		_apply_scheme(main, sk, fi, bend, scheme)
		var tip := _tip(sk, fi)
		if step > 0:
			max_jump = maxf(max_jump, tip.distance_to(prev))
		prev = tip
	return max_jump


func _apply_scheme(main: Node, sk: Skeleton3D, fi: int, bend: float, scheme: Dictionary) -> void:
	for chain in main.get("_finger_chain_indices"):
		for b in chain:
			sk.reset_bone_pose(b)

	var flex: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0]
	flex[fi] = -bend * main.call("_flex_span", fi) * main.call("_flex_bend_range_ratio", fi)
	var bend_v: float = main.call("_flex_to_bend", flex[fi], fi, true)
	var spread_p: float = bend_v
	var curl_p: float = _smoothstep(bend_v)
	var flexion: float = main.call("_finger_flexion_rad", fi, curl_p)
	if fi > 0:
		flexion = -flexion
	var abduction: float = main.call("_finger_abduction_rad", fi, spread_p)
	abduction *= lerpf(1.0, scheme.abduct_curl_mix, curl_p)

	var chain: Array = main.get("_finger_chain_indices")[fi]
	var splay_axes: Dictionary = main.get("_bone_splay_axes")
	var curl_axes: Dictionary = main.get("_bone_curl_axes")
	var boost_max: float = main.get("finger_mcp_boost_max")

	for seg in chain.size():
		var bone_idx: int = chain[seg]
		var w: float = scheme.w[seg]
		if seg == scheme.boost_seg and curl_p > 0.001 and boost_max > 1.001:
			w *= lerpf(1.0, boost_max, curl_p * curl_p)
		var rot := Quaternion.IDENTITY
		if seg == 0:
			var flex_rot := Quaternion.IDENTITY
			var abduct_rot := Quaternion.IDENTITY
			if absf(flexion) > 0.001 and w > 0.001 and scheme.order != "mcp_abduct_only":
				flex_rot = Quaternion(curl_axes.get(bone_idx, Vector3.RIGHT), flexion * w)
			if absf(abduction) > 0.001:
				abduct_rot = Quaternion(splay_axes.get(bone_idx, Vector3.UP), abduction)
			if scheme.order == "flex*abduct":
				rot = flex_rot * abduct_rot if flex_rot != Quaternion.IDENTITY else abduct_rot
			elif scheme.order == "abduct*flex":
				rot = abduct_rot * flex_rot if flex_rot != Quaternion.IDENTITY else abduct_rot
			else:
				rot = abduct_rot
		elif w > 0.001 and absf(flexion) > 0.001:
			rot = Quaternion(curl_axes.get(bone_idx, Vector3.RIGHT), flexion * w)
		if rot != Quaternion.IDENTITY:
			sk.set_bone_pose_rotation(bone_idx, rot)
	for bi in sk.get_bone_count():
		sk.force_update_bone_child_transform(bi)


func _smoothstep(t: float) -> float:
	t = clampf(t, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func _joint_angles(sk: Skeleton3D, fi: int) -> Array[float]:
	var out: Array[float] = []
	for seg in 4:
		var idx := sk.find_bone("%s%d" % [PREFIXES[fi], seg + 1])
		out.append(absf(rad_to_deg(sk.get_bone_pose_rotation(idx).get_angle())) if idx >= 0 else 0.0)
	return out


func _tip(sk: Skeleton3D, fi: int) -> Vector3:
	var idx := sk.find_bone("%s4" % PREFIXES[fi])
	if idx < 0:
		idx = sk.find_bone("%s3" % PREFIXES[fi])
	return sk.get_bone_global_pose(idx).origin if idx >= 0 else Vector3.ZERO
