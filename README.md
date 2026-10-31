# 🌧️ Godot 2D Weather Particles

![Godot Version](https://img.shields.io/badge/Godot-4.3%2B-blue?logo=godot-engine)
![License](https://img.shields.io/badge/License-MIT-green.svg)

A complete, drag-and-drop 2D rain particle system for **Godot 4**. 

Drop a single node into your scene and instantly get beautiful, slanted rain that realistically collides with your TileMaps and StaticBodies. It automatically spawns crisp splash droplets upon impact and builds everything entirely at runtime—no messy scene trees required.

## ✨ Features

* **One Node Setup:** All particles, splashes, and colliders are generated via code at runtime. Nothing is saved to your scene file.
* **Real SDF Collision:** Utilizes Godot 4.3+'s 2D Signed Distance Field (SDF) collision for accurate particle impacts.
* **Dynamic Splashes:** Uses GPU sub-emitters to spawn bouncing droplets exactly where the rain hits the ground.
* **Auto-Detecting Colliders:** Automatically finds `TileMapLayer`, `TileMap`, `StaticBody2D`, and `Area2D` nodes and generates `LightOccluder2D` nodes on the fly as the camera moves.
* **Weather Presets:** Includes Light Rain, Rain, Heavy Rain, and Storm presets.
* **Customizable:** Easily tweak density, fall angle, colors, and intensity via the Inspector or through code.
* **Smooth Transitions:** Includes built-in `fade_in()` and `stop()` methods for seamless weather changes.

---

## 🚀 Installation & Usage

1. Download `weather_particles.gd` (or the source file from this repo) and place it anywhere in your project.
2. In your scene, add a new `Node2D` and attach the script to it.
3. **Important:** Ensure your `Camera2D` is set up, as the rain follows the camera by default.
4. Hit Play!

### Quick Code Example

```gdscript
extends Node2D

func _ready():
    # Create and add the weather node
    var weather = WeatherParticles.new()
    add_child(weather)
    
    # Set a preset and customize it
    weather.preset = WeatherParticles.Preset.STORM
    weather.custom_direction = true
    weather.fall_angle = 25.0 # Slant to the right
    
    # Fade the rain in over 3 seconds
    weather.fade_in(3.0)

func _on_boss_fight_start():
    # Ramp down the rain over 2 seconds
    $Weather.stop(2.0)
```

---

## ⚙️ How Collision Works

This script does not use standard `PhysicsBody2D` nodes for the rain. Instead, it scans your level and generates `LightOccluder2D` polygons with `sdf_collision = true` enabled.

To tell the rain what to collide with, the script will automatically detect:
* `TileMapLayer` or `TileMap` (as long as the TileSet has physics polygons).
* `CollisionShape2D` or `CollisionPolygon2D` whose parent is a `StaticBody2D` or `Area2D`.

**Custom Groups:**
* Add any node to the `rain_collider` group to force it to collide.
* Add any node to the `rain_ignore` group to skip it.

---

## ⚠️ Important Requirements & Pro-Tips

> [!WARNING]
> **Renderer Requirement for Real Splashes**  
> Real splashes (sub-emitter at collision) require **Godot 4.3 or newer** running on the **Forward+** or **Mobile** renderer. If you use the Compatibility renderer, the script automatically switches to fake splashes (they will spawn near the bottom of the screen).

> [!IMPORTANT]
> **Project Settings for Edge Coverage**  
> By default, Godot's SDF area only covers the exact screen size. If your rain has a strong slant (drift), drops on the edges might not collide.  
> **Fix:** Go to **Project > Project Settings > Rendering > 2D > SDF > Oversize** and set it to **150%** or **200%**. (You must restart the Godot editor for this to take effect).

### Tuning Tips (Inspector)

| Property | Recommendation |
| :--- | :--- |
| **Collider Depth** | Because rain moves incredibly fast, a 0-thickness collider will cause drops to "tunnel" through the floor. The script enforces a minimum depth of `32px`, but **96px** is highly recommended for storms. |
| **Collider Lift** | If splashes look like they are sinking into the ground, increase this property. It moves the invisible collision surface up slightly to match the exact top of your tiles. |
| **Spawn Margin** | If you can see rain "popping" into existence at the top of the screen, increase this value to spawn drops higher up. |

---

## 📄 License

This project is licensed under the MIT License. You are free to use it, modify it, and include it in both personal and commercial projects.
