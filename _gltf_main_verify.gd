extends SceneTree

func _init() -> void:
	var main: Node = load("res://test.tscn").instantiate()
	root.add_child(main)
	await process_frame
	await process_frame

	main.set("is_calibrated", true)
	main.set("flex_rest", [988.0, 907.0, 925.0, 829.0, 961.0])
	var sk: Skeleton3D = main.find_child("Skeleton3D", true, false) as Skeleton3D

	print("=== scene.gltf via Main.gd ===")
	print("bones_ready=", main.get("_bones_ready"))
	print("wrist=", main.get("_wrist_bone_idx"))
	print("finger mcp indices=", main.get("_finger_bone_indices"))
	print("chains=", main.get("_finger_chain_indices"))
	print("weight sets=", main.get("_finger_chain_weight_sets"))

	for bend in [0.0, 0.5, 1.0]:
		var flex: Array[float] = []
		flex.resize(5)
		for fi in 5:
			flex[fi] = -bend * main.call("_flex_span", fi) * main.call("_flex_bend_range_ratio", fi)
		main.call("_apply_finger_poses", flex)
		for bi in sk.get_bone_count():
			sk.force_update_bone_child_transform(bi)
		var tips: Array[String] = []
		for prefix in ["thumb_03.R", "index_03.R", "middle_03.R", "ring_03.R", "pinky_03.R"]:
			for i in sk.get_bone_count():
				if sk.get_bone_name(i).begins_with(prefix):
					tips.append("%s=%s" % [prefix, sk.get_bone_global_pose(i).origin])
					break
		print("bend=%.1f %s" % [bend, " | ".join(tips)])
	quit()
