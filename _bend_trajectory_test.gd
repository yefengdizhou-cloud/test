extends SceneTree

const FINGER_NAMES: Array[String] = ["thumb", "index", "middle", "ring", "pinky"]
const TIP_SUFFIX := "4"


func _init() -> void:
	var main: Node = load("res://test.tscn").instantiate()
	root.add_child(main)
	await process_frame
	await process_frame

	var script: Script = main.get_script()
	if script == null:
		push_error("Main script missing")
		quit(1)
		return

	main.set("is_calibrated", true)
	var flex_rest: Array = [988.0, 907.0, 925.0, 829.0, 961.0]
	main.set("flex_rest", flex_rest)

	var sk: Skeleton3D = main.find_child("Skeleton3D", true, false) as Skeleton3D
	if sk == null:
		push_error("Skeleton3D missing")
		quit(1)
		return

	print("=== Two-phase bend trajectory test ===")
	for bend in [0.0, 0.25, 0.5, 0.75, 1.0]:
		var flex := _flex_for_uniform_bend(main, bend)
		main.call("_apply_finger_poses", flex)
		for bi in sk.get_bone_count():
			sk.force_update_bone_child_transform(bi)
		_print_bend_report(sk, bend)
	quit()


func _flex_for_uniform_bend(main: Node, bend: float) -> Array[float]:
	var out: Array[float] = []
	out.resize(5)
	for i in 5:
		var span: float = main.call("_flex_span", i)
		var ratio: float = main.call("_flex_bend_range_ratio", i)
		out[i] = -bend * span * ratio
	return out


func _tip_global(sk: Skeleton3D, prefix: String) -> Vector3:
	var idx := sk.find_bone("%s%s" % [prefix, TIP_SUFFIX])
	if idx < 0:
		idx = sk.find_bone("%s3" % prefix)
	if idx < 0:
		return Vector3.ZERO
	return sk.get_bone_global_pose(idx).origin


func _print_bend_report(sk: Skeleton3D, bend: float) -> void:
	var prefixes: Array[String] = [
		"RightHandThumb", "RightHandIndex", "RightHandMiddle", "RightHandRing", "RightHandPinky",
	]
	var tips: Array[Vector3] = []
	for p in prefixes:
		tips.append(_tip_global(sk, p))

	var mid := tips[2]
	print("\n-- bend=%.2f --" % bend)
	for i in 5:
		print("  %s tip: %s  dist_to_middle=%.4f" % [FINGER_NAMES[i], tips[i], tips[i].distance_to(mid)])

	var four := [tips[1], tips[3], tips[4]]
	var min_sep := INF
	for a in four.size():
		for b in range(a + 1, four.size()):
			min_sep = minf(min_sep, four[a].distance_to(four[b]))
	print("  four-finger min tip separation: %.4f" % min_sep)
