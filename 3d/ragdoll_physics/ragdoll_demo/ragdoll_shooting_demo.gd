extends Node3D

## Point-and-Click shooting mechanics for ragdoll demo

@export var shoot_force := 50.0

@onready var camera: Camera3D = $CameraPivot/Camera3D
@onready var instructions: Label = $UI/Instructions


func _ready() -> void:
	# Keep mouse VISIBLE and FREE
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	update_instructions()


func _process(_delta: float) -> void:
	pass


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			# Shoot from mouse position
			shoot(event.position)
	
	# Release mouse capture if it somehow got captured
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func update_instructions() -> void:
	instructions.text = "Left Click anywhere to shoot!\nMouse is free to move."


func shoot(screen_pos: Vector2) -> void:
	var space_state := get_world_3d().direct_space_state
	
	# Get ray from camera through mouse cursor
	var from := camera.project_ray_origin(screen_pos)
	var to := from + camera.project_ray_normal(screen_pos) * 100.0
	
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = false
	
	var result := space_state.intersect_ray(query)
	
	if result:
		print("Hit: ", result.collider.name, " at ", result.position)
		spawn_debug_sphere(result.position)
		
		# Check if we hit a ragdoll
		var hit_node := result.collider as Node
		
		# Try to find the ragdoll controller (could be parent or ancestor)
		var ragdoll_controller = find_ragdoll_controller(hit_node)
		
		if ragdoll_controller and ragdoll_controller.has_method("activate_ragdoll"):
			var direction := (to - from).normalized()
			# Pass the ACTUAL hit node to the controller
			ragdoll_controller.activate_ragdoll(hit_node, result.position, direction * shoot_force)


func spawn_debug_sphere(pos: Vector3) -> void:
	var mesh_instance := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.05
	sphere.height = 0.1
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.RED
	material.emission_enabled = true
	material.emission = Color.RED
	sphere.material = material
	mesh_instance.mesh = sphere
	add_child(mesh_instance)
	mesh_instance.global_position = pos
	
	# Auto-delete after 2 seconds
	var timer := get_tree().create_timer(2.0)
	timer.timeout.connect(mesh_instance.queue_free)


func find_ragdoll_controller(node: Node) -> Node:
	# Search up the tree for a node with the ragdoll activation script
	var current := node
	while current:
		if current.has_method("activate_ragdoll"):
			return current
		current = current.get_parent()
	return null
