extends SceneTree

func _init() -> void:
	var scene: Node = load("res://assets/scene.gltf").instantiate()
	root.add_child(scene)
	await process_frame
	var sk: Skeleton3D = scene.find_child("Skeleton3D", true, false) as Skeleton3D

	var chains: Array[Array] = [
		["thumb_base.R", "thumb_01.R", "thumb_02.R", "thumb_03.R"],
		["index_base.R", "index_01.R", "index_02.R", "index_03.R"],
		["middle_base.R", "middle_01.R", "middle_02.R", "middle_03.R"],
		["ring_base.R", "ring_01.R", "ring_02.R", "ring_03.R"],
		["pinky_base.R", "pinky_01.R", "pinky_02.R", "pinky_03.R"],
	]
	print("=== Full deform chains (base+01+02+03) ===")
	for c in chains:
		var total := 0.0
		var parts: Array[String] = []
		for prefix in c:
			var idx := _find(sk, prefix)
			if idx < 0:
				parts.append("%s:?" % prefix)
				continue
			var l := _child_len(sk, idx)
			total += l
			parts.append("%s:%.3f" % [sk.get_bone_name(idx), l])
		print(" ".join(parts), " total=", total)

	var wrist := sk.find_bone("hand.R_02")
	var hand001 := sk.find_bone("hand.R.001_011")
	print("\nhand.R_02=", wrist, sk.get_bone_global_rest(wrist).origin if wrist>=0 else null)
	print("hand.R.001=", hand001)

	# finger dirs from wrist
	for prefix in ["index_03.R", "middle_03.R", "thumb_03.R"]:
		var idx := _find(sk, prefix)
		if idx >= 0:
			print(prefix, "tip=", sk.get_bone_global_rest(idx).origin)
	quit()


func _find(sk: Skeleton3D, prefix: String) -> int:
	for i in sk.get_bone_count():
		if sk.get_bone_name(i).begins_with(prefix):
			return i
	return -1


func _child_len(sk: Skeleton3D, idx: int) -> float:
	var rest := sk.get_bone_rest(idx)
	for c in sk.get_bone_count():
		if sk.get_bone_parent(c) == idx:
			return (sk.get_bone_rest(c).origin - rest.origin).length()
	return 0.0
