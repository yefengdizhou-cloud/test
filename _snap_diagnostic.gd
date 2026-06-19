extends SceneTree

const NAMES: Array[String] = ["thumb", "index", "middle", "ring", "pinky"]
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
	if sk == null:
		push_error("no skeleton")
		quit(1)
		return

	print("=== Finger onset snap diagnostic (fine steps) ===")
	var start_ratio: float = main.get("finger_curl_ease_power")
	print("finger_curl_ease_power=%.3f" % start_ratio)

	for fi in [1, 3, 4]:
		_scan_finger_onset(main, sk, fi)

	quit()


func _scan_finger_onset(main: Node, sk: Skeleton3D, fi: int) -> void:
	var prev_tip := Vector3.ZERO
	var prev_bend := -1.0
	var max_jump := 0.0
	var max_jump_bend := 0.0
	var max_lateral := 0.0
	var max_lat_bend := 0.0
	var neighbor_fi := fi - 1 if fi == 4 else fi + 1
	if fi == 1:
		neighbor_fi = 2

	for step in 80:
		var bend := float(step) * 0.005
		_apply_single_finger_bend(main, sk, fi, bend)
		var tip := _tip(sk, PREFIXES[fi])
		var ntip := _tip(sk, PREFIXES[neighbor_fi])

		if prev_bend >= 0.0:
			var jump := tip.distance_to(prev_tip)
			var lateral := _lateral_toward_neighbor(tip, prev_tip, ntip)
			if jump > max_jump:
				max_jump = jump
				max_jump_bend = bend
			if absf(lateral) > absf(max_lateral):
				max_lateral = lateral
				max_lat_bend = bend

			if step % 4 == 0 or jump > 0.004:
				var curl_p: float = main.call("_finger_curl_phase", bend)
				var spread_p: float = main.call("_finger_spread_phase", bend)
				print(
					"  %s bend=%.3f spread=%.3f curl=%.3f jump=%.5f lateral=%.5f"
					% [NAMES[fi], bend, spread_p, curl_p, jump, lateral]
				)

		prev_tip = tip
		prev_bend = bend

	print(
		"-> %s max tip jump %.5f at bend=%.3f | max lateral toward %s %.5f at bend=%.3f"
		% [NAMES[fi], max_jump, max_jump_bend, NAMES[neighbor_fi], max_lateral, max_lat_bend]
	)


func _apply_single_finger_bend(main: Node, sk: Skeleton3D, fi: int, bend: float) -> void:
	var flex: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0]
	var span: float = main.call("_flex_span", fi)
	var ratio: float = main.call("_flex_bend_range_ratio", fi)
	flex[fi] = -bend * span * ratio
	main.call("_apply_finger_poses", flex)
	for bi in sk.get_bone_count():
		sk.force_update_bone_child_transform(bi)


func _tip(sk: Skeleton3D, prefix: String) -> Vector3:
	var idx := sk.find_bone("%s4" % prefix)
	if idx < 0:
		idx = sk.find_bone("%s3" % prefix)
	return sk.get_bone_global_pose(idx).origin if idx >= 0 else Vector3.ZERO


func _lateral_toward_neighbor(tip: Vector3, prev_tip: Vector3, neighbor_tip: Vector3) -> float:
	var delta := tip - prev_tip
	if delta.length_squared() < 1e-12:
		return 0.0
	var to_neighbor := (neighbor_tip - prev_tip).normalized()
	return delta.dot(to_neighbor)
