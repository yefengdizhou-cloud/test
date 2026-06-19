extends SceneTree

func _init() -> void:
	var scene: Node = load("res://assets/FpsArmsHigh.fbx").instantiate()
	var sk: Skeleton3D = scene.find_child("Skeleton3D", true, false) as Skeleton3D
	var hand := sk.find_bone("RightHand")
	var mid := sk.find_bone("RightHandMiddle1")
	var hand_p := sk.get_bone_global_rest(hand).origin
	var finger := (sk.get_bone_global_rest(mid).origin - hand_p).normalized()
	var q1 := Quaternion(finger, Vector3(0, 0, -1))
	print("from_to finger ", q1 * finger)
	var q2 := Quaternion(Vector3(1, 0, 0), Vector3(0, 0, -1))
	print("x to -z ", q2 * Vector3(1, 0, 0))
	quit()
