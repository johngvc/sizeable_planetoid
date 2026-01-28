extends RigidBody2D
## RigidBody2D Player controller with physics interactions
## Supports pushing objects, rolling circular objects, and grabbing plaster materials

signal fly_mode_changed(active: bool)
signal layer_changed(new_layer: int)
signal grab_state_changed(is_grabbing: bool, grabbed_object: RigidBody2D)

# Movement constants (force-based, tuned for mass=1.5)
# Force = mass * acceleration. With mass=1.5, force of 1500 gives accel of 1000 units/s²
const MOVE_FORCE = 1500.0  # Base horizontal movement force
const FLY_FORCE = 1000.0  # Force in fly mode
const MAX_SPEED = 300.0  # Maximum horizontal speed
const FLY_MAX_SPEED = 350.0  # Maximum speed in fly mode
const JUMP_VELOCITY = 350.0  # Upward velocity for jumping
const AIR_CONTROL_MULTIPLIER = 0.6  # Reduced control in air
const JUMP_GRACE_TIME = 0.15  # Time after jump where we ignore grounded state

# Slope climbing constants (Sackboy-style)
const SLOPE_GRAVITY_SCALE = 0.4  # Reduced gravity when climbing slopes (floaty feel)
const SLOPE_UPWARD_ASSIST = 0.3  # Upward force multiplier when moving on slopes
const NORMAL_GRAVITY_SCALE = 1.0  # Default gravity
const SLOPE_SPEED_MULTIPLIER = 0.8  # Slope climbing speed is 80% of ground speed
const MAX_CLIMBABLE_ANGLE = 70.0  # Degrees - slopes steeper than this are hard to climb
# cos(70°) ≈ 0.342, so normal.y must be <= -0.342 for climbable
const MAX_CLIMBABLE_NORMAL_Y = -0.342

# Debug logging control
var debug_movement = true  # Enable detailed movement logging

# Grab constants
const GRAB_FORCE_GROUNDED = 1.0  # Full force when grounded
const GRAB_FORCE_AIRBORNE = 0.3  # Reduced force when airborne
const GRAB_BREAK_DISTANCE = 60.0  # Distance at which grab breaks
const GRAB_STIFFNESS = 50.0  # Spring stiffness for grab joint
const GRAB_DAMPING = 5.0  # Damping for grab joint

# Push/roll constants
const PUSH_FORCE_MULTIPLIER = 0.8  # Force transferred when pushing
const ROLL_TORQUE_MULTIPLIER = 50.0  # Torque applied to circular objects

# Layer system constants
const FRONT_LAYER = 0
const BACK_LAYER = 1
const FRONT_LAYER_TINT = Color(1.0, 1.0, 1.0, 1.0)
const BACK_LAYER_TINT = Color(0.7, 0.7, 0.7, 1.0)
const FRONT_LAYER_SCALE = Vector2(1.0, 1.0)
const BACK_LAYER_SCALE = Vector2(0.85, 0.85)
const FRONT_LAYER_Z_INDEX = 10
const BACK_LAYER_Z_INDEX = 0
const FLY_MODE_SCALE = Vector2(1.15, 1.15)
const FRONT_COLLISION_MASK = 1 | 4 | 8
const BACK_COLLISION_MASK = 2 | 4 | 8
const FRONT_COLLISION_LAYER = 1
const BACK_COLLISION_LAYER = 2

# Layer state
var current_layer: int = FRONT_LAYER

# References
var cursor: Node2D = null
@onready var sprite: Sprite2D = $Sprite2D
@onready var ground_raycast: RayCast2D = $GroundRayCast
@onready var grab_area: Area2D = $GrabArea

# Fly mode state
var is_fly_mode: bool = false
var drag_velocity: Vector2 = Vector2.ZERO
var original_collision_mask: int = 0
var original_collision_layer: int = 0
var original_z_index: int = 0
var original_scale: Vector2 = Vector2(1.0, 1.0)
var original_gravity_scale: float = 1.0

# Grab state
var grabbed_object: RigidBody2D = null
var grab_joint: PinJoint2D = null
var grab_offset: Vector2 = Vector2.ZERO
var is_grabbing: bool = false

# Facing direction (for grab area positioning)
var facing_direction: int = 1  # 1 = right, -1 = left

# Landing velocity preservation
var was_grounded: bool = true
var pre_landing_velocity_x: float = 0.0
var just_landed: bool = false  # Flag for _physics_process to also restore velocity

# Jump state
var jump_timer: float = 0.0  # Grace period after jumping

# Slope tracking
var current_floor_normal: Vector2 = Vector2.UP  # Normal of the surface we're standing on
var on_slope: bool = false  # True if on a slope steep enough to need compensation

# Push tracking to prevent twitching
var push_cooldowns: Dictionary = {}  # Object RID -> cooldown timer
const PUSH_COOLDOWN_TIME = 0.15  # Seconds before same object can be pushed again
var objects_being_pushed: Array[RigidBody2D] = []  # Objects currently in contact

# Jump state to prevent climbing on objects
var is_jumping: bool = false  # True when player initiated a jump

# Wall contact state (updated in _integrate_forces, used for logging)
var is_touching_wall: bool = false
var wall_push_direction: int = 0  # -1 = wall on left, 1 = wall on right, 0 = no wall
var wall_contact_timer: float = 0.0  # Persistence timer to prevent oscillation
const WALL_CONTACT_PERSIST_TIME = 0.1  # How long wall contact "sticks" after losing contact

# RigidBody push contact persistence (to prevent shaking when pushing heavy objects)
var recent_push_contacts: Dictionary = {}  # RID -> {body, position, timer}
const PUSH_CONTACT_PERSIST_TIME = 0.15  # How long push contact persists after losing contact

# Velocity tracking for debugging
var last_frame_velocity: Vector2 = Vector2.ZERO


func _integrate_forces(state: PhysicsDirectBodyState2D) -> void:
	# Skip all platformer physics processing in fly mode
	if is_fly_mode:
		return
	
	# EARLY VELOCITY CHECK: Detect extreme velocity changes (physics engine might be doing something crazy)
	var current_vel = state.get_linear_velocity()
	var vel_delta = current_vel - last_frame_velocity
	if vel_delta.length() > 500 and debug_movement:
		print("[VELOCITY_SPIKE] vel=", snapped(current_vel, Vector2(1, 1)), " was=", snapped(last_frame_velocity, Vector2(1, 1)), " delta=", snapped(vel_delta, Vector2(1, 1)), " contacts=", state.get_contact_count())
	last_frame_velocity = current_vel
	
	# Check if we just landed by looking at contacts
	var is_grounded_now = false
	var contacted_bodies: Array[RigidBody2D] = []
	var has_climbable_rigidbody_slope = false  # True if any RigidBody2D contact is climbable
	var touching_rigidbody = false
	var touching_wall = false  # True if touching a near-vertical surface (static or dynamic)
	var wall_normal_x = 0.0  # Average wall normal x component
	var wall_contact_count = 0
	
	# Slope threshold: 75 degrees from horizontal
	# cos(75°) ≈ 0.259, so normal.y must be <= -0.259 for climbable slope
	const CLIMBABLE_SLOPE_THRESHOLD = -0.259
	# Wall threshold: nearly vertical surfaces (within 15 degrees of vertical)
	# cos(75°) ≈ 0.259 for normal.x means surface is 15° from vertical
	const WALL_THRESHOLD = 0.3
	# Slope compensation: apply force to prevent sliding on slopes up to 45°
	const SLOPE_STICK_THRESHOLD = -0.7  # cos(45°) ≈ 0.707
	
	var best_floor_normal = Vector2.UP
	var best_floor_dot = 0.0  # Track the most "floor-like" contact
	
	for i in range(state.get_contact_count()):
		var normal = state.get_contact_local_normal(i)
		var collider = state.get_contact_collider_object(i)
		var collider_name = collider.name if collider else "unknown"
		
		# Ground contact detection - accept slopes up to ~75° as "ground"
		# normal.y < -0.26 means the surface is pointing somewhat upward
		if normal.y < CLIMBABLE_SLOPE_THRESHOLD:
			is_grounded_now = true
			# Track the most floor-like contact (most negative y = most upward-pointing)
			if normal.y < best_floor_dot:
				best_floor_dot = normal.y
				best_floor_normal = normal
		
		# Wall contact detection - near vertical surfaces (both static and dynamic)
		# A wall has a mostly horizontal normal (abs(normal.x) > 0.7 means < 45° from vertical)
		if abs(normal.x) > 0.7 and abs(normal.y) < WALL_THRESHOLD:
			touching_wall = true
			wall_normal_x += normal.x
			wall_contact_count += 1
			# Log wall contacts for debugging
			if Engine.get_physics_frames() % 15 == 0:
				print("[WALL_CONTACT] normal=", snapped(normal, Vector2(0.01, 0.01)), " collider=", collider_name)
		
		# Track RigidBody2D contacts for continuous pushing
		if collider is RigidBody2D and collider != self:
			touching_rigidbody = true
			if not contacted_bodies.has(collider):
				contacted_bodies.append(collider)
			
			# Check if this contact has a climbable slope (75° or less from horizontal)
			if normal.y <= CLIMBABLE_SLOPE_THRESHOLD:
				has_climbable_rigidbody_slope = true
	
	# Update list of objects being pushed
	objects_being_pushed = contacted_bodies
	
	# Update floor normal for slope handling
	if is_grounded_now:
		current_floor_normal = best_floor_normal
		# Check if we're on a significant slope (not flat ground)
		on_slope = abs(current_floor_normal.x) > 0.15  # More than ~8.5° slope
	else:
		current_floor_normal = Vector2.UP
		on_slope = false
	
	# Update persistent push contact tracking
	# Add/refresh current contacts
	for body in contacted_bodies:
		var rid = body.get_rid()
		recent_push_contacts[rid] = {
			"body": body,
			"position": body.global_position,
			"timer": PUSH_CONTACT_PERSIST_TIME
		}
	
	# Decay timers and remove expired entries
	var expired_rids: Array = []
	for rid in recent_push_contacts:
		if not contacted_bodies.has(recent_push_contacts[rid]["body"]):
			recent_push_contacts[rid]["timer"] -= state.get_step()
			if recent_push_contacts[rid]["timer"] <= 0:
				expired_rids.append(rid)
	for rid in expired_rids:
		recent_push_contacts.erase(rid)
	
	# Calculate average wall normal direction
	if wall_contact_count > 0:
		wall_normal_x /= wall_contact_count
	
	var vel = state.get_linear_velocity()
	var original_vel = vel
	
	# WALL FLOAT PREVENTION: When touching a wall while airborne and not grounded,
	# prevent the player from maintaining or gaining height by pushing into the wall
	if touching_wall and not is_grounded_now and not is_jumping:
		# Check if player is trying to move INTO the wall (velocity opposes wall normal)
		var moving_into_wall = (wall_normal_x > 0 and vel.x < -10) or (wall_normal_x < 0 and vel.x > 10)
		
		if moving_into_wall:
			# Cancel any upward velocity that might be caused by collision response
			if vel.y < 0:
				vel.y = 0
				print("[WALL_FLOAT_BLOCK] Cancelled upward vel while pushing into wall. was_vel=", snapped(original_vel, Vector2(0.1, 0.1)))
			
			# Also reduce horizontal velocity pushing into wall to prevent "sticking"
			var wall_slide_factor = 0.3  # Allow some sliding, but reduce wall push
			if wall_normal_x > 0:  # Wall on left, player pushing left
				vel.x = max(vel.x, -MAX_SPEED * wall_slide_factor)
			else:  # Wall on right, player pushing right
				vel.x = min(vel.x, MAX_SPEED * wall_slide_factor)
			
			state.set_linear_velocity(vel)
	
	# Update wall tracking state for other systems with persistence
	# This prevents oscillation when bouncing off walls
	if touching_wall:
		is_touching_wall = true
		wall_push_direction = int(sign(-wall_normal_x))
		wall_contact_timer = WALL_CONTACT_PERSIST_TIME
	else:
		# Decay the timer, keep wall state until timer expires
		wall_contact_timer -= state.get_step()
		if wall_contact_timer <= 0:
			is_touching_wall = false
			wall_push_direction = 0
	
	# Prevent climbing on RigidBody2D objects - if touching with steep slope and not in jump grace period,
	# clamp upward velocity to prevent collision response from lifting the player
	if touching_rigidbody and jump_timer <= 0 and not has_climbable_rigidbody_slope:
		vel = state.get_linear_velocity()
		if vel.y < -10:  # Moving upward significantly
			vel.y = 0  # Cancel upward movement from collision
			state.set_linear_velocity(vel)
			if Engine.get_physics_frames() % 30 == 0:  # Reduce log spam
				print("[CLIMB_BLOCK] Prevented climbing")
	
	# Decay jump timer
	if jump_timer > 0:
		jump_timer -= state.get_step()
	
	# DYNAMIC GRAVITY SCALING (Sackboy-style)
	# Check if player is pressing movement input
	var horizontal_input = Input.get_axis("ui_left", "ui_right")
	if horizontal_input == 0:
		horizontal_input = Input.get_axis("move_left", "move_right")
	
	# When moving on a slope, reduce gravity for that floaty climbing feel
	if is_grounded_now and on_slope and horizontal_input != 0 and jump_timer <= 0:
		gravity_scale = SLOPE_GRAVITY_SCALE
	elif not is_grounded_now or not on_slope:
		gravity_scale = NORMAL_GRAVITY_SCALE
	
	# ANTI-SLIDE FRICTION (Sackboy-style)
	# When idle on a slope, lock the player in place
	if is_grounded_now and on_slope and jump_timer <= 0 and horizontal_input == 0:
		var vel_now = state.get_linear_velocity()
		
		# If velocity is low, just stop the player completely (high friction simulation)
		if abs(vel_now.x) < 30:
			vel_now.x = 0
			state.set_linear_velocity(vel_now)
		else:
			# Apply strong braking force
			var brake_force = -sign(vel_now.x) * MOVE_FORCE * 2.0
			state.apply_central_force(Vector2(brake_force, 0))
		
		if Engine.get_physics_frames() % 60 == 0 and debug_movement:
			print("[SLOPE] idle brake, vel.x=", snapped(vel_now.x, 1))
	
	# Reset jump state when grounded AND jump grace period is over
	if is_grounded_now and jump_timer <= 0:
		is_jumping = false
	
	# Preserve horizontal velocity when landing (but don't let it accumulate)
	if is_grounded_now and not was_grounded:
		vel = state.get_linear_velocity()
		# Only restore if it helps maintain momentum, not gain it
		# And cap to MAX_SPEED to prevent accumulation
		var capped_restore = clamp(pre_landing_velocity_x, -MAX_SPEED, MAX_SPEED)
		# Only restore if current velocity is significantly lower (collision killed it)
		if abs(vel.x) < abs(capped_restore) * 0.5:
			vel.x = capped_restore
			state.set_linear_velocity(vel)
			just_landed = true
			if Engine.get_physics_frames() % 30 == 0:  # Reduce log spam
				print("[LAND] Restored vel.x to ", snapped(capped_restore, 0.1))
	
	# Track velocity while airborne for next landing (capped)
	if not is_grounded_now:
		pre_landing_velocity_x = clamp(state.get_linear_velocity().x, -MAX_SPEED, MAX_SPEED)
	
	was_grounded = is_grounded_now
	
	# SANITY CHECK: Clamp extreme velocities that shouldn't occur
	vel = state.get_linear_velocity()
	var max_sane_vel = MAX_SPEED * 5  # Allow up to 5x max speed before clamping
	if abs(vel.x) > max_sane_vel or abs(vel.y) > max_sane_vel:
		print("[EXTREME_VEL_FIX] Clamping insane velocity: ", snapped(vel, Vector2(1, 1)))
		vel.x = clamp(vel.x, -max_sane_vel, max_sane_vel)
		vel.y = clamp(vel.y, -max_sane_vel, max_sane_vel)
		state.set_linear_velocity(vel)
	
	# Periodic debug logging for physics state
	if debug_movement and Engine.get_physics_frames() % 60 == 0:
		print("[PHYSICS] grounded=", is_grounded_now, " wall=", touching_wall, " rb=", touching_rigidbody, 
			" vel=", snapped(state.get_linear_velocity(), Vector2(1, 1)), " contacts=", state.get_contact_count())


func _ready() -> void:
	add_to_group("player")
	
	# Ensure body is not frozen and cannot sleep
	freeze = false
	sleeping = false
	can_sleep = false
	
	# Store original settings
	original_collision_mask = collision_mask
	original_collision_layer = collision_layer
	original_z_index = z_index
	original_scale = scale
	original_gravity_scale = gravity_scale
	
	# Initialize layer appearance
	_update_layer_appearance()
	_update_layer_collision()
	
	# Connect body signals for push detection
	body_entered.connect(_on_body_entered)
	
	# Clear any initial velocity
	linear_velocity = Vector2.ZERO
	print("[READY] Player initialized. mass=", mass, " linear_damp=", linear_damp, " pos=", global_position)
	
	# Find cursor after scene is ready
	await get_tree().process_frame
	cursor = get_tree().get_first_node_in_group("cursor")


func _input(event: InputEvent) -> void:
	# Toggle fly mode with O key
	if event is InputEventKey and event.pressed and event.keycode == KEY_O:
		toggle_fly_mode()
	
	# Layer switching (disabled in fly mode)
	if event is InputEventKey and event.pressed and not event.echo and not is_fly_mode:
		if event.keycode == KEY_UP or event.keycode == KEY_W:
			switch_to_layer(BACK_LAYER)
		elif event.keycode == KEY_DOWN or event.keycode == KEY_S:
			switch_to_layer(FRONT_LAYER)
	
	# Grab input with Shift (disabled in fly mode)
	if event is InputEventKey and not is_fly_mode:
		if event.keycode == KEY_SHIFT:
			if event.pressed and not is_grabbing:
				_try_grab()
			elif not event.pressed and is_grabbing:
				_release_grab()


func _physics_process(delta: float) -> void:
	# Restore velocity immediately if we just landed (before any rendering)
	if just_landed:
		linear_velocity.x = pre_landing_velocity_x
		just_landed = false
	
	_update_facing_direction()
	_update_grab_area_position()
	
	if is_fly_mode:
		_handle_fly_mode(delta)
	else:
		_handle_platformer_mode(delta)
		_handle_grab_physics(delta)
		_process_continuous_push(delta)
	
	# Clamp velocity to max speed
	_clamp_velocity()


func _handle_platformer_mode(delta: float) -> void:
	var is_grounded = _is_on_floor()
	var old_vel = linear_velocity
	
	# Don't accept movement input if cursor mode is active
	var cursor_active = cursor and cursor.has_method("is_cursor_active") and cursor.is_cursor_active()
	
	if cursor_active:
		# Apply counter-force to slow down horizontal movement
		if abs(linear_velocity.x) > 10:
			apply_central_force(Vector2(-sign(linear_velocity.x) * MOVE_FORCE * 0.5, 0))
		return
	
	# Handle jump - with slope-based reduction
	if Input.is_action_just_pressed("ui_accept") and is_grounded and not is_grabbing:
		# Calculate jump power based on slope steepness
		var jump_multiplier = 1.0
		
		if on_slope:
			# Calculate slope angle from floor normal
			# normal.y = -1 is flat (0°), normal.y = 0 is vertical (90°)
			# steepness = abs(normal.x) = sin(angle)
			# 60° start threshold: sin(60°) ≈ 0.866
			# 70° full reduction: sin(70°) ≈ 0.94, jump is 10%
			var start_threshold = 0.866  # abs(normal.x) at 60° = sin(60°)
			var steep_threshold = 0.94   # abs(normal.x) at 70° = sin(70°)
			
			var steepness = abs(current_floor_normal.x)  # 0 at flat, 0.94 at 70°
			if steepness > start_threshold:  # Only reduce on slopes >= 60°
				# Map steepness 0.866-0.94 to multiplier 1.0-0.1
				jump_multiplier = lerp(1.0, 0.1, clamp((steepness - start_threshold) / (steep_threshold - start_threshold), 0.0, 1.0))
		
		# Calculate jump velocity with slope reduction
		var actual_jump_velocity = JUMP_VELOCITY * jump_multiplier
		
		# PREVENT VELOCITY ACCUMULATION: Reset vertical velocity before jumping
		# This prevents stacking jumps for extra height
		linear_velocity.y = -actual_jump_velocity
		
		# Also cap horizontal velocity on jump to prevent speed accumulation
		var max_jump_horizontal = MAX_SPEED * 0.8
		linear_velocity.x = clamp(linear_velocity.x, -max_jump_horizontal, max_jump_horizontal)
		
		is_jumping = true
		jump_timer = JUMP_GRACE_TIME  # Grace period to escape ground detection
		
		if jump_multiplier < 1.0:
			print("[JUMP] slope reduced: vel.y=", snapped(-actual_jump_velocity, 0.1), " mult=", snapped(jump_multiplier, 0.01))
		else:
			print("[JUMP] vel.y=", -actual_jump_velocity)
	
	# Get horizontal input
	var direction := Input.get_axis("ui_left", "ui_right")
	if direction == 0:
		direction = Input.get_axis("move_left", "move_right")
	
	var action = "none"
	
	# Check if we're pushing into a wall/object (works for both grounded and airborne)
	# Use multiple detection methods for reliability:
	# 1. Wall normal detection (is_touching_wall from _integrate_forces)
	# 2. Persistent RigidBody2D contact tracking (recent_push_contacts)
	var pushing_into_wall = false
	var push_target_direction = 0
	
	# Method 1: Wall normal detection
	if is_touching_wall:
		if (wall_push_direction > 0 and direction > 0) or (wall_push_direction < 0 and direction < 0):
			pushing_into_wall = true
			push_target_direction = wall_push_direction
	
	# Method 2: Persistent RigidBody2D contact detection (uses timer-based persistence)
	if not pushing_into_wall and direction != 0 and recent_push_contacts.size() > 0:
		for rid in recent_push_contacts:
			var contact_data = recent_push_contacts[rid]
			var body = contact_data["body"]
			if is_instance_valid(body):
				var to_body = (body.global_position - global_position).normalized()
				# Check if we're trying to move toward this body
				if (to_body.x > 0.3 and direction > 0) or (to_body.x < -0.3 and direction < 0):
					pushing_into_wall = true
					push_target_direction = int(sign(to_body.x))
					break
	
	# SACKBOY-STYLE FORCE-BASED MOVEMENT
	# Use proportional control: force scales with how far we are from target speed
	# This naturally limits acceleration as we approach max speed
	var applied_force = Vector2.ZERO  # Now a Vector2 for slope-aligned movement
	
	if direction != 0:
		var target_speed = direction * MAX_SPEED
		var current_speed = linear_velocity.x
		var speed_diff = target_speed - current_speed
		var speed_ratio = abs(current_speed) / MAX_SPEED  # 0 to 1+
		
		if pushing_into_wall:
			# Pushing into wall/object: gentle constant force
			applied_force = Vector2(direction * MOVE_FORCE * 0.3, 0)
			action = "push"
		elif is_grounded:
			# Grounded: force reduces as we approach max speed (proportional control)
			var force_scale = clamp(1.0 - speed_ratio * 0.8, 0.2, 1.0)
			var base_force_magnitude = MOVE_FORCE * force_scale
			
			if on_slope:
				# VECTOR PROJECTION: Push along the slope, not just horizontally
				# For a normal (nx, ny), the tangent pointing "right" along the surface is:
				# (-ny, nx) for upward-pointing normals (ny < 0)
				# This ensures we push ALONG the slope surface, not into it
				var slope_tangent = Vector2(-current_floor_normal.y, current_floor_normal.x)
				# slope_tangent now points "right" along the slope
				# Flip for leftward movement
				if direction < 0:
					slope_tangent = -slope_tangent
				
				slope_tangent = slope_tangent.normalized()
				
				# Check if going uphill (moving against the direction normal.x points)
				var going_uphill = (current_floor_normal.x > 0 and direction < 0) or (current_floor_normal.x < 0 and direction > 0)
				
				# Apply slope speed multiplier (80% of ground speed)
				var slope_force = base_force_magnitude * SLOPE_SPEED_MULTIPLIER
				
				# Check if slope is too steep (steeper than 70 degrees)
				# normal.y closer to 0 = steeper slope
				var is_too_steep = current_floor_normal.y > MAX_CLIMBABLE_NORMAL_Y
				
				if going_uphill and is_too_steep:
					# Steep slope penalty - greatly reduce climbing ability
					# The steeper it is, the harder to climb
					var steepness_factor = abs(current_floor_normal.x)  # 0.94 at 70°, 1.0 at 90°
					var climb_penalty = 1.0 - ((steepness_factor - 0.94) / 0.06)  # 1.0 at 70°, 0.0 at 90°
					climb_penalty = clamp(climb_penalty, 0.1, 1.0)  # Never fully zero
					slope_force *= climb_penalty * 0.3  # Heavy penalty on steep slopes
					action = "steep f=" + str(snapped(slope_force, 0.1)) + " pen=" + str(snapped(climb_penalty, 0.01))
				else:
					if going_uphill:
						action = "uphill f=" + str(snapped(slope_force, 0.1))
					else:
						action = "downhill f=" + str(snapped(slope_force, 0.1))
				
				# Apply force along the slope
				applied_force = slope_tangent * slope_force
				
				# UPWARD ASSIST: When going uphill (and not too steep), add extra upward force
				if going_uphill and not is_too_steep:
					var upward_assist = slope_force * SLOPE_UPWARD_ASSIST
					applied_force.y -= upward_assist  # Negative Y is up
			else:
				# Flat ground: just horizontal force
				applied_force = Vector2(direction * base_force_magnitude, 0)
				action = "ground f=" + str(snapped(applied_force.x, 0.1))
		else:
			# Airborne: reduced and proportional
			var force_scale = clamp(1.0 - speed_ratio * 0.9, 0.1, 1.0)
			var air_force = direction * MOVE_FORCE * AIR_CONTROL_MULTIPLIER * force_scale
			applied_force = Vector2(air_force, 0)
			action = "air f=" + str(snapped(air_force, 0.1))
		
		apply_central_force(applied_force)
	else:
		# No input: rely on linear_damp for natural slowdown
		# Only apply active braking if moving fast on ground (and not on a slope - that's handled in _integrate_forces)
		if is_grounded and abs(linear_velocity.x) > 20 and not on_slope:
			var brake_force = -sign(linear_velocity.x) * MOVE_FORCE * 0.5
			apply_central_force(Vector2(brake_force, 0))
			action = "brake f=" + str(snapped(brake_force, 0.1))
		else:
			action = "idle"
	
	# Detailed logging for movement diagnosis
	if debug_movement:
		var vel_changed = abs(linear_velocity.x - old_vel.x) > 10 or abs(linear_velocity.y - old_vel.y) > 10
		var extreme_vel = abs(linear_velocity.x) > MAX_SPEED * 2 or abs(linear_velocity.y) > 1000
		
		if vel_changed or extreme_vel or Engine.get_physics_frames() % 60 == 0:
			var state = "G" if is_grounded else "A"  # Grounded/Airborne
			var push_info = ""
			if pushing_into_wall:
				push_info = " PUSH"
			if extreme_vel:
				print("[EXTREME_VEL] vel=", snapped(linear_velocity, Vector2(1, 1)), " old=", snapped(old_vel, Vector2(1, 1)), " delta=", snapped(linear_velocity - old_vel, Vector2(1, 1)))
			print("[Move] ", state, push_info, " dir=", direction, " vel=", snapped(linear_velocity, Vector2(1, 1)), " ", action)


func _handle_fly_mode(delta: float) -> void:
	var cursor_active = cursor and cursor.has_method("is_cursor_active") and cursor.is_cursor_active()
	
	if cursor_active:
		# Smooth drag movement - interpolate toward drag velocity for smoothness
		var target_vel = drag_velocity
		var smoothing = 8.0  # Higher = snappier, lower = smoother
		linear_velocity = linear_velocity.lerp(target_vel, smoothing * delta)
	else:
		# Free flight with omnidirectional movement
		var direction := Vector2.ZERO
		var horizontal = Input.get_axis("ui_left", "ui_right")
		if horizontal == 0:
			horizontal = Input.get_axis("move_left", "move_right")
		var vertical = Input.get_axis("ui_up", "ui_down")
		if vertical == 0:
			vertical = Input.get_axis("move_up", "move_down")
		direction.x = horizontal
		direction.y = vertical
		
		if direction != Vector2.ZERO:
			direction = direction.normalized()
			# Smooth acceleration toward target velocity
			var target_velocity = direction * FLY_MAX_SPEED
			var acceleration = 6.0  # How quickly to accelerate to target
			linear_velocity = linear_velocity.lerp(target_velocity, acceleration * delta)
		else:
			# Smooth deceleration when no input
			var deceleration = 4.0  # How quickly to slow down
			linear_velocity = linear_velocity.lerp(Vector2.ZERO, deceleration * delta)


func _clamp_velocity() -> void:
	var max_spd = FLY_MAX_SPEED if is_fly_mode else MAX_SPEED
	var was_extreme = abs(linear_velocity.x) > max_spd * 2 or abs(linear_velocity.y) > 1000
	
	if was_extreme and debug_movement:
		print("[VELOCITY_CLAMP] Extreme velocity detected: ", snapped(linear_velocity, Vector2(1, 1)))
	
	if not is_fly_mode:
		# Clamp horizontal and also vertical to reasonable limits
		linear_velocity.x = clamp(linear_velocity.x, -max_spd, max_spd)
		# Allow more vertical for jumping/falling, but clamp extremes
		linear_velocity.y = clamp(linear_velocity.y, -1000, 1000)
	else:
		# Clamp total velocity in fly mode
		if linear_velocity.length() > max_spd:
			linear_velocity = linear_velocity.normalized() * max_spd


func _is_on_floor() -> bool:
	# Slope threshold matching _integrate_forces: 75 degrees from horizontal
	const FLOOR_THRESHOLD = -0.259  # cos(75°)
	
	# Use PhysicsDirectBodyState2D for contact detection
	var state = PhysicsServer2D.body_get_direct_state(get_rid())
	if state and state.get_contact_count() > 0:
		for i in range(state.get_contact_count()):
			var contact_normal = state.get_contact_local_normal(i)
			# If normal points up enough, we're resting on a climbable surface
			if contact_normal.y < FLOOR_THRESHOLD:
				return true
	
	# Fallback to raycast
	if ground_raycast and ground_raycast.is_colliding():
		return true
	
	return false


func _update_facing_direction() -> void:
	var horizontal = Input.get_axis("ui_left", "ui_right")
	if horizontal == 0:
		horizontal = Input.get_axis("move_left", "move_right")
	
	if horizontal != 0:
		facing_direction = int(sign(horizontal))


func _update_grab_area_position() -> void:
	if grab_area:
		# Position grab area in front of player based on facing direction
		var grab_shape = grab_area.get_node_or_null("GrabShape")
		if grab_shape:
			grab_shape.position.x = 12 * facing_direction


# ============== GRAB MECHANICS ==============

func _try_grab() -> void:
	if is_fly_mode:
		return
	
	# Get bodies overlapping grab area
	var bodies = grab_area.get_overlapping_bodies()
	
	for body in bodies:
		if body is RigidBody2D and body != self:
			# Check if object is grabbable (plaster material or low mass)
			if _is_grabbable(body):
				_grab_object(body)
				return


func _is_grabbable(body: RigidBody2D) -> bool:
	# Check for plaster material
	if body.has_meta("material_regions"):
		var regions = body.get_meta("material_regions")
		for region in regions:
			if region is MaterialRegion and region.material:
				# Check if it's plaster (density 0.4) or similarly light material
				if region.material.density <= 0.5:
					return true
	
	# Also allow grabbing light objects (mass threshold)
	if body.mass <= 2.0:
		return true
	
	return false


func _grab_object(body: RigidBody2D) -> void:
	grabbed_object = body
	is_grabbing = true
	
	# Calculate grab offset (where we're grabbing the object)
	grab_offset = body.global_position - global_position
	
	# Create a pin joint to connect player to object
	grab_joint = PinJoint2D.new()
	grab_joint.node_a = get_path()
	grab_joint.node_b = body.get_path()
	grab_joint.softness = 1.0 / GRAB_STIFFNESS
	add_child(grab_joint)
	
	grab_state_changed.emit(true, grabbed_object)


func _release_grab() -> void:
	if grab_joint:
		grab_joint.queue_free()
		grab_joint = null
	
	var old_grabbed = grabbed_object
	grabbed_object = null
	is_grabbing = false
	grab_offset = Vector2.ZERO
	
	grab_state_changed.emit(false, old_grabbed)


func _handle_grab_physics(delta: float) -> void:
	if not is_grabbing or not grabbed_object or not is_instance_valid(grabbed_object):
		if is_grabbing:
			_release_grab()
		return
	
	# Check if grab should break due to distance
	var current_distance = global_position.distance_to(grabbed_object.global_position)
	if current_distance > GRAB_BREAK_DISTANCE:
		_release_grab()
		return
	
	# Apply movement force to grabbed object based on player's movement
	var is_grounded = _is_on_floor()
	var force_multiplier = GRAB_FORCE_GROUNDED if is_grounded else GRAB_FORCE_AIRBORNE
	
	# Transfer some of player's movement intention to grabbed object
	var horizontal = Input.get_axis("ui_left", "ui_right")
	if horizontal == 0:
		horizontal = Input.get_axis("move_left", "move_right")
	
	if horizontal != 0:
		var grab_force = horizontal * MOVE_FORCE * force_multiplier * 0.5
		grabbed_object.apply_central_force(Vector2(grab_force, 0))


# ============== PUSH/ROLL MECHANICS ==============

func _on_body_entered(body: Node) -> void:
	# Initial contact - only used for logging now, actual push is continuous
	if body is RigidBody2D and body != self and not is_grabbing:
		print("[PUSH] Contact with: ", body.name)


func _process_continuous_push(delta: float) -> void:
	# Update cooldowns
	var rids_to_remove: Array = []
	for rid in push_cooldowns:
		push_cooldowns[rid] -= delta
		if push_cooldowns[rid] <= 0:
			rids_to_remove.append(rid)
	for rid in rids_to_remove:
		push_cooldowns.erase(rid)
	
	# Process objects we're currently in contact with
	for body in objects_being_pushed:
		if not is_instance_valid(body) or is_grabbing:
			continue
		
		var rid = body.get_rid()
		
		# Skip if on cooldown
		if push_cooldowns.has(rid):
			continue
		
		# Only push if we're actively moving toward the object
		var to_body = (body.global_position - global_position).normalized()
		var velocity_toward = linear_velocity.dot(to_body)
		
		if velocity_toward > 10:  # Moving toward object at reasonable speed
			_apply_push_force(body)
			push_cooldowns[rid] = PUSH_COOLDOWN_TIME


func _apply_push_force(body: RigidBody2D) -> void:
	# Calculate push direction from player to object
	var push_direction = (body.global_position - global_position).normalized()
	
	# Calculate push force based on player's velocity
	var push_magnitude = linear_velocity.length() * PUSH_FORCE_MULTIPLIER
	var push_force = push_direction * push_magnitude * mass
	
	# Apply force to the object
	body.apply_central_impulse(push_force)
	print("[PUSH] Applied force ", snapped(push_force.length(), 0.1), " to ", body.name, " dir=", snapped(push_direction, Vector2(0.01, 0.01)))
	
	# Check if object has circular collision for rolling
	if _has_circular_collision(body):
		_apply_roll_torque(body, push_direction)


func _has_circular_collision(body: RigidBody2D) -> bool:
	for child in body.get_children():
		if child is CollisionShape2D:
			var shape = child.shape
			if shape is CircleShape2D:
				return true
	return false


func _apply_roll_torque(body: RigidBody2D, push_direction: Vector2) -> void:
	# Apply torque to make circular object roll
	# Torque direction depends on push direction (push right = roll clockwise)
	var torque = push_direction.x * linear_velocity.length() * ROLL_TORQUE_MULTIPLIER
	body.apply_torque(torque)


# ============== FLY MODE ==============

func toggle_fly_mode() -> void:
	is_fly_mode = not is_fly_mode
	
	# Release grab when entering fly mode
	if is_fly_mode and is_grabbing:
		_release_grab()
	
	# If trying to exit fly mode, check if front layer is clear
	if not is_fly_mode and not _is_layer_clear(FRONT_LAYER):
		is_fly_mode = true  # Stay in fly mode
		return
	
	fly_mode_changed.emit(is_fly_mode)
	
	if is_fly_mode:
		# Enable fly mode
		collision_mask = 12  # Ground and boundaries only
		collision_layer = 0  # Don't exist on any layer
		z_index = 100
		scale = FLY_MODE_SCALE
		gravity_scale = 0.0  # No gravity in fly mode
		if sprite:
			sprite.modulate = FRONT_LAYER_TINT
	else:
		# Restore normal mode
		current_layer = FRONT_LAYER
		collision_mask = original_collision_mask
		collision_layer = original_collision_layer
		z_index = original_z_index
		drag_velocity = Vector2.ZERO
		gravity_scale = original_gravity_scale
		_update_layer_appearance()
		_update_layer_collision()


func set_drag_velocity(vel: Vector2) -> void:
	"""Called by cursor controller to drag player in fly mode"""
	if is_fly_mode:
		drag_velocity = vel


# ============== LAYER SYSTEM ==============

func switch_to_layer(new_layer: int) -> void:
	if current_layer == new_layer:
		return
	
	if not _is_layer_clear(new_layer):
		return
	
	current_layer = new_layer
	_update_layer_appearance()
	_update_layer_collision()
	layer_changed.emit(current_layer)


func _is_layer_clear(target_layer: int) -> bool:
	var current_mask = collision_mask
	var current_col_layer = collision_layer
	
	if target_layer == BACK_LAYER:
		collision_mask = BACK_COLLISION_MASK
	else:
		collision_mask = FRONT_COLLISION_MASK
	
	# Use shape query for RigidBody2D
	var space_state = get_world_2d().direct_space_state
	var query = PhysicsShapeQueryParameters2D.new()
	
	# Get player's collision shape
	var collision_shape = get_node_or_null("CollisionShape2D")
	if collision_shape and collision_shape.shape:
		query.shape = collision_shape.shape
		query.transform = global_transform
		query.collision_mask = collision_mask
		query.exclude = [get_rid()]
		
		var result = space_state.intersect_shape(query, 1)
		
		# Restore original settings
		collision_mask = current_mask
		collision_layer = current_col_layer
		
		return result.is_empty()
	
	# Restore if no shape found
	collision_mask = current_mask
	collision_layer = current_col_layer
	return true


func _update_layer_appearance() -> void:
	if not sprite:
		return
	
	if is_fly_mode:
		return
	
	if current_layer == BACK_LAYER:
		sprite.modulate = BACK_LAYER_TINT
		scale = BACK_LAYER_SCALE
		z_index = BACK_LAYER_Z_INDEX
	else:
		sprite.modulate = FRONT_LAYER_TINT
		scale = FRONT_LAYER_SCALE
		z_index = FRONT_LAYER_Z_INDEX


func _update_layer_collision() -> void:
	if is_fly_mode:
		return
	
	if current_layer == BACK_LAYER:
		collision_mask = BACK_COLLISION_MASK
		collision_layer = BACK_COLLISION_LAYER
	else:
		collision_mask = FRONT_COLLISION_MASK
		collision_layer = FRONT_COLLISION_LAYER
	
	if not is_fly_mode:
		original_collision_mask = collision_mask
		original_collision_layer = collision_layer
		original_z_index = z_index
