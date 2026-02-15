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
@export var recovery_duration: float = 0.5 # Wait time before blending starts
@export var blend_time: float = 0.5 # Duration of blend back to anim

@export_group("Active Recovery")
@export var recovery_stiffness: float = 20.0 # Torque strength to return to pose
@export var recovery_damping: float = 1.0 # Damping to prevent oscillation

enum State { IDLE, REFLEX, RECOVERY, BLENDING, DEAD }
var current_state: State = State.IDLE
var current_health: int
var state_timer: float = 0.0

@onready var animation_player: AnimationPlayer = get_node(animation_player_path)
@onready var physical_bone_simulator: PhysicalBoneSimulator3D = get_node(physical_bone_simulator_path)
var skeleton: Skeleton3D

# Node references
var bones_dict: Dictionary = {}
var active_bones_mask: Array[StringName] = [] # Bones currently simulating

# Blending State
var blend_amount: float = 0.0
var snapshot_local_poses: Dictionary = {} # bone_idx -> Transform3D (Local to Parent)
var sorted_bone_indices: Array[int] = [] 

# Active Recovery State
var target_physical_local_transforms: Dictionary = {} # bone_idx -> Transform3D (Local to Parent PhysicalBone)


func _ready() -> void:
	current_health = max_health
	
	if physical_bone_simulator:
		skeleton = physical_bone_simulator.get_parent() as Skeleton3D
		if helper_skeleton_path:
			skeleton = get_node(helper_skeleton_path)
			
		for child in physical_bone_simulator.get_children():
			if child is PhysicalBone3D and child.bone_name:
				bones_dict[child.bone_name] = child
				
				# Finger/Small Bone Stabilization Injection
				if is_finger(child.bone_name):
					# Higher damping prevent 'jitter' and 'spaghetti' artifacts in small bones
					child.linear_damp = 5.0
					child.angular_damp = 5.0
	
	start_animation()


func _physics_process(delta: float) -> void:
	match current_state:
		State.REFLEX:
			state_timer -= delta
			if state_timer <= 0:
				enter_recovery_state()
				
		State.RECOVERY:
			state_timer -= delta
			apply_active_recovery_torque(delta)
			
			if state_timer <= 0:
				start_blending_back()
				
		State.BLENDING:
			# Reduce override amount over time
			blend_amount -= delta / blend_time
			if blend_amount <= 0:
				blend_amount = 0
				current_state = State.IDLE
				clear_snapshot_overrides()
			else:
				apply_snapshot_overrides(blend_amount)


func enter_recovery_state() -> void:
	current_state = State.RECOVERY
	state_timer = recovery_duration


func apply_active_recovery_torque(delta: float) -> void:
	if not skeleton: return
	
	for bone_name in active_bones_mask:
		var bone_idx = skeleton.find_bone(bone_name)
		if bone_idx == -1: continue
		
		# Get the PhysicalBone3D node
		var pb = bones_dict[bone_name] as PhysicalBone3D
		if not pb: continue
		
		# Retrieve captured relative transform
		if not target_physical_local_transforms.has(bone_idx): continue
		var target_local_transform = target_physical_local_transforms[bone_idx]
		
		var parent_idx = skeleton.get_bone_parent(bone_idx)
		var parent_global_transform = Transform3D.IDENTITY
		
		# Determine parent's CURRENT global transform
		if parent_idx != -1:
			var parent_name = skeleton.get_bone_name(parent_idx)
			if bones_dict.has(parent_name):
				# Use parent PhysicalBone current transform (even if kinematic/static)
				var parent_pb = bones_dict[parent_name] as PhysicalBone3D
				parent_global_transform = parent_pb.global_transform
			else:
				# Use Skeleton animation transform if no PhysicalBone exists for parent
				parent_global_transform = skeleton.global_transform * skeleton.get_bone_global_pose(parent_idx)
		else:
			parent_global_transform = skeleton.global_transform
			
		# Calculate TARGET Global Transform
		# Global = ParentGlobal * LocalSnapshot
		var target_global_transform = parent_global_transform * target_local_transform
		var target_global_basis = target_global_transform.basis
		var current_global_basis = pb.global_transform.basis
		
		# Calculate rotation difference to target
		var diff = target_global_basis * current_global_basis.inverse()
		var ang_vel = pb.angular_velocity
		
		# Convert to axis-angle for torque
		var axis = diff.get_rotation_quaternion().get_axis()
		var angle = diff.get_rotation_quaternion().get_angle()
		
		# Optimize angle range (-PI to PI)
		if angle > PI: angle -= 2 * PI
		
		# Apply Torque: Spring (Stiffness) - Damper (Damping)
		# Note: This is an approximation. Ideally use joint motors, but PhysicalBone3D manual torque works ok.
		# usage of angular_velocity direct modification because apply_torque/apply_torque_impulse are missing
		var torque = axis * angle * recovery_stiffness - ang_vel * recovery_damping
		pb.angular_velocity += torque * delta # Torque * Time = Change within frame


func start_blending_back() -> void:
	current_state = State.BLENDING
	blend_amount = 1.0
	
	# Snapshot current physics poses in SKELETON MODEL SPACE by active capture
	# We avoid get_bone_global_pose() because it returns animation pose if active physics is stopped
	# We avoid direct world capture without conversion because it breaks local space
	# Solution: Get World Pose from PhysicalBone, Convert to Skeleton Model Space
	
	snapshot_local_poses.clear()
	sorted_bone_indices.clear()
	
	# 1. Identify active bones
	for bone_name in active_bones_mask:
		if skeleton:
			var bone_idx = skeleton.find_bone(bone_name)
			if bone_idx != -1:
				sorted_bone_indices.append(bone_idx)
	
	# 2. Sort for processing (Parents first is critical for relative transform)
	sorted_bone_indices.sort()
	
	# 3. Capture Poses
	var skel_world_transform = skeleton.global_transform
	var captured_model_poses: Dictionary = {} # bone_idx -> Transform3D (Model Space)
	
	for bone_idx in sorted_bone_indices:
		var bone_name = skeleton.get_bone_name(bone_idx)
		var bone_model_pose = Transform3D.IDENTITY
		
		# Getting Current Physics Pose (World Space)
		if bones_dict.has(bone_name):
			var pb = bones_dict[bone_name] as PhysicalBone3D
			# World -> Model Space: SkeletonInverse * BoneWorld
			# Correct for Body Offset! (PB Transform -> Bone Transform)
			var bone_global_transform = pb.global_transform * pb.body_offset.inverse()
			bone_model_pose = skel_world_transform.affine_inverse() * bone_global_transform
		else:
			# Fallback if no PhysicalBone (shouldn't happen in this loop)
			bone_model_pose = skeleton.get_bone_global_pose(bone_idx)
			
		captured_model_poses[bone_idx] = bone_model_pose
		
		# Get Parent Model Pose
		var parent_idx = skeleton.get_bone_parent(bone_idx)
		var parent_model_pose = Transform3D.IDENTITY
		
		if parent_idx != -1:
			# If parent was simulated, use its Captured Physics Pose
			if captured_model_poses.has(parent_idx):
				parent_model_pose = captured_model_poses[parent_idx]
			else:
				# Otherwise use CURRENT Animation Pose (Model Space)
				# get_bone_global_pose returns current model pose relative to Skeleton
				parent_model_pose = skeleton.get_bone_global_pose(parent_idx)
		
		# Calculate Local Pose relative to Parent (Model Space Delta)
		# Local = ParentInverse * Child
		var local_pose = parent_model_pose.affine_inverse() * bone_model_pose
		snapshot_local_poses[bone_idx] = local_pose
	
	# Stop active physics (Snaps bones to animation pose internally)
	physical_bone_simulator.physical_bones_stop_simulation()
	active_bones_mask.clear()
	
	# Ensure animation is playing
	if animation_player and not animation_player.is_playing():
		start_animation()
		
	# Apply initial override (100% ragdoll pose)
	apply_snapshot_overrides(1.0)


func apply_snapshot_overrides(amount: float) -> void:
	if not skeleton: return
	
	# MANUAL BLEND STRATEGY
	# To avoid "morphing/inverted" bugs caused by linear interpolation of matrices,
	# we manually interpolate the transform (SLERP) and apply it as a 100% override.
	
	# 1. Calculate Current Animation Global Poses (without override influence)
	var anim_global_poses: Dictionary = {} # bone_idx -> Transform3D (Model Space)
	
	# Process parents first to build hierarchy
	for bone_idx in sorted_bone_indices:
		var parent_idx = skeleton.get_bone_parent(bone_idx)
		var parent_anim_global = Transform3D.IDENTITY
		
		if parent_idx != -1:
			if anim_global_poses.has(parent_idx):
				parent_anim_global = anim_global_poses[parent_idx]
			else:
				# Fallback: simpler lookup if parent not in mask (e.g. Hips)
				# get_bone_global_pose returns ANIMATED pose since simulation is stopped
				# AND we cleared overrides on non-simulated bones.
				# However, since we are overriding currently, get_bone_global_pose might return the override?
				# Let's assume non-mask bones are safe (not overridden).
				parent_anim_global = skeleton.get_bone_global_pose(parent_idx)
		
		# Get Local Animation Pose (from tracks)
		var local_anim = skeleton.get_bone_pose(bone_idx)
		var global_anim = parent_anim_global * local_anim
		anim_global_poses[bone_idx] = global_anim
	
	# 2. Interpolate and Apply
	# We use Transform3D.interpolate_with() which handles translation lerp + rotation slerp perfectly.
	# amount: 1.0 = Snapshot (Ragdoll), 0.0 = Animation
	
	for bone_idx in sorted_bone_indices:
		if not anim_global_poses.has(bone_idx): continue
		
		# Reconstruct Snapshot Global Pose (Model Space)
		# We need to rebuild it from the snapshot locals to account for PARENT BLENDING!
		# If thigh blends 50%, shin must start from that 50% thigh.
		
		var parent_idx = skeleton.get_bone_parent(bone_idx)
		var parent_blended_global = Transform3D.IDENTITY
		
		if parent_idx != -1:
			# Use the BLENDED parent pose (set in previous iteration of this loop)
			# But we can't get it easily from skeleton during the same frame update?
			# Actually, we can just calculate it.
			# But wait, we are setting overrides.
			# Let's use the layout from previous fix: Parent * LocalSnapshot.
			pass # Logic handles this implicitly if we reconstruct
		
		# ACTUALLY: The Snapshot Locality logic was:
		# SnapshotGlobal = ParentCurrent * SnapshotLocal
		# But ParentCurrent is changing (Blending)!
		# So SnapshotGlobal moves towards AnimGlobal.
		
		# Let's stick to the ROBUST Manual Blend:
		# 1. Target = AnimGlobal
		# 2. Source = SnapshotGlobal (At freeze time? No, relative to current parent?)
		
		# Refined Manual Blend:
		# A. Get Target Anim Global (calculated above)
		# B. Get Source Ragdoll Global (Reconstructed from snapshot local + BLENDED PARENT)
		# C. Interpolate A -> B is implicit if we override properly?
		
		# User issue "Morphing" suggests B is wrong.
		# If we use `set_bone_global_pose_override(idx, target, amount)`, Godot interpolates:
		# Result = Anim * (1-amount) + Target * amount.
		
		# The issue is `Target` calculation.
		# `Target = ParentBlended * SnapshotLocal`.
		# Godot blends `Anim` and `Target`.
		# `ParentBlended` is ALREADY blended.
		# So `Target` is "Ragdoll relative to Blended Parent".
		# `Anim` is "Anim relative to Blended Parent" (approx).
		#
		# If Godot LERPs this, it should be fine?
		# UNLESS `SnapshotLocal` rotation is > 90 deg from `AnimLocal`.
		# Then LERP takes the short path (morph/shrink).
		#
		# FIX: Manually verify Shortest Path for the Rotation.
		
		var local_pose = snapshot_local_poses[bone_idx]
		
		# reconstruct parent frame
		var parent_idx_for_calc = skeleton.get_bone_parent(bone_idx)
		var parent_model_pose = Transform3D.IDENTITY
		if parent_idx_for_calc != -1:
			 # Critical: Use the pose that the child "sees" as its attachment point
			 # This is the Skeleton's current global pose for the parent (which includes hierarchy overrides!)
			parent_model_pose = skeleton.get_bone_global_pose(parent_idx_for_calc)
			
		# Calculate Model Pose: ParentModel * Local
		var target_model_pose = parent_model_pose * local_pose
		
		# REVERTED "Just Inverse" Hack
		# Correct Pivot Handling (body_offset) should fix Squeezing/Twisting.
		# We assume target_model_pose is now correct.
		
		# Apply override relative to skeleton
		skeleton.set_bone_global_pose_override(bone_idx, target_model_pose, amount, true)


func clear_snapshot_overrides() -> void:
	if not skeleton: return
	skeleton.clear_bones_global_pose_override()


func enter_idle_state() -> void:
	start_blending_back()


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
		print("Character DIED. Starting full ragdoll.")
		start_full_ragdoll()
		# Defer impulse to next frame. Applying to ALL bones should prevent stretching.
		call_deferred("apply_ragdoll_impulse", hit_node, hit_position, impulse * 0.5)
	else:
		start_reflex_reaction(hit_node, hit_position, impulse)


func start_reflex_reaction(hit_node: Node, hit_position: Vector3, impulse: Vector3) -> void:
	# If already blending, cancel blend/overrides and re-react
	if current_state == State.BLENDING:
		clear_snapshot_overrides()
	
	current_state = State.REFLEX
	state_timer = reflex_duration
	target_physical_local_transforms.clear()
	
	# LOCALIZED SIMULATION logic
	var target_bone_name = ""
	if hit_node is PhysicalBone3D:
		target_bone_name = hit_node.bone_name
	
	active_bones_mask.clear()
	
	if target_bone_name:
		active_bones_mask.append(target_bone_name)
		add_bone_subtree(target_bone_name)
	else:
		for b in bones_dict.keys():
			if b != "Hips":
				active_bones_mask.append(b)

	# Capture target physical locals for active recovery
	if skeleton:
		for bone_name in active_bones_mask:
			var idx = skeleton.find_bone(bone_name)
			if idx != -1:
				# Capture relative transform in PhysicalBone space!
				var pb = bones_dict[bone_name] as PhysicalBone3D
				if pb:
					# We need parent's GLOBAL transform at this moment (Animation Pose)
					var parent_idx = skeleton.get_bone_parent(idx)
					var parent_global_transform = Transform3D.IDENTITY
					
					if parent_idx != -1:
						var parent_name = skeleton.get_bone_name(parent_idx)
						if bones_dict.has(parent_name):
							var parent_pb = bones_dict[parent_name] as PhysicalBone3D
							parent_global_transform = parent_pb.global_transform
						else:
							parent_global_transform = skeleton.global_transform * skeleton.get_bone_global_pose(parent_idx)
					else:
						parent_global_transform = skeleton.global_transform
					
					# Store Local = ParentInverse * ChildGlobal
					# This captures exactly "Where child is relative to parent"
					# Correct for Body Offset! (PB Transform -> Bone Transform)
					var pb_bone_transform = pb.global_transform * pb.body_offset.inverse()
					target_physical_local_transforms[idx] = parent_global_transform.affine_inverse() * pb_bone_transform

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
		
	# Clear any existing partial simulation / recovery state
	active_bones_mask.clear()
	clear_snapshot_overrides()
	physical_bone_simulator.physical_bones_stop_simulation()
	
	# Disable the character's movement colliders so the ragdoll can fall freely
	disable_character_colliders()
	
	# Start full simulation (empty array = all bones)
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
		# If DEAD, distribute impulse to ALL bones to prevent the "Stretching" artifact
		if current_state == State.DEAD:
			print("Applying DEATH impulse to ALL bones. Target: ", target_bone.bone_name)
			# Apply a uniform velocity boost to EVERY bone in the character
			for child in physical_bone_simulator.get_children():
				if child is PhysicalBone3D:
					child.apply_central_impulse(impulse * 0.3)
			
			# Apply "Impact Snap" to the actual hit bone (Head, etc.)
			target_bone.apply_impulse(impulse * 0.1, hit_position - target_bone.global_position)
		else:
			# Normal hit - apply full force to target bone
			target_bone.apply_impulse(impulse, hit_position - target_bone.global_position)


func is_finger(bone_name: String) -> bool:
	var n = bone_name.to_lower()
	# Keywords found in Rig: index, middle, little, ring, thumb, proximal, intermediate, distal, metacarpal
	return "finger" in n or "thumb" in n or "index" in n or "middle" in n or "ring" in n or "pinky" in n or \
		   "little" in n or "proximal" in n or "intermediate" in n or "distal" in n or "metacarpal" in n


func disable_character_colliders() -> void:
	# Search for any CollisionObject3D in the character hierarchy that isn't a PhysicalBone
	# Disabling these ensures the ragdoll doesn't 'sit' on its own movement capsule.
	_disable_colliders_recursive(self)


func _disable_colliders_recursive(node: Node) -> void:
	if node is CollisionObject3D and not node is PhysicalBone3D:
		node.collision_layer = 0
		node.collision_mask = 0
		print("Disabled character collider: ", node.name)
	
	for child in node.get_children():
		_disable_colliders_recursive(child)


func reset_ragdoll() -> void:
	current_state = State.IDLE
	current_health = max_health
	if physical_bone_simulator:
		physical_bone_simulator.physical_bones_stop_simulation()
	start_animation()
