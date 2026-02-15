extends Node3D

## Manages transition from animated character to ragdoll physics

@export var animation_player_path: NodePath
@export var physical_bone_simulator_path: NodePath
@export var helper_skeleton_path: NodePath # Optional: Path to the Skeleton3D if not parent of simulator
@export var animation_name: String = "AnimationLibrary_Godot_Standard/Idle"
@export var max_health: int = 5

# TUNING EXPORTS
@export_group("Reaction Tuning")
@export var hit_reaction_force_mult: float = 0.5 
@export var reflex_duration: float = 0.2
@export var recovery_duration: float = 1.0 # Longer for smooth blend
@export var blend_time: float = 0.5 # Duration of blend back to anim

enum State { IDLE, REFLEX, RECOVERY, DEAD }
var current_state: State = State.IDLE
var current_health: int
var state_timer: float = 0.0

@onready var animation_player: AnimationPlayer = get_node(animation_player_path)
@onready var physical_bone_simulator: PhysicalBoneSimulator3D = get_node(physical_bone_simulator_path)
var skeleton: Skeleton3D

# Node references
var bones_dict: Dictionary = {}
var active_bones_mask: Array[StringName] = [] # Bones currently simulating

func _ready() -> void:
	current_health = max_health
	
	if physical_bone_simulator:
		skeleton = physical_bone_simulator.get_parent() as Skeleton3D
		if helper_skeleton_path:
			skeleton = get_node(helper_skeleton_path)
			
		for child in physical_bone_simulator.get_children():
			if child is PhysicalBone3D and child.bone_name:
				bones_dict[child.bone_name] = child
	
	start_animation()


func _physics_process(delta: float) -> void:
	match current_state:
		State.REFLEX:
			state_timer -= delta
			if state_timer <= 0:
				enter_recovery_state()
				
		State.RECOVERY:
			state_timer -= delta
			
			# In recovery, we want to gently guide bones back.
			# Godot's PhysicalBoneSimulator doesn't support easy blending.
			# We'll simulate a blend by just letting physics settle and then snapping?
			# Or better: Stop simulation for bones one by one?
			# For now, let's just wait longer.
			
			if state_timer <= 0:
				enter_idle_state()


func enter_recovery_state() -> void:
	current_state = State.RECOVERY
	state_timer = recovery_duration
	
	# To make it "roll back", we could re-enable animation on some bones?
	# But PhysicalBoneSimulator is all or nothing per bone.
	# We'll rely on the "Upright" torque we had, or just let it settle.


func enter_idle_state() -> void:
	current_state = State.IDLE
	physical_bone_simulator.physical_bones_stop_simulation()
	active_bones_mask.clear()
	
	if animation_player and not animation_player.is_playing():
		start_animation()


func start_animation() -> void:
	if animation_player:
		if animation_player.has_animation(animation_name):
			animation_player.play(animation_name)
		else:
			var anims = animation_player.get_animation_list()
			if anims.size() > 0:
				animation_player.play(anims[0])


func activate_ragdoll(hit_node: Node, hit_position: Vector3, impulse: Vector3) -> void:
	if current_state == State.DEAD:
		apply_ragdoll_impulse(hit_node, hit_position, impulse)
		return

	# Take damage
	current_health -= 1
	print("Hit! Health remaining: ", current_health)
	
	if current_health <= 0:
		start_full_ragdoll()
		apply_ragdoll_impulse(hit_node, hit_position, impulse * 2.0)
	else:
		start_reflex_reaction(hit_node, hit_position, impulse)


func start_reflex_reaction(hit_node: Node, hit_position: Vector3, impulse: Vector3) -> void:
	current_state = State.REFLEX
	state_timer = reflex_duration
	
	# LOCALIZED SIMULATION
	# Identify the bone chain to simulate.
	# If we hit "LeftLowerLeg", we want to simulate "LeftLowerLeg", "LeftFoot" etc.
	# But NOT "Spine" or "Head".
	
	var target_bone_name = ""
	if hit_node is PhysicalBone3D:
		target_bone_name = hit_node.bone_name
	
	active_bones_mask.clear()
	
	if target_bone_name:
		# Add specific hit bone
		active_bones_mask.append(target_bone_name)
		
		# Simplistic: Add commonly associated bones or children?
		# For now, just simulate the hit bone and maybe its parent/child?
		# Actually, simulating Just the hit bone might detach it visually if parent is animated.
		# Godot handles this by blending? No.
		
		# Strategy: Simulate the SUBTREE starting from the hit bone?
		add_bone_subtree(target_bone_name)
		
	else:
		# Fallback: Simulate everything except hips
		for b in bones_dict.keys():
			if b != "Hips":
				active_bones_mask.append(b)

	physical_bone_simulator.physical_bones_start_simulation(active_bones_mask)
	apply_ragdoll_impulse(hit_node, hit_position, impulse * hit_reaction_force_mult)


func add_bone_subtree(bone_name: String) -> void:
	# Add this bone
	if not active_bones_mask.has(bone_name):
		active_bones_mask.append(bone_name)
	
	# Find children in skeleton
	if skeleton:
		var bone_idx = skeleton.find_bone(bone_name)
		if bone_idx != -1:
			var children = skeleton.get_bone_children(bone_idx)
			for child_idx in children:
				var child_name = skeleton.get_bone_name(child_idx)
				# Only add if it has a physical bone
				if bones_dict.has(child_name):
					add_bone_subtree(child_name)


func start_full_ragdoll() -> void:
	current_state = State.DEAD
	if animation_player:
		animation_player.stop()
	physical_bone_simulator.physical_bones_start_simulation([])


func apply_ragdoll_impulse(hit_node: Node, hit_position: Vector3, impulse: Vector3) -> void:
	var target_bone: PhysicalBone3D = null
	
	if hit_node is PhysicalBone3D:
		target_bone = hit_node
	else:
		var closest_distance := INF
		for child in physical_bone_simulator.get_children():
			var bone := child as PhysicalBone3D
			if bone:
				var distance := bone.global_position.distance_to(hit_position)
				if distance < closest_distance:
					closest_distance = distance
					target_bone = bone
	
	if target_bone:
		target_bone.apply_impulse(impulse, hit_position - target_bone.global_position)


func reset_ragdoll() -> void:
	current_state = State.IDLE
	current_health = max_health
	if physical_bone_simulator:
		physical_bone_simulator.physical_bones_stop_simulation()
	start_animation()
