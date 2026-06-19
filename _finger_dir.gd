extends SceneTree

func _init() -> void:
	var scene: Node = load("res://assets/FpsArmsHigh.fbx").instantiate()
	var sk: Skeleton3D = scene.find_child("Skeleton3D", true, false) as Skeleton3D
	var hand := sk.find_bone("RightHand")
	var index1 := sk.find_bone("RightHandIndex1")
	var middle1 := sk.find_bone("RightHandMiddle1")
	var thumb1 := sk.find_bone("RightHandThumb1")

	var hand_g := sk.get_bone_global_rest(hand).origin
	var idx_g := sk.get_bone_global_rest(index1).origin
	var mid_g := sk.get_bone_global_rest(middle1).origin
	var thumb_g := sk.get_bone_global_rest(thumb1).origin

	print("hand ", hand_g)
	print("index dir ", (idx_g - hand_g).normalized())
	print("middle dir ", (mid_g - hand_g).normalized())
	print("thumb dir ", (thumb_g - hand_g).normalized())
	print("hand bind euler ", rad_to_deg(sk.get_bone_global_rest(hand).basis.get_euler().y))
	quit()
