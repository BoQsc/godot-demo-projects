extends Node3D

## Manages transition from animated character to ragdoll physics

@export var animation_player_path: NodePath
@export var physical_bone_simulator_path: NodePath
@export var animation_name: String = "AnimationLibrary_Godot_Standard/Idle"

var is_ragdoll_active := false

@onready var animation_player: AnimationPlayer = get_node(animation_player_path)
@onready var physical_bone_simulator: PhysicalBoneSimulator3D = get_node(physical_bone_simulator_path)


func _ready() -> void:
	# Start with animation playing
	if animation_player and animation_player.has_animation(animation_name):
		animation_player.play(animation_name)
	elif animation_player:
		printerr("Animation not found: ", animation_name) 
		# Fallback to first animation if available
		var anims = animation_player.get_animation_list()
		if anims.size() > 0:
			animation_player.play(anims[0])


func activate_ragdoll(hit_node: Node, hit_position: Vector3, impulse: Vector3) -> void:
	if not is_ragdoll_active:
		is_ragdoll_active = true
		
		# Stop animation
		if animation_player:
			animation_player.stop()
		
		# Start physics simulation
		physical_bone_simulator.physical_bones_start_simulation()
	
	# Apply impulse to the bone
	var target_bone: PhysicalBone3D = null
	
	# First check if we hit a bone directly
	if hit_node is PhysicalBone3D:
		target_bone = hit_node
		print("Direct bone hit: ", target_bone.name)
	else:
		# Fallback to closest bone
		print("Hit non-bone node: ", hit_node.name, ", searching for closest bone...")
		var closest_distance := INF
		
		for child in physical_bone_simulator.get_children():
			var bone := child as PhysicalBone3D
			if bone:
				var distance := bone.global_position.distance_to(hit_position)
				if distance < closest_distance:
					closest_distance = distance
					target_bone = bone
	
	# Apply the impulse
	if target_bone:
		# Apply impulse directly
		target_bone.apply_impulse(impulse, hit_position - target_bone.global_position)
		print("Applied impulse to: ", target_bone.name, " Force: ", impulse.length())
		
		# If the ragdoll seems stuck, try ensuring the simulator is active?
		# No, simulator should handle this. Impulse should wake it.


func reset_ragdoll() -> void:
	"""Call this to reset the character back to animated state"""
	is_ragdoll_active = false
	
	# Stop physics simulation
	physical_bone_simulator.physical_bones_stop_simulation()
	
	# Restart animation
	if animation_player and animation_player.has_animation(animation_name):
		animation_player.play(animation_name)
