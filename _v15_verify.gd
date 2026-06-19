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

	print("=== v15 joint angles at bend=1 ===")
	for fi in 5:
		_apply_all(main, sk, fi, 1.0)
		var a := _angles(sk, fi)
		print("%s MCP=%.1f PIP=%.1f DIP=%.1f TIP=%.1f" % [NAMES[fi], a[0], a[1], a[2], a[3]])

	print("\n=== v15 trajectory ===")
	for bend in [0.25, 0.5, 0.75, 1.0]:
		_apply_all_uniform(main, sk, bend)
		var tips: Array[Vector3] = []
		for fi in 5:
			tips.append(_tip(sk, fi))
		var min_sep := INF
		for a in [1, 3, 4]:
			for b in [1, 3, 4]:
				if b > a:
					min_sep = minf(min_sep, tips[a].distance_to(tips[b]))
		print("bend=%.2f four-finger min sep=%.4f" % [bend, min_sep])

	print("\n=== v15 onset snap (pinky/index) ===")
	for fi in [1, 4]:
		print("%s max jump [0.15,0.40]=%.5f" % [NAMES[fi], _snap(main, sk, fi)])
	quit()


func _apply_all(main: Node, sk: Skeleton3D, only_fi: int, bend: float) -> void:
	var flex: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0]
	flex[only_fi] = -bend * main.call("_flex_span", only_fi) * main.call("_flex_bend_range_ratio", only_fi)
	main.call("_apply_finger_poses", flex)
	_update(sk)


func _apply_all_uniform(main: Node, sk: Skeleton3D, bend: float) -> void:
	var flex: Array[float] = []
	flex.resize(5)
	for fi in 5:
		flex[fi] = -bend * main.call("_flex_span", fi) * main.call("_flex_bend_range_ratio", fi)
	main.call("_apply_finger_poses", flex)
	_update(sk)


func _snap(main: Node, sk: Skeleton3D, fi: int) -> float:
	var prev := Vector3.ZERO
	var max_jump := 0.0
	for step in 80:
		var bend := float(step) * 0.005
		_apply_all(main, sk, fi, bend)
		var tip := _tip(sk, fi)
		if step > 0 and bend >= 0.15 and bend <= 0.40:
			max_jump = maxf(max_jump, tip.distance_to(prev))
		prev = tip
	return max_jump


func _angles(sk: Skeleton3D, fi: int) -> Array[float]:
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


func _update(sk: Skeleton3D) -> void:
	for bi in sk.get_bone_count():
		sk.force_update_bone_child_transform(bi)
