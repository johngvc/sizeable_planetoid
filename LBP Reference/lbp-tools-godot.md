# LittleBigPlanet Tools Bag - Godot 2D Implementation Guide

## 1. Tools

### Material Changer
**Functionality:** Changes the material/texture of connected objects to a selected material
**Godot Implementation:** 
- TileMap/Sprite2D texture swapping
- Resource management system
- Modulate property for color changes
- Custom shader materials

### Corner Editor
**Functionality:** Precise shape manipulation by editing vertices and edges
**Godot Implementation:**
- Polygon2D editing
- Line2D point manipulation
- CollisionPolygon2D vertex editing
- Custom editor tool plugin

### Electric Tool
**Functionality:** Apply electrical hazard effect to materials
**Godot Implementation:**
- Area2D with damage detection
- AnimatedSprite2D for electric effect
- ParticleSystem2D for sparks
- AudioStreamPlayer for sound

### Flame Tool
**Functionality:** Apply fire hazard that damages on contact
**Godot Implementation:**
- Area2D collision detection
- CPUParticles2D/GPUParticles2D for flames
- Timer for damage-over-time
- Light2D for glow effect

### Horrible Gas Tool
**Functionality:** Lingering deadly gas with customizable color
**Godot Implementation:**
- Area2D with slow-moving particles
- CPUParticles2D with custom color/modulate
- Gradual opacity/fade
- CanvasGroup for blend modes

### Unlethalize Tool
**Functionality:** Remove hazards from materials
**Godot Implementation:**
- Remove Area2D children
- Clear collision masks/layers
- Reset material properties
- Remove particle effects

### Capture Object
**Functionality:** Save objects for reuse or distribution
**Godot Implementation:**
- PackedScene resource system
- Node.duplicate() for copies
- JSON/Resource serialization
- Inventory/collection system

---

## 2. Gadgets

### Connectors

#### Bolt
**Functionality:** Join objects with adjustable rotation/tightness
**Godot Implementation:**
- PinJoint2D
- Joint stiffness/damping parameters
- Angular limits

#### Sprung Bolt
**Functionality:** Bolt that springs back to position
**Godot Implementation:**
- DampedSpringJoint2D
- Stiffness/damping properties
- Rest length configuration

#### Motor Bolt
**Functionality:** Rotating connector with speed control
**Godot Implementation:**
- GrooveJoint2D or custom joint
- RigidBody2D with angular velocity
- Constant force/torque application

#### Wobble Bolt
**Functionality:** Bolt that rotates within angle limits then reverses
**Godot Implementation:**
- PinJoint2D with angular limits
- Custom script with sin/cos oscillation
- Tween animations

#### String
**Functionality:** Basic connector between two objects
**Godot Implementation:**
- Line2D for visual
- DampedSpringJoint2D
- Verlet integration for physics

#### Elastic
**Functionality:** Stretchy string connector
**Godot Implementation:**
- DampedSpringJoint2D with high damping
- Adjustable stiffness property
- Visual stretch using Line2D scaling

#### Rod
**Functionality:** Rigid unbending connector
**Godot Implementation:**
- PinJoint2D with zero damping
- Fixed distance constraint
- CollisionShape2D for solid rod

#### Spring
**Functionality:** Spring that returns to rest position
**Godot Implementation:**
- DampedSpringJoint2D
- Rest length property
- Spring constant/damping ratio

#### Winch
**Functionality:** Adjustable-length string that reels in/out
**Godot Implementation:**
- GrooveJoint2D with moving anchor
- Tween for length animation
- Speed/min/max length properties

#### Piston
**Functionality:** Rigid rod with adjustable length
**Godot Implementation:**
- GrooveJoint2D
- RigidBody2D with position constraints
- Linear interpolation for movement

---

### Creature Pieces

#### Magic Mouth
**Functionality:** Triggered audio/text display near player
**Godot Implementation:**
- Area2D for proximity detection
- AudioStreamPlayer2D
- Label/RichTextLabel for dialogue
- AnimatedSprite2D for mouth animation

#### Magic Eye
**Functionality:** Eyes that follow player
**Godot Implementation:**
- Sprite2D with look_at() method
- Area2D to detect player position
- Rotation constraints
- Smooth rotation with lerp

#### Leg
**Functionality:** Animated walking appendage
**Godot Implementation:**
- AnimationPlayer
- Sprite2D/AnimatedSprite2D
- IK (inverse kinematics) solver
- RayCast2D for ground detection

#### Creature Navigator
**Functionality:** Boundary that forces creatures to turn around
**Godot Implementation:**
- Area2D collision zones
- State machine for direction change
- NavigationRegion2D boundaries
- Signal-based turn triggers

#### Creature Brain (Protected)
**Functionality:** AI controller that makes creatures move (invincible)
**Godot Implementation:**
- CharacterBody2D/RigidBody2D
- State machine (idle, chase, flee, patrol)
- NavigationAgent2D
- Immortal flag (no health system)

#### Creature Brain (Unprotected)
**Functionality:** AI controller that makes creatures move (killable)
**Godot Implementation:**
- CharacterBody2D/RigidBody2D
- State machine
- Health component
- Death animation/free on death

#### Wheel
**Functionality:** Rotating wheel for creature movement
**Godot Implementation:**
- RigidBody2D with circular shape
- WheelJoint2D
- Motor force/torque
- AnimatedSprite2D rotation

---

### Special

#### Emitter
**Functionality:** Spawns custom objects at intervals
**Godot Implementation:**
- Timer node for spawn rate
- Instance spawning from PackedScene
- Queue_free() with lifetime timer
- Velocity/direction properties

#### Rocket (Thruster)
**Functionality:** Provides thrust force
**Godot Implementation:**
- apply_force() or apply_impulse()
- CPUParticles2D for exhaust
- AudioStreamPlayer for sound
- Adjustable thrust magnitude

#### Global Lighting Object
**Functionality:** Changes lighting/atmosphere when activated
**Godot Implementation:**
- CanvasModulate node
- WorldEnvironment settings
- Environment resource tweaking
- Signal connections to switches

---

### Switches

#### Button
**Functionality:** Activated by pressing/jumping
**Godot Implementation:**
- Area2D collision detection
- AnimatedSprite2D for press animation
- Signal emission on activation
- Cooldown timer

#### Sticker Switch (Sticker Sensor)
**Functionality:** Activates when specific sticker placed
**Godot Implementation:**
- Drag-and-drop detection
- Sprite comparison/matching
- Area2D for placement zone
- Resource/texture matching

#### Grab Switch (Grab Sensor)
**Functionality:** Activates when object is grabbed
**Godot Implementation:**
- Signal from player grab action
- Boolean flag for grabbed state
- RigidBody2D contact monitoring
- Custom input handling

#### Sensor Switch (Player Sensor)
**Functionality:** Activates when player is nearby
**Godot Implementation:**
- Area2D with body_entered/exited
- Detection radius adjustable
- Layer/mask filtering
- Distance calculation option

#### 2-Way Switch
**Functionality:** Toggle switch (on/off)
**Godot Implementation:**
- Boolean state variable
- Collision detection
- Visual state change (Sprite2D)
- Toggle on contact

#### 3-Way Switch
**Functionality:** Three-position directional switch
**Godot Implementation:**
- Integer state (0, 1, 2)
- Directional input detection
- Rotation/position visual
- State machine

#### Magnetic Key (Tag)
**Functionality:** Colored key for activating matching switches
**Godot Implementation:**
- Groups system
- Color/ID property
- Collision layer metadata
- Visual color coding

#### Magnetic Key Switch (Tag Sensor)
**Functionality:** Activated by matching colored key
**Godot Implementation:**
- Area2D detection
- Group matching logic
- Color/ID comparison
- Visual feedback on activation

#### Paint Switch
**Functionality:** Activates when shot by paintinator
**Godot Implementation:**
- Area2D for projectile detection
- Hit counter
- One-shot/on-off/directional modes
- Visual splatter effect

#### Water Switch (Water Sensor)
**Functionality:** Activates when submerged
**Godot Implementation:**
- Area2D for water zones
- Buoyancy detection
- Inversion option
- Collision mask for water layer

---

## 3. Gameplay Kits

### Basic Kit

#### Camera Zone
**Functionality:** Controls camera angle/position in area
**Godot Implementation:**
- Camera2D node
- Area2D for zone triggers
- Position/zoom smoothing
- Limit properties

#### Entrance
**Functionality:** Level starting checkpoint
**Godot Implementation:**
- Marker2D for spawn position
- Global spawn point reference
- Scene entry logic
- Player instantiation point

#### Score Bubble
**Functionality:** Collectible that adds points
**Godot Implementation:**
- Area2D collision detection
- Global score variable increment
- Particle effect on collect
- AudioStreamPlayer

#### Scoreboard
**Functionality:** Level end with score display
**Godot Implementation:**
- Control/Panel UI node
- Label for score display
- SceneTree.change_scene()
- Leaderboard data storage

#### Checkpoint
**Functionality:** Respawn point with limited lives
**Godot Implementation:**
- Marker2D for respawn position
- Lives counter variable
- Global checkpoint reference
- Flag animation

#### Close-Level Post
**Functionality:** Prevents new players from joining
**Godot Implementation:**
- Multiplayer API lock
- Global flag variable
- Trigger zone (Area2D)
- Network state change

#### Photo Booth (Snapshot Camera)
**Functionality:** Takes screenshot
**Godot Implementation:**
- Viewport.get_texture()
- Image.save_png()
- Screenshot capture system
- UI display of photo

#### Prize Bubble
**Functionality:** Gives items when collected
**Godot Implementation:**
- Area2D detection
- Inventory system integration
- Item/resource loading
- Collection feedback

#### Double-Life Checkpoint
**Functionality:** Checkpoint with extra lives
**Godot Implementation:**
- Same as Checkpoint
- Lives = 8 instead of 4
- Visual ring indicator
- Lives counter UI

#### Infinite-Life Checkpoint
**Functionality:** Checkpoint with unlimited respawns
**Godot Implementation:**
- Same as Checkpoint
- Lives = INF or -1
- No lives counter
- Always active

---

### Character Enhancements

#### Jetpack
**Functionality:** Limited-use flight ability
**Godot Implementation:**
- apply_force() upward
- Fuel/energy resource
- CPUParticles2D thrust effect
- Input detection for activation

#### Tetherless Jetpack
**Functionality:** Jetpack without rope constraint
**Godot Implementation:**
- Same as Jetpack
- No tether visual/physics
- Free movement

#### Paintinator
**Functionality:** Projectile weapon power-up
**Godot Implementation:**
- Projectile spawning system
- RayCast2D or Area2D bullets
- Ammo counter
- Aiming with mouse/stick

#### Scuba Gear
**Functionality:** Underwater breathing equipment
**Godot Implementation:**
- Oxygen timer extension
- Visual overlay/UI
- Underwater movement modifier
- Bubble particle effect

#### Bubble Machine
**Functionality:** Creates protective bubbles
**Godot Implementation:**
- Sphere Area2D spawn
- RigidBody2D physics
- Float upward behavior
- Collision detection

#### Enhancement Remover
**Functionality:** Strips player enhancements
**Godot Implementation:**
- Remove child nodes
- Reset player variables
- Clear inventory flags
- State machine reset

---

### Dangerous Kit

#### Trigger Explosive
**Functionality:** Explodes when activated by switch
**Godot Implementation:**
- Signal connection to switches
- Explosion Area2D on trigger
- Particle/sprite animation
- Queue_free() after explosion

#### Impact Explosive
**Functionality:** Explodes on impact or drop
**Godot Implementation:**
- RigidBody2D contact detection
- Velocity threshold trigger
- Impact force calculation
- Collision-based activation

#### Missile
**Functionality:** Flying explosive projectile
**Godot Implementation:**
- RigidBody2D with thrust
- Homing/straight trajectory
- Explosion on contact
- Trail particle effect

#### Large Spikes
**Functionality:** 3x3 grid of deadly spikes
**Godot Implementation:**
- TileMap or multiple Area2D
- Instant death collision
- Static/animated sprites
- Collision shape array

#### Small Spikes
**Functionality:** Single deadly spike
**Godot Implementation:**
- Area2D with small collision
- Instant death trigger
- Sprite2D visual
- Point damage zone

#### Plasma Ball
**Functionality:** Dissolving deadly projectile
**Godot Implementation:**
- Area2D collision
- Instant death on contact
- Fade-out animation
- Self-destruct timer

---

### Racing

#### Start Gate
**Functionality:** Race starting point with timer
**Godot Implementation:**
- Area2D for race begin
- Timer/countdown UI
- Starting gun signal
- Race state initialization

#### Finish Gate
**Functionality:** Race endpoint with placement scoring
**Godot Implementation:**
- Area2D for race end
- Placement tracking (1st-4th)
- Score calculation
- Leaderboard update

---

## 4. Audio Objects

### Music
**Functionality:** Licensed music tracks with trigger options
**Godot Implementation:**
- AudioStreamPlayer for BGM
- Autoplay/trigger activation
- Fade in/out with Tween
- Start time offset

### Music - Interactive
**Functionality:** Layered music with instrument volume control
**Godot Implementation:**
- Multiple AudioStreamPlayer tracks
- Bus volume control per layer
- Sync playback position
- Dynamic mixing

### Sound Objects
**Functionality:** Categorized sound effects with pitch/variation
**Godot Implementation:**
- AudioStreamPlayer2D
- Pitch_scale property
- RandomNumberGenerator for variation
- Category-based organization

---

## 5. Background

### Story Backgrounds
**Functionality:** Themed background environments
**Godot Implementation:**
- ParallaxBackground/ParallaxLayer
- Multiple Sprite2D layers
- Ambient sound loops
- Decorative elements

### DLC Backgrounds
**Functionality:** Special licensed theme backgrounds
**Godot Implementation:**
- Same as Story Backgrounds
- Custom artwork assets
- Unique particle effects
- Themed audio

---

## 6. Global Controls

### Lighting
**Functionality:** Time of day simulation (sun position)
**Godot Implementation:**
- DirectionalLight2D rotation
- CanvasModulate color shift
- Shadow angle changes
- Sky gradient colors

### Darkness
**Functionality:** Overall brightness level
**Godot Implementation:**
- CanvasModulate with black modulation
- Ambient light intensity
- Light2D for torches/lamps
- Visibility range control

### Fogginess
**Functionality:** Visibility range and fog density
**Godot Implementation:**
- BackBufferCopy for blur
- CanvasLayer with shader
- Distance-based alpha fade
- CPUParticles2D fog clouds

### Fog Color
**Functionality:** Custom fog color tinting
**Godot Implementation:**
- CanvasModulate color property
- Shader uniform color
- ColorRect overlay
- Blend mode adjustments

### Color Correction
**Functionality:** Screen color grading (B&W, sepia, contrast)
**Godot Implementation:**
- ColorRect with shader
- Post-process effects
- Saturation/contrast uniforms
- LUT (Look-Up Table) textures
