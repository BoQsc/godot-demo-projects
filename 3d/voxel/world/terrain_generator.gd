class_name TerrainGenerator
extends Resource

# Can't be "Chunk.CHUNK_SIZE" due to cyclic dependency issues.
# https://github.com/godotengine/godot/issues/21461
const CHUNK_SIZE = 16

const RANDOM_BLOCK_PROBABILITY = 0.015


static func empty():
	return {}


static func random_blocks():
	var random_data = {}
	for x in range(CHUNK_SIZE):
		for y in range(CHUNK_SIZE):
			for z in range(CHUNK_SIZE):
				var vec = Vector3i(x, y, z)
				if randf() < RANDOM_BLOCK_PROBABILITY:
					random_data[vec] = randi() % 29 + 1
	return random_data


static func flat(chunk_position):
	var data = {}

	if chunk_position.y != -1:
		return data

	for x in range(CHUNK_SIZE):
		for z in range(CHUNK_SIZE):
			data[Vector3i(x, 0, z)] = 3

	return data

static func mountainous(chunk_position):
	var data = {}
	const CHUNK_SIZE = 16
	
	# Only generate terrain in the bottom chunk
	if chunk_position.y != -1:
		return data
	
	# Simple noise parameters for gentle hills
	var frequency = 0.04
	
	# Calculate the world position of this chunk
	var world_x = chunk_position.x * CHUNK_SIZE
	var world_z = chunk_position.z * CHUNK_SIZE
	
	for x in range(CHUNK_SIZE):
		for z in range(CHUNK_SIZE):
			# Calculate world coordinates
			var wx = world_x + x
			var wz = world_z + z
			
			# Generate a simple height using sine waves
			var height_value = sin(wx * frequency) * 0.5 + sin(wz * frequency * 1.3) * 0.5
			
			# Convert to a height between 6-10 blocks
			var height = int(height_value * 2.0 + 8.0)
			
			# Place grass block at calculated height
			data[Vector3i(x, height, z)] = 3  # Grass on top
			
			# Create dirt layer (1-2 blocks)
			for y in range(height-1, height-3, -1):
				if y >= 0:
					data[Vector3i(x, y, z)] = 2  # Dirt underneath grass
			
			# Fill in stone blocks below the dirt
			for y in range(height-3, -1, -1):
				if y >= 0:
					data[Vector3i(x, y, z)] = 1  # Stone underneath
	
	return data
	
# Used to create the project icon.
static func origin_grass(chunk_position):
	if chunk_position == Vector3i.ZERO:
		return {Vector3i.ZERO: 3}

	return {}
