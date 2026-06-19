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

	for scheme in [_v12(), _anatomy()]:
		print("\n== %s ==" % scheme.name)
		for fi in [1, 4]:
			_print_snap_window(main, sk, fi, scheme)
	quit()


func _v12() -> Dictionary:
	return {
		"name": "v12_abduct*flex",
		"w": [0.52, 0.58, 0.54, 0.26],
		"order": "abduct*flex",
		"mix": 1.0,
		"boost_seg": 0,
	}


func _anatomy() -> Dictionary:
	return {
		"name": "anatomy_flex*abduct_mix",
		"w": [0.55, 0.28, 0.22, 0.10],
		"order": "flex*abduct",
		"mix": 0.50,
		"boost_seg": 0,
	}


func _print_snap_window(main: Node, sk: Skeleton3D, fi: int, scheme: Dictionary) -> void:
	var prev := Vector3.ZERO
	var max_jump := 0.0
	var max_bend := 0.0
	for step in 80:
		var bend := float(step) * 0.005
		_apply(main, sk, fi, bend, scheme)
		var tip := _tip(sk, fi)
		if step > 0 and bend >= 0.15 and bend <= 0.40:
			var j := tip.distance_to(prev)
			if j > max_jump:
				max_jump = j
				max_bend = bend
		prev = tip
	print("  %s max jump in [0.15,0.40] = %.5f at bend=%.3f" % [NAMES[fi], max_jump, max_bend])


func _apply(main: Node, sk: Skeleton3D, fi: int, bend: float, scheme: Dictionary) -> void:
	for chain in main.get("_finger_chain_indices"):
		for b in chain:
			sk.reset_bone_pose(b)
	var flex: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0]
	flex[fi] = -bend * main.call("_flex_span", fi) * main.call("_flex_bend_range_ratio", fi)
	var bend_v: float = main.call("_flex_to_bend", flex[fi], fi, true)
	var curl_p := bend_v * bend_v * (3.0 - 2.0 * bend_v)
	var flexion: float = main.call("_finger_flexion_rad", fi, curl_p)
	if fi > 0:
		flexion = -flexion
	var abduction: float = main.call("_finger_abduction_rad", fi, bend_v)
	abduction *= lerpf(1.0, scheme.mix, curl_p)
	var chain: Array = main.get("_finger_chain_indices")[fi]
	var splay_axes: Dictionary = main.get("_bone_splay_axes")
	var curl_axes: Dictionary = main.get("_bone_curl_axes")
	var boost_max: float = main.get("finger_mcp_boost_max")
	for seg in chain.size():
		var bone_idx: int = chain[seg]
		var w: float = scheme.w[seg]
		if seg == scheme.boost_seg and curl_p > 0.001:
			w *= lerpf(1.0, boost_max, curl_p * curl_p)
		var rot := Quaternion.IDENTITY
		if seg == 0:
			var fr := Quaternion.IDENTITY
			var ar := Quaternion.IDENTITY
			if absf(flexion) > 0.001 and w > 0.001:
				fr = Quaternion(curl_axes.get(bone_idx, Vector3.RIGHT), flexion * w)
			if absf(abduction) > 0.001:
				ar = Quaternion(splay_axes.get(bone_idx, Vector3.UP), abduction)
			rot = fr * ar if scheme.order == "flex*abduct" else ar * fr
			if fr == Quaternion.IDENTITY:
				rot = ar
			elif ar == Quaternion.IDENTITY:
				rot = fr
		elif w > 0.001 and absf(flexion) > 0.001:
			rot = Quaternion(curl_axes.get(bone_idx, Vector3.RIGHT), flexion * w)
		if rot != Quaternion.IDENTITY:
			sk.set_bone_pose_rotation(bone_idx, rot)
	for bi in sk.get_bone_count():
		sk.force_update_bone_child_transform(bi)


func _tip(sk: Skeleton3D, fi: int) -> Vector3:
	var idx := sk.find_bone("%s4" % PREFIXES[fi])
	if idx < 0:
		idx = sk.find_bone("%s3" % PREFIXES[fi])
	return sk.get_bone_global_pose(idx).origin if idx >= 0 else Vector3.ZERO
