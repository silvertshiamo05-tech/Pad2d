# Pad2D: Inochi2D for iPad

Pad2D makes and plays [Inochi2D](https://github.com/Inochi2D/inochi2d) puppets (`.inp` files and Inochi Creator `.inx` projects) natively on iPadOS. You can rig a model from a layered PSD on the iPad itself, then test it with face tracking. It renders with Metal and supports face tracking, physics and touch control. It's tuned for the iPad 10th generation (A14, 4 GB RAM).

Its runtime is a **Swift port of the Inochi2D 0.8 runtime**, the version Inochi Creator and Inochi Session use today. CI checks it against the original D code on every push (see [Verification](#verification)).

![Aka and Midori at rest and with the head turned, rendered from Pad2D's draw list](docs/preview.png)

*Sample models Aka and Midori by seagetch (CC BY 4.0), rendered from Pad2D's draw list.*

> Pad2D is an independent, unofficial project and isn't affiliated with the Inochi2D Project. Inochi2D is © the Inochi2D Project, BSD 2-Clause licensed; see `Packages/Inochi2DKit/LICENSE`.

## Editor

Tap **Edit** on any model, or **New from PSD** in the library. The editor follows Inochi Creator 0.8's layout and modes. A hardware keyboard works, and **Ctrl / Shift / Alt** toggles on the toolbar stand in for one.

- **Model mode:**
  - Tap or lasso parts to select them, and long-press for overlapping parts.
  - **Move, scale and rotate handles**, plus arrow-key nudge.
  - The node tree has multi-select, drag-and-drop reparenting, copy/paste, and Creator's context menu (lock to root, recalculate origin, convert node types).
  - The inspector covers transform, snapping, z-sort, blend mode, tint and screen tint, masks, the 3 texture slots (albedo/emission/bump), mesh groups, physics, cameras and automation.
- **Mesh mode:**
  - Point, edge, grid and lasso tools.
  - Horizontal/vertical mirroring and auto-connect, with a live triangulation preview.
  - **Auto Mesh** (contour or grid presets) for one part or many, copying a mesh from another part, and a local undo stack.
- **Rigging:**
  - Create 1D/2D parameters or use presets, group them, and set up flip pairs.
  - Arm a parameter, then deform with the **points**, **brush** (circle, double threshold or rectangle; drag or flow), **path** (spline define/transform) or **lasso** tools.
  - Keypoint actions: copy, paste, paste-flipped, mirror, auto-flip, swap, reset, unset, extrapolate and mirrored autofill.
  - You can also convert to 2D, split a parameter, edit its axis points, change its merge mode, and transfer deformation between parts.
- **Animation mode:** create animations (fps, lead-in/out, additive and weight), key parameters, scrub the timeline and play back with Creator's interpolation.
- **Test mode:** play the model with physics, automation and face tracking, with bindings from ARKit blend shapes to parameters.
- **Tools and files:**
  - Named undo history, autosave with crash recovery, and recent projects.
  - PSD import and **PSD merge**, which updates an existing rig from a changed PSD.
  - Texture premultiply and color bleed, and node ID repair.
- **Export:**
  - `.inx` and `.inp`, with an atlas packer that has scale, padding and watermark options.
  - PNG/JPEG/TGA images and videos (H.264, or HEVC with transparency) rendered through a Camera node.

Files saved by Pad2D load in the original Inochi2D 0.8.7 and behave the same (checked in CI).

## Features

- **Opens any Inochi2D 0.8 model:**
  - Part, Composite, MeshGroup (including dynamic deformation), SimplePhysics, AnimatedPart
  - Masks and dodge masks
  - Parameters with Nearest/Linear/Cubic interpolation
  - Sine automation
- **All 19 Inochi2D blend modes**, computed in the shader with framebuffer fetch. Overlay, Soft Light, Color Burn and the other "advanced" modes look the same as in Inochi Creator on a desktop GPU.
- **Face tracking** with the front camera through ARKit. It works on the iPad 10th gen even without Face ID hardware, and nothing leaves the device. Head turn, nod and tilt, eye blinks, gaze, mouth open and smile are mapped to the model's parameters automatically, and you can adjust or invert each mapping.
- **Follow finger mode:** the model looks wherever you touch.
- **Pendulum physics** for hair and clothes, plus idle breathing and blinking.
- **Parameter panel** with sliders and XY pads, and a presentation mode with green or blue screen backgrounds for screen recording.
- **Sample models** Aka and Midori by seagetch (CC BY 4.0) are bundled.

### Gestures

| Gesture | Action |
| --- | --- |
| Pinch | Zoom |
| Two-finger drag | Pan |
| One-finger drag | Pan, or steer the head in *Follow finger* mode |
| Double tap | Reset the view |

## Built for 4 GB iPads

- Textures are decoded one at a time into GPU-only (private) Metal textures with mipmaps, and CPU copies are freed straight away. If a model would need more than about 1/6 of RAM (~680 MB on a 4 GB iPad), all its textures are scaled down evenly and the app tells you.
- The model file is memory-mapped, so its pages can be dropped by the OS.
- Deformation runs on the CPU in about 1–2 ms per frame for the sample models. Geometry goes to the GPU through a ring of three reused buffers.
- Face tracking uses ARKit's smallest video format.

## Install on iPad without a computer

GitHub Actions builds the app on a Mac in the cloud on every push.

1. Open **Releases → Latest build** on this repo from your phone or iPad and download `Pad2D-unsigned.ipa`. It's also attached to each run under **Actions** as an artifact.
2. iPadOS only installs signed apps, so sign it with one of:
   - **SideStore** (free, uses your Apple ID, re-sign every 7 days). The first setup needs a computer once to create a pairing file.
   - **An Apple Developer account** ($99/year). The workflow can be extended to sign and upload to TestFlight, and then you install from the TestFlight app with no computer at all.
3. Put `.inp`/`.inx` models in the Files app, then use **Import** in Pad2D or *Share → Pad2D*.

## Project layout

```
Packages/Inochi2DKit/   Swift port of the Inochi2D 0.8 runtime (no UIKit/Metal; tested on Linux and macOS)
  INPFile.swift         .inp/.inx container reader
  Node.swift            Node, Drawable, Part, Composite
  MeshGroup.swift       Mesh group deformation of child meshes
  Parameter.swift       Parameters, value and deformation bindings
  SimplePhysics.swift   Pendulum and spring-pendulum physics (RK4)
  Puppet.swift          Update loop, draw order, sine automation
  DrawList.swift        Renderer-agnostic draw commands
  Tracking.swift        Tracking-to-parameter mapping
  TGA.swift             Texture decoder for Inochi Creator's TGA textures
  Writer.swift          Saving .inp/.inx
  Editing.swift         Editing operations (nodes, meshes, parameters, bindings)
  Reinterpolate.swift   Inochi Creator's keypoint fill-in
  PSD.swift             PSD reader and importer
  MeshGenerator.swift   Auto-mesh and Delaunay triangulation
App/Sources/            iPad app (SwiftUI + Metal + ARKit); the editor is in App/Sources/Editor
Tools/Verify/           Compares the port with the original Inochi2D 0.8.7
project.yml             XcodeGen project definition
```

## Verification

`Tools/Verify/run.sh` checks the port against the original Inochi2D 0.8.7 in two ways:

1. **Geometry.** It builds Inochi2D 0.8.7 (renderless) and compares every drawn vertex of both sample models, in draw order. That covers the rest pose, parameter poses (2D head, body roll, mouth, blink, breath) and up to 600 frames of physics. The port matches to within 0.01 px.
2. **Pixels.** It renders the models with Inochi2D's own OpenGL renderer (headless, on Mesa) and with a CPU renderer that follows the same rules as Pad2D's Metal shaders (draw list, masks, composites, blend modes, mipmaps). The average difference is under 1.5/255.

CI runs both on every push.

```sh
cd Packages/Inochi2DKit && swift test   # unit tests
Tools/Verify/run.sh                     # needs ldc2/dub, swift, python3, Mesa EGL
```

## Not yet supported

- Inochi2D 0.9 files (`TRNSRTS2`). 0.9 is still being rewritten upstream, and its current code can't animate models yet.
- Emission/bump rendering, scene lighting and post-processing. The texture slots are kept and saved, but not drawn yet.
- Krita (`.kra`) import, and importing an `.inp` or a folder of images as a new project.
- VMC/OpenSeeFace network tracking.
- Playing a model's animations from the viewer screen (they play in the editor's Animation and Test modes).
