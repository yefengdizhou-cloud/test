extends SceneTree

func _init() -> void:
	var main: Node = load("res://test.tscn").instantiate()
	root.add_child(main)
	await process_frame
	await process_frame

	main.set("is_calibrated", true)
	main.set("flex_rest", [988.0, 907.0, 925.0, 829.0, 961.0])
	var sk: Skeleton3D = main.find_child("Skeleton3D", true, false) as Skeleton3D
	var labels := ["thumb", "index", "middle", "ring", "pinky"]

	var bend := 0.5
	var flex: Array[float] = []
	flex.resize(5)
	for fi in 5:
		flex[fi] = -bend * main.call("_flex_span", fi) * main.call("_flex_bend_range_ratio", fi)

	print("=== per-finger bend debug (bend=%.1f) ===" % bend)
	print("flex_rest=", main.get("flex_rest"))
	print("flex_closed=", main.get("flex_closed_finger"))
	for fi in 5:
		print(
			"  %s span=%.1f ratio=%.2f"
			% [labels[fi], main.call("_flex_span", fi), main.call("_flex_bend_range_ratio", fi)]
		)
	for fi in 5:
		var b: float = main.call("_flex_to_bend", flex[fi], fi, true)
		var spread: float = main.call("_finger_spread_phase", b)
		var curl: float = main.call("_finger_curl_phase", b)
		var flexion: float = main.call("_finger_flexion_rad", fi, curl)
		if fi > 0:
			flexion = -flexion
		var abduct: float = main.call("_finger_abduction_rad", fi, spread, curl)
		print(
			"%s flex=%.1f bend=%.3f curl=%.3f flexion=%.4f abduct=%.4f"
			% [labels[fi], flex[fi], b, curl, flexion, abduct]
		)

	main.call("_apply_finger_poses", flex)
	for bi in sk.get_bone_count():
		sk.force_update_bone_child_transform(bi)

	var chains: Array = main.get("_finger_chain_indices")
	for fi in 5:
		var chain: Array = chains[fi]
		if chain.is_empty():
			continue
		var tip_idx: int = chain[chain.size() - 1]
		var tip_name := sk.get_bone_name(tip_idx)
		var pose_rot := sk.get_bone_pose_rotation(tip_idx)
		var tip_pos := sk.get_bone_global_pose(tip_idx).origin
		print(
			"%s tip=%s pose_euler=%s pos=%s"
			% [
				labels[fi],
				tip_name,
				pose_rot.get_euler(),
				tip_pos,
			]
		)
	quit()
