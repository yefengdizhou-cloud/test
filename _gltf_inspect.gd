extends SceneTree

const DEFORM_CHAINS: Array[Array] = [
	["thumb_01.R", "thumb_02.R", "thumb_03.R"],
	["index_01.R", "index_02.R", "index_03.R"],
	["middle_01.R", "middle_02.R", "middle_03.R"],
	["ring_01.R", "ring_02.R", "ring_03.R"],
	["pinky_01.R", "pinky_02.R", "pinky_03.R"],
]


func _init() -> void:
	var scene: Node = load("res://assets/scene.gltf").instantiate()
	root.add_child(scene)
	await process_frame

	var sk: Skeleton3D = scene.find_child("Skeleton3D", true, false) as Skeleton3D
	if sk == null:
		push_error("No Skeleton3D")
		quit(1)
		return

	print("=== scene.gltf Godot skeleton ===")
	print("bone_count=", sk.get_bone_count())
	for i in sk.get_bone_count():
		print("%3d %s parent=%s" % [i, sk.get_bone_name(i), sk.get_bone_name(sk.get_bone_parent(i))])

	print("\n=== Wrist candidates ===")
	for name in ["hand.R", "hand.R_02", "hand.R.001", "pulse.R", "pulse.R_01", "_rootJoint"]:
		var idx := sk.find_bone(name)
		if idx >= 0:
			print(name, idx, sk.get_bone_global_rest(idx).origin)

	print("\n=== Deform chain resolve ===")
	for fi in 5:
		var chain: Array[int] = []
		for prefix in DEFORM_CHAINS[fi]:
			var idx := _find_by_prefix(sk, prefix)
			if idx >= 0:
				chain.append(idx)
				var rest := sk.get_bone_rest(idx)
				var child_len := 0.0
				for c in sk.get_bone_count():
					if sk.get_bone_parent(c) == idx:
						child_len = (sk.get_bone_rest(c).origin - rest.origin).length()
						break
				print("  %s -> %s len=%.4f" % [["thumb","index","middle","ring","pinky"][fi], sk.get_bone_name(idx), child_len])
		print("  chain size=", chain.size())

	var meshes := scene.find_children("*", "MeshInstance3D", true, false)
	print("\nmeshes=", meshes.size())
	for m in meshes:
		var mi := m as MeshInstance3D
		print(" ", mi.name, " skin=", mi.skin != null, " verts=", mi.mesh.get_surface_count() if mi.mesh else 0)
	quit()


func _find_by_prefix(sk: Skeleton3D, prefix: String) -> int:
	for i in sk.get_bone_count():
		var n := sk.get_bone_name(i)
		if n.begins_with(prefix):
			return i
	return -1
