extends Node3D

## Manages transition from animated character to ragdoll physics

@export var animation_player_path: NodePath
@export var physical_bone_simulator_path: NodePath
@export var animation_name: String = "AnimationLibrary_Godot_Standard/Idle"
@export var max_health: int = 5 # Tougher enemy

var current_health: int
var is_ragdoll_active := false
var recovery_timer: Timer

# Bones to simulate on hit (keeping legs animated)
var upper_body_bones: Array[StringName] = [
	"Spine", "Chest", "UpperChest", "Neck", "Head",
	"LeftShoulder", "LeftUpperArm", "LeftLowerArm", "LeftHand",
	"RightShoulder", "RightUpperArm", "RightLowerArm", "RightHand"
]

@onready var animation_player: AnimationPlayer = get_node(animation_player_path)
@onready var physical_bone_simulator: PhysicalBoneSimulator3D = get_node(physical_bone_simulator_path)


func _ready() -> void:
	current_health = max_health
	
	# Create timer for recovery from hit reaction
	recovery_timer = Timer.new()
	add_child(recovery_timer)
	recovery_timer.one_shot = true
	recovery_timer.timeout.connect(_on_recovery_timeout)
	
	start_animation()


func start_animation() -> void:
	if animation_player and animation_player.has_animation(animation_name):
		animation_player.play(animation_name)
	elif animation_player:
		var anims = animation_player.get_animation_list()
		if anims.size() > 0:
			animation_player.play(anims[0])


func activate_ragdoll(hit_node: Node, hit_position: Vector3, impulse: Vector3) -> void:
	# If dead/full ragdoll, just apply force
	if is_ragdoll_active and current_health <= 0:
		apply_ragdoll_impulse(hit_node, hit_position, impulse)
		return

	# Take damage
	current_health -= 1
	print("Hit! Health remaining: ", current_health)
	
	if current_health <= 0:
		# DEATH: Full Ragdoll
		start_full_ragdoll()
		apply_ragdoll_impulse(hit_node, hit_position, impulse * 2.0) # Extra force on death
	else:
		# HIT REACTION: Partial Ragdoll (Upper Body)
		react_to_hit(hit_node, hit_position, impulse)


func react_to_hit(hit_node: Node, hit_position: Vector3, impulse: Vector3) -> void:
	# 1. Keep animation playing (legs will hold pose)
	# 2. Start simulation only for upper body
	physical_bone_simulator.physical_bones_start_simulation(upper_body_bones)
	
	# Apply force
	apply_ragdoll_impulse(hit_node, hit_position, impulse)
	
	# Recover after 0.3 seconds (snap back to animation)
	recovery_timer.start(0.3)


func _on_recovery_timeout() -> void:
	if current_health > 0:
		# Stop simulation to snap back to animation pose
		physical_bone_simulator.physical_bones_stop_simulation()
		
		# Ensure animation is still playing correctly
		if animation_player and not animation_player.is_playing():
			start_animation()


func start_full_ragdoll() -> void:
	is_ragdoll_active = true
	
	# Stop animation completely
	if animation_player:
		animation_player.stop()
	
	# Start FULL physics simulation (empty array = all bones)
	physical_bone_simulator.physical_bones_start_simulation([])


func apply_ragdoll_impulse(hit_node: Node, hit_position: Vector3, impulse: Vector3) -> void:
	# Apply impulse to the bone
	var target_bone: PhysicalBone3D = null
	
	# First check if we hit a bone directly
	if hit_node is PhysicalBone3D:
		target_bone = hit_node
	else:
		# Fallback to closest bone
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
		target_bone.apply_impulse(impulse, hit_position - target_bone.global_position)


func reset_ragdoll() -> void:
	"""Call this to reset the character back to animated state"""
	is_ragdoll_active = false
	current_health = max_health
	recovery_timer.stop()
	
	# Stop physics simulation
	if physical_bone_simulator:
		physical_bone_simulator.physical_bones_stop_simulation()
	
	start_animation()
