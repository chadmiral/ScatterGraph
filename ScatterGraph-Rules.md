# ScatterGraph Rules & Parameters

ScatterGraph is a procedural decorator placement system for Roblox. Biome definitions are node graphs stored under `ReplicatedStorage.ScatterGraphs`. A Roblox Studio plugin evaluates those graphs inside tagged **scatter volumes** and places cloned geometry into `Workspace.ScatterGraphInstances`.

This document describes every node type, attribute, wire, tag, and volume setting the backend recognizes.

---

## How evaluation works

1. The plugin finds all instances tagged **`ScatterGraphVolume`**.
2. Volumes with **`Enabled`** = `true` are grouped by the biome graph they link to (see [Scatter volume](#scatter-volume)), and each group is evaluated **once** for all of its volumes (see [Overlapping volumes](#overlapping-volumes)).
3. The ground the group covers settles the [grid](#the-grid) that fields and textures are measured onto for the whole evaluation, before any node runs.
4. It finds children of the graph root with **`NodeType`** = **`Output`** and evaluates each one.
5. **`Output`** nodes follow **`ObjectValue`** wires to terminal **`PlaceGeometryOnPoints`** nodes.
6. Each node walks upstream through **`Points`** wires until it reaches a source **`ScatterPoints`** node. The rule being evaluated and the grid go down with the call, so every node in a chain sees them.
7. Points pass through optional filters (exclusion volumes, terrain snap, slope/material filters) before geometry is cloned.

**Registered node types** (the `NodeType` attribute must match exactly):

| `NodeType` | Implementation |
|------------|----------------|
| `Output` | Entry point; fans out to placement rules |
| `ScatterPoints` | Generates initial point cloud |
| `ScatterPointsAroundPoints` | Expands each upstream point into a local cluster |
| `SnapPointsToTerrain` | Raycasts to terrain; filters by slope and material |
| `MaterialSDF2D` | Measures how far every spot of ground under the volumes is from named terrain materials, seen from above |
| `SDFThreshold2D` | Cuts a distance field at a distance, giving a density texture that is white beyond it and black within |
| `NoiseTexture2D` | Fills a density texture with Perlin noise, to break a scatter up in soft patches |
| `Number` | Holds one number for other nodes to read |
| `Reroute` | Hands on whatever is wired into it, so a wire can be routed around the canvas |
| `PlaceGeometryOnPoints` | Clones and places asset geometry at each point |

The biome root model uses **`NodeType`** = **`ScatterGraph`**. It is a container only and is not evaluated directly.

---

## Graph structure

### Biome root

| Property | Value |
|----------|-------|
| Instance type | `Model` (e.g. `DesertScatterGraph`) |
| **`NodeType`** | **`ScatterGraph`** |
| Location | Typically `ReplicatedStorage.ScatterGraphs.<Name>` |

### Output registry

| Property | Value |
|----------|-------|
| Child name | `Output` |
| Instance type | `Model` |
| **`NodeType`** | **`Output`** |
| Children | One **`ObjectValue`** per placement rule |

Each **`ObjectValue`** under **`Output`**:

| Property | Value |
|----------|-------|
| Name | Same as the rule (e.g. `Cypress_Tree_A`) |
| **`NodeType`** | **`OutputNode`** |
| **`Value`** | References that rule's terminal **`PlaceGeometryOnPoints`** node |

### Per-rule folder

Each rule is a **`Folder`** (same name as its **`Output`** entry) containing the node chain for that rule. Nodes are linked by **`ObjectValue`** children named **`Points`**.

The folder is an organising convention, not something evaluation depends on: nodes are reached by following wires, so a node may sit anywhere under the biome root. Nodes added from the Graph View are parented to the root directly, since a node built by hand does not belong to a rule until something is wired to it.

### Wires

| Wire name | Instance type | **`NodeType`** | **`Value`** |
|-----------|---------------|----------------|-------------|
| `Points` | `ObjectValue` | `Points` | Upstream node that feeds this node |
| `Asset` | `ObjectValue` (on `PlaceGeometryOnPoints` only) | `Asset` | In-scene template to clone (optional) |

**`Points`** is an edge between two nodes, and is a port on the canvas. **`Asset`** is a reference into the scene, and is a row in the parameter panel.

### Data types

A wire between two nodes carries one of these kinds of thing, and each end of it is a port that takes or gives that kind:

| Data type | What it is | Produced by | Read by | Port colour |
|-----------|------------|-------------|---------|-------------|
| **Points** | A cloud of positions | `ScatterPoints`, `ScatterPointsAroundPoints`, `SnapPointsToTerrain` | `ScatterPointsAroundPoints`, `SnapPointsToTerrain`, `PlaceGeometryOnPoints` | Blue |
| **Instances** | The geometry a rule has placed in the world | `PlaceGeometryOnPoints` | `Output` | Green |
| **SDF Grid 2D** | A shape on the ground measured onto a rectangle of cells as the signed distance to its edge, seen from above | `MaterialSDF2D` | `SDFThreshold2D` | Yellow |
| **Texture 2D** | A greyscale image laid over the ground, read as [how much of a scatter survives where](#density-masking) | `SDFThreshold2D`, `NoiseTexture2D` | `ScatterPoints`, `ScatterPointsAroundPoints`, `SnapPointsToTerrain` | Salmon |
| **Number** | A single value | `Number` | `SDFThreshold2D` | Violet |

A **Number** port left unwired stands at its own default rather than at nothing, so wiring one is a way to make several nodes agree on a value, not a requirement.

[`Reroute`](#reroute) is not in that table because it has no type of its own: it produces whatever is wired into it, and the dot it is drawn as takes that type's colour once something is.

The Graph View draws every port in its type's colour — filled when something is wired to it, a ring of the same colour when nothing is — so what a wire may join reads off the canvas. A wire dropped on a slot that takes another type is refused with a warning, and one dropped on the body of a node goes to whichever of its slots takes what is being dragged. A node type the plugin does not recognise has no type, is drawn grey, and has no slots.

Which node produces which type, and which slots each one reads, lives in `src/shared/ScatterGraph/DataTypes.luau`. Evaluation itself does not check types: a node reads its input by wire name and takes whatever the upstream node returned.

### The grid

Two kinds of thing are measured over the ground being scattered — a [distance field](#materialsdf2d) and a [density texture](#density-masking) — and both sit on the same kind of grid, so it is described once here.

A grid is **flat**. Scattering is a top-down business — points are spread across a footprint and dropped onto the ground — so what a mask needs to know is how far a spot is from water or from sand *as seen from above*, and a rectangle of cells answers that at a fraction of the cost of a box of them. A grid has no height at all: sampling one reads the point's X and Z and ignores its Y, so a point 500 studs in the air reads exactly what the ground below it reads.

**What ground a grid covers is the scatter volumes' to decide, not the node's.** The plugin works the rectangle out from the group's bounds before the first **`Output`** node is reached, and it goes down the graph with the evaluation, so everything measured in one evaluation covers the same ground. How finely that rectangle is divided is the one part a measuring node asks for, through its **`VoxelSize`**. Two grids at different cell sizes are still read the same way — by sampling a world position rather than an index — so they need not line up cell for cell.

Values are held at cell centres and read **between** them, so a grid answers smoothly rather than in steps of a cell. That matters more for a texture than a field: it is why a hard black-and-white edge in a texture thins a scatter through a cell-wide band of greys instead of cutting a straight line across it.

| Part of the grid | How it is decided |
|------------------|-------------------|
| **Extent** | The X and Z bounds of every volume in the group, snapped out to whole cells and padded by two of them, so a grid carries on a little way past the ground being scattered. A coarse grid therefore reaches further out than a fine one over the same volumes. |
| **Cell size** | The measuring node's **`VoxelSize`**, **4 studs** by default — terrain's own grid, the finest a material boundary is known to. Doubles to 8, 16 and so on until the grid fits the ten million cells one may hold, warning when it does. |
| **Origin** | The world X and Z of the centre of cell `(0, 0)`, half a cell in from the corner of that rectangle. |
| **Resolution** | Cell counts across X and Z, at least 2. |

A 160 × 160 stud footprint comes out as 45 × 45 cells at the default 4 studs. The two 389 × 749 stud footprints of a biome evaluated as one group come out as 194 × 285 cells of 4 studs — 55,290 of them, about 200 ms to measure a field over, most of which is reading the terrain rather than measuring anything. At 1 stud the same ground is 762 × 1123 cells and about 530 ms, so a fine field over a whole biome is affordable in a way a 3D one never was.

Because the count grows as the square of the ground rather than the cube, the ten million cell ceiling is a backstop against a mistyped parameter rather than a limit real work meets: it is twelve thousand studs square at 4 studs.

Cell size buys accuracy near a boundary, not shape: the material is only ever known per 4-stud terrain voxel, so a finer field divides the same blocky patches more finely rather than finding a truer edge. A texture is cheaper again — a noise texture over that whole biome is about 10 ms, since there is no terrain to read.

`GridLayout2D.layoutFor` in `src/shared/ScatterGraph/GridLayout2D.luau` is what settles it.

**Typical chains:**

```
ScatterPoints → SnapPointsToTerrain → PlaceGeometryOnPoints
```

With clustering:

```
ScatterPoints → ScatterPointsAroundPoints → SnapPointsToTerrain → PlaceGeometryOnPoints
```

Follow **`Points`** wires from the terminal node backward. **`ScatterPoints`** is always the source (no incoming **`Points`** wire).

---

## Scatter volume

Volumes define *where* a biome graph is evaluated. Tag the volume part with **`ScatterGraphVolume`**.

| Attribute / child | Type | Required | Description |
|-------------------|------|----------|-------------|
| **`Enabled`** | `boolean` | Yes (for evaluation) | When `true`, the graph is evaluated for this volume when the plugin runs. |
| **`BiomeDefinitionAssetID`** | `number` | One of these | Published asset ID of the biome graph package. Loaded via `InsertService` once per group of volumes sharing the ID; first child is used as the graph. |
| Child **`ObjectValue`** | `ObjectValue` | One of these | **`Value`** points directly at the biome root model (in-place definition). Used when **`BiomeDefinitionAssetID`** is not set. |

The volume's **`Size`**, **`CFrame`**, and **shape** define the scatter bounds. Point generation covers the volume's footprint — the ground area a downward ray can hit it from — and terrain raycasts span the volume's world-space Y extent. A point survives only if the terrain it lands on is inside the volume, so the volume's shape bounds placement vertically as well as horizontally.

### Volume shapes

Every Roblox part shape is supported, for scatter volumes and exclusion volumes alike:

| Shape | Region |
|-------|--------|
| `Block` | The whole box. |
| `Ball` | A sphere at the center. Roblox never stretches a ball into an ellipsoid, so the diameter is the **smallest** **`Size`** component. |
| `Cylinder` | A circular cylinder whose axis runs along the part's **X** axis; the diameter is the smaller of **`Size.Y`** and **`Size.Z`**. Rotate it 90° to stand it up as a circular region. |
| `Wedge` | The box cut by the slanted face, which is full height along the **+Z** edge and tapers to nothing at **-Z**. |
| `CornerWedge` | The box cut by two slanted faces meeting over the **(+X, -Z)** corner. |

`MeshPart`s, unions, and other parts fall back to their bounding box.

Volumes may be rotated arbitrarily; the footprint and the raycast extent are computed in world space, so a tilted volume still scatters over the ground area it actually covers.

### Overlapping volumes

Volumes that link to the **same** biome definition form a group and are evaluated together as a single region. Where they overlap, the result is a **union**, not a double dose:

- The sampling lattice is anchored to the world origin and each cell's jitter is derived from that cell's index, so every volume in a group agrees on where the points in a shared cell go. Each cell contributes at most one point no matter how many volumes cover it.
- Density in an overlap therefore matches density anywhere else, and a region built from several overlapping volumes is indistinguishable from the same region built as one volume. Splitting a volume in two, with the halves overlapping, does not change the result.
- Intersection avoidance spans the whole group: with **`AvoidIntersections`** set, a tree in one volume and a boulder in another will not overlap (see [Cross-branch intersection avoidance](#cross-branch-intersection-avoidance)).
- Volumes in a group do not have to touch. Scattered patches sharing one definition cost nothing for the empty space between them.

Two volumes linked to **different** definitions remain independent: both scatter over the shared ground, and their instances can intersect. That is how two different biomes are meant to interleave along a border.

Grouping is by the *definition the volume links to*, so:

| Volumes link via | Grouped together? |
|------------------|-------------------|
| Child **`ObjectValue`** → the same graph `Model` | Yes |
| The same **`BiomeDefinitionAssetID`** | Yes (the asset is loaded once for the group) |
| **`ObjectValue`** → two separate copies of the same graph | No — separate definitions |

---

## Node reference

### ScatterPoints

Generates an initial point cloud using a simplified Poisson-disc grid: one jittered point per grid cell, with cell size derived from **`Spacing`**. The lattice is anchored to the world origin and each cell's jitter is derived from **`Seed`** together with that cell's index, so the same cell always yields the same point — this is what lets overlapping volumes in a group union cleanly. Cells whose ground column misses every volume in the group are discarded.

| Attribute | Type | Required | Description |
|-----------|------|----------|-------------|
| **`NodeType`** | `string` | Yes | **`ScatterPoints`** |
| **`Seed`** | `number` | Yes | Random seed. Controls jitter within each grid cell, and seeds the stream that downstream nodes draw from for scale, rotation, and the slope filter. |
| **`Spacing`** | `number` | Yes | Target minimum distance between points (studs). Cell size = `Spacing / sqrt(2)`. |

| Wire | Required | Description |
|------|----------|-------------|
| **`Density`** | No | A [density texture](#density-masking) thinning the candidates out. Nothing wired keeps them all. |

**Output:** `{ Vector3 }` — world-space positions, at the middle of the volume group's vertical span until something snaps them.

---

### ScatterPointsAroundPoints

For each point from upstream, generates up to **`Count`** additional points in an annulus between **`InnerRadius`** and **`OuterRadius`** (horizontal XZ offset from the seed). Uses its own **`Seed`** for deterministic randomness.

| Attribute | Type | Required | Description |
|-----------|------|----------|-------------|
| **`NodeType`** | `string` | Yes | **`ScatterPointsAroundPoints`** |
| **`Seed`** | `number` | Yes | Random seed for cluster offsets. |
| **`InnerRadius`** | `number` | Yes | Minimum horizontal distance from seed (studs). Use `0` for a filled disc. |
| **`OuterRadius`** | `number` | Yes | Maximum horizontal distance from seed (studs). Must be ≥ **`InnerRadius`**. |
| **`Count`** | `number` | Yes | Number of offset points generated **per upstream seed**. |

| Wire | Required | Description |
|------|----------|-------------|
| **`Points`** | Yes | Upstream node (typically **`ScatterPoints`**). |
| **`Density`** | No | A [density texture](#density-masking) thinning the cluster points out. Nothing wired keeps them all. |

**Output:** `{ Vector3 }` — cluster offset points only (does **not** pass through upstream seed positions; generates **`Count`** new points per upstream seed).

**Note:** Upstream points are collected from all **`Points`** wires. [Exclusion volumes](#exclusion-volumes) are applied before clustering. Offsets that land outside the volume's footprint are dropped, so clusters seeded near an edge do not spill past it — expect fewer than **`Count`** points per seed there.

---

### SnapPointsToTerrain

Raycasts each point downward through the scatter volume to find terrain. Snaps surviving points to the hit position, discarding any hit that falls outside the volume's shape. Filters by slope probability and material denylist.

| Attribute | Type | Required | Description |
|-----------|------|----------|-------------|
| **`NodeType`** | `string` | Yes | **`SnapPointsToTerrain`** |
| **`MaterialFilter`** | `string` | Yes | Comma-separated **denylist** of terrain material names (e.g. `Water,Ice,Snow`). Points landing on listed materials are rejected. |
| **`SlopeFilter`** | `NumberSequence` | Yes | Maps terrain slope to a **keep probability**. Time **0** = flat ground, **1** = vertical. A point is kept when `random() < evaluated probability`. |

**Slope calculation:** `terrainSlope = clamp(1 - normal · up, 0, 1)`.

| Wire | Required | Description |
|------|----------|-------------|
| **`Points`** | Yes | Upstream node providing candidate positions. |
| **`Density`** | No | A [density texture](#density-masking) thinning the snapped points out. Nothing wired keeps them all. |

**Output:** `{ Vector3 }` — terrain-snapped, filtered positions, all inside the volume.

The texture is read **after** the snap, over what survived the snap's own filters. Since a texture is flat that is the same answer as reading it before, over fewer points.

**Example `SlopeFilter` values:**

- Flat-only (trees): `NumberSequence.new(1, 0)` — full density on flat ground, none on vertical.
- Boulders on slopes: `NumberSequence.new(1, 0.5)` — partial density retained on steep terrain.
- Mid-slope peak: use multiple keypoints so density peaks between flat and vertical.

Set via `SetAttribute("SlopeFilter", NumberSequence.new(...))` in Studio so the attribute serializes correctly.

---

### MaterialSDF2D

Source node. Measures where named terrain materials are into a flat signed distance field over the ground being scattered: every cell holds how far it is from the nearest ground whose surface is one of those materials, negative on the material itself. Wire it into [`SDFThreshold2D`](#sdfthreshold2d) to turn that into ground a rule may or may not plant on.

Materials are named as strings, which is what keeps the node place-agnostic: a graph is shared between places and may point at nothing in one of them, but `Water` means water everywhere.

| Attribute | Type | Required | Description |
|-----------|------|----------|-------------|
| **`NodeType`** | `string` | Yes | **`MaterialSDF2D`** |
| **`Materials`** | `string` | Yes | Comma-separated list of terrain material names to measure from (e.g. `Water,Sand`). Spelled as in the Terrain editor. Surrounding spaces and repeats are ignored; a name that is not a material is warned about and skipped. |
| **`VoxelSize`** | `number` | No | The edge of one cell of the field, in studs. Defaults to **`4`**, the grid terrain keeps material on. Smaller sharpens the distances around the material; larger is coarser and cheaper. A value of zero or less falls back to 4 with a warning. |

**Inputs:** None (source node).

**Output:** an [SDF Grid 2D](#data-types) — `{ origin, voxelSize, resolution, dimensions, distances, source }`, where `origin`, `resolution` and `dimensions` are `Vector2`s of world X and Z. Read cell by cell, or at a world position with `GridLayout2D.read(grid, grid.distances, worldPoint)`, which ignores the point's Y.

**The field:**

- **What a spot's material is.** What is seen looking straight down at it: the topmost terrain voxel with anything in it, within the height the volumes span. That is the same surface **`SnapPointsToTerrain`** casts its rays onto, so a mask and the points it masks agree about the ground. Water reads as water because water is what is on top there, and the ground under a lake is not sand as far as this node is concerned — nor is buried material anything at all. In the Elwynn biome, `Ground` is the surface of 1,814 of 55,290 cells while `Grass` is 46,041 of them.
- **Where it is measured.** Over [the ground the scatter volumes set](#the-grid), which the node does not choose, divided into cells of its own **`VoxelSize`**, which it does.
- **What the numbers mean.** Zero on the boundary between the material and everything else, negative on it, positive off it, in studs. Distances are measured from cell centre to cell centre and then brought half a cell in, which puts the zero crossing on the edges the two sides share. A voxel one tenth full of water is water: anything keeping clear of a shoreline should keep clear of all of it. A cell counts as the material if any part of a terrain voxel of it lies in there — so a coarse cell takes in several terrain columns and a fine one is one of several taking in the same column — which spreads the material out rather than dropping it.
- **When there is none of it.** A material that is nowhere on the surface in range leaves every cell reading as astronomically far away, not zero, so a texture cut from it comes out white everywhere and thins nothing — rather than black everywhere, which would remove the scatter entirely.

**Cost:** the terrain is read a patch at a time, top down, and each patch stops being read as soon as every column in it has found its surface — so nothing below the ground is read at all. The distances are then worked out with a separable exact distance transform, two passes over the cells rather than a search around each one. Measuring the Elwynn biome's field takes about 200 ms, nearly all of it reading terrain. The field is measured once per evaluation however many nodes read it.

**Read by:** [`SDFThreshold2D`](#sdfthreshold2d).

---

### SDFThreshold2D

Cuts a [distance field](#materialsdf2d) at a distance and hands back what is left as a [density texture](#density-masking): **white** where the field reads at or beyond **`Distance`**, **black** where it reads short of it. This is what turns *how far is this spot from the road* into *may anything grow here*.

| Attribute | Type | Required | Description |
|-----------|------|----------|-------------|
| **`NodeType`** | `string` | Yes | **`SDFThreshold2D`** |

No attributes of its own: both of its parameters arrive over wires.

| Wire | Required | Description |
|------|----------|-------------|
| **`SDF`** | Yes | The field to cut. Nothing wired produces nothing, with a warning. |
| **`Distance`** | No | Where to cut it, in studs. Defaults to `0`. Wire a [`Number`](#number) node here to set it, or to cut several rules at one distance. |

Since a field reads negative on the material it measures:

| `Distance` | White (kept) where |
|------------|--------------------|
| `0` | Anywhere off the material |
| `12` | At least 12 studs clear of it |
| `-8` | Off it, and up to 8 studs onto it |

**Output:** a [Texture 2D](#data-types) on the field's own cells, so nothing is resampled and the edge lands exactly where the field puts it. Reading between cells then leaves that edge soft by about a cell, which dithers the boundary instead of drawing a line across the scatter — of 5,506 candidates over the Elwynn biome, a few hundred fall in that band.

A field naming a material the place does not have reads as astronomically far away everywhere, so cutting it gives an all-white texture that thins nothing, rather than a black one that removes everything.

---

### NoiseTexture2D

Source node. Fills a [density texture](#density-masking) with Perlin noise: soft blotches over the ground, mid grey on average, running to white where the noise peaks and black where it troughs. Wired into a **`Density`** slot it breaks a scatter up the way ground cover actually grows — thick in places, thin in others, with no edge anywhere — which even spacing and a uniform count cannot do on their own.

| Attribute | Type | Required | Description |
|-----------|------|----------|-------------|
| **`NodeType`** | `string` | Yes | **`NoiseTexture2D`** |
| **`Scale`** | `number` | No | How wide one blotch is, in studs. Defaults to **`64`**, about a clearing. Larger is broader patchiness; smaller breaks the scatter up more finely, down to about the cell size. A value below `1` is read as `1`, with a warning. |
| **`Phase`** | `number` | No | Which slice of the noise this is. Defaults to `0`. Two nodes at the same **`Scale`** and different **`Phase`**s give unrelated patterns over the same ground. |
| **`VoxelSize`** | `number` | No | The edge of one cell, in studs. Defaults to **`4`**. Only worth changing for a **`Scale`** near it, where the pattern is finer than the cells can carry. |

**Inputs:** None (source node).

**Output:** a [Texture 2D](#data-types) over [the ground the scatter volumes set](#the-grid).

**The noise:**

- **It is a function of position, not a picture.** The same ground gives the same blotches every run, so moving a volume moves the scatter through the pattern rather than reshuffling it, and two rules reading one node thin out together.
- **Mid grey on average.** Over the Elwynn biome the mean is 0.503 and about half of any scatter survives it. Roughly a tenth of the ground is dark enough to be nearly bare and a tenth pale enough to be nearly untouched.
- **It clips at the ends.** Roblox's noise mostly keeps within half a unit of zero but overshoots on a few cells in a hundred, and those clamp to solid black or white — which is what puts the occasional bare clearing and solid thicket in an otherwise probabilistic texture.

---

### Number

Source node. Holds one number and hands it to everything wired to it. There is nothing to compute; the node exists so that a figure several rules depend on — a threshold distance, typically — is one thing in one place rather than the same number typed into each of them. Change the node and every rule reading it changes together.

| Attribute | Type | Required | Description |
|-----------|------|----------|-------------|
| **`NodeType`** | `string` | Yes | **`Number`** |
| **`Value`** | `number` | Yes | The number handed to every wire out of this node. |

**Inputs:** None (source node).

**Output:** a [Number](#data-types). A node with no **`Value`** set produces nothing and warns; a slot reading it falls back to its own default.

---

### Reroute

A bend in a wire. It reads one thing and hands that same thing on, and it exists for the canvas rather than the evaluation: a field or a texture shared by a dozen rules otherwise reaches them as a dozen wires drawn straight across everything between, and a reroute or two lets those run where you put them.

| Attribute | Type | Required | Description |
|-----------|------|----------|-------------|
| **`NodeType`** | `string` | Yes | **`Reroute`** |

Nothing to set: what it passes on is whatever is wired into it.

| Wire | Required | Description |
|------|----------|-------------|
| **`Input`** | Yes | The node whose output this one hands on. Nothing wired means nothing to pass on, and it warns. |

**Output:** whatever reached it, of whatever type — so a reroute takes the colour of what it is carrying.

**On the canvas it is a dot, not a card.** A reroute is drawn the size of a port, in the colour of what it carries: solid once something is wired into it and a ring around a hole while nothing is, which is how an empty port looks and how you can tell an unwired one at a glance. Both of its ends are that one point, so the wire arriving and the wires leaving meet there and the pair reads as a single bent wire. A card keeps its two gestures apart by geometry — the body is dragged to move it, the port on its edge to wire it — and a dot has no room for both, so it grows one: **drag the dot to move it, and point at it to bring up an output port on its right edge, which is what you drag from to wire it into another node.** The port goes away again when you point elsewhere, so a reroute at rest is just a dot. A wire is dropped onto it the same way as onto any other node. There is nowhere on a dot to print a name, so hovering one names it and says what it is carrying.

**It has no type until it carries one.** An empty reroute is grey and accepts anything; from the moment something is wired in, it reads as that type and a wire of another type is turned down like any other mismatch. To re-aim one at a different kind of thing, break its input wire first — and check what it feeds still makes sense, since those wires were drawn when it carried something else.

**It changes nothing about the evaluation.** A chain with reroutes in it produces exactly what the same chain without them would, point for point:

- Reroutes chain, so a wire may bend as many times as the layout needs.
- The rule a placement is recorded under travels through one, so a reroute may stand between a terminal node and the [Output registry](#output-registry) without costing that rule its identity. The registry entry keeps its own name either way, and that name is still what identifies the rule.
- It is deliberately not cached. A wire read by two nodes evaluates what is behind it twice, and a reroute that only did it once would be a reroute that changed the answer.
- A reroute wired into a loop by hand hangs an evaluation exactly as any other loop does. The canvas refuses to draw one, and the windows themselves are loop-safe, so a graph in that state can still be opened and unpicked.

---

### PlaceGeometryOnPoints

Terminal node. Clones a template model at each input point, applies scale, optional color tint, and rotation, and parents instances to `Workspace.ScatterGraphInstances`.

| Attribute | Type | Required | Description |
|-----------|------|----------|-------------|
| **`NodeType`** | `string` | Yes | **`PlaceGeometryOnPoints`** |
| **`GeometryAssetID`** | `number` | One of these | Published asset ID. Loaded via `InsertService`; first child is the template. Ignored when **`Asset`** wire is set. |
| **`ScaleRange`** | `Vector2` | No | Uniform scale range: **`X`** = minimum, **`Y`** = maximum. Sampled as `X + random() * (Y - X)`. Defaults to `1` when omitted. |
| **`RotationType`** | `string` | No | How to rotate each instance (see below). |
| **`ColorRange`** | `ColorSequence` | No | Random tint applied to `SurfaceAppearance.Color` on descendant `MeshPart`s. Sampled with `random()` as the sequence time. |
| **`AvoidIntersections`** | `boolean` | No | When `true`, this rule participates in order-independent intersection avoidance: an instance is dropped if its circular footprint would overlap another rule's footprint. Defaults to `false`. See [Cross-branch intersection avoidance](#cross-branch-intersection-avoidance). |
| **`Radius`** | `number` | No | Horizontal footprint radius (studs) used for intersection tests. Two placements overlap when the distance between their centers is less than the sum of their radii. Defaults to `5`. |
| **`Priority`** | `number` | No | Tiebreak when two avoiding rules contest the same space — the **lower** **`Priority`** number is kept (`0` is the highest priority). Defaults to `0`. Has no effect unless **`AvoidIntersections`** is set. |

| Wire | Required | Description |
|------|----------|-------------|
| **`Points`** | Yes | Upstream node providing placement positions. |
| **`Asset`** | No | In-scene template instance to clone. Takes precedence over **`GeometryAssetID`**. |

**`RotationType` values:**

| Value | Behavior |
|-------|----------|
| `"Random"` | Random rotation on all three axes. |
| `"UpAxis"` | Random yaw around world Y. |
| *( omitted or other )* | No rotation applied beyond placement pivot. |

**Color tinting:** Applied to `SurfaceAppearance` descendants of each `MeshPart`. Parts tagged **`NoTint`** (CollectionService) are skipped.

---

### Output

Graph entry point. Evaluates every child **`ObjectValue`** (each pointing at a rule's **`PlaceGeometryOnPoints`** node).

| Attribute | Type | Required | Description |
|-----------|------|----------|-------------|
| **`NodeType`** | `string` | Yes | **`Output`** |

| Child | Type | Description |
|-------|------|-------------|
| **`ObjectValue`** (one per rule) | `ObjectValue` | **`NodeType`** = **`OutputNode`**. **`Value`** → terminal **`PlaceGeometryOnPoints`** for that rule. |

**Output:** `nil` (side effect is placed instances).

Branch evaluation order does **not** affect placement results. Intersection avoidance is resolved globally after every branch has run (see [Cross-branch intersection avoidance](#cross-branch-intersection-avoidance)).

---

## Exclusion volumes

A part tagged **`ExclusionVolume`** keeps points out of itself. Any point inside it is discarded, using the part's actual [shape](#volume-shapes) and orientation, so a rotated wedge excludes a wedge and not its bounding box.

Exclusion volumes live in the place, not in the graph: a graph is shared between places, while what has to be kept clear — a road, a building footprint, a plaza — belongs to the place it was built in. Nothing in a graph refers to an exclusion volume, and adding or moving one changes no graph.

### Which rules a volume excludes

By default, all of them. A volume can instead name the rules it applies to, by giving it **`ObjectValue`** children whose **`Value`** points at an **`Output`** registry entry — the `ObjectValue` under a graph's `Output` node that names one rule:

| Children of the volume | Excludes |
|------------------------|----------|
| None | Every rule of every graph in the place |
| One `ObjectValue` → an `Output` entry | That rule only |
| Several `ObjectValue`s | Each of the rules they point at |

The children's names are not read, only their **`Value`**s, so name them whatever reads best in the Explorer.

```
Workspace
└── PlazaExclusion            [ExclusionVolume]
    ├── NoTrees      ObjectValue → ScatterGraphs.Forest.Output.Trees
    └── NoBoulders   ObjectValue → ScatterGraphs.Forest.Output.Boulders
```

That volume keeps trees and boulders off the plaza while leaving every other rule — grass, say — to grow across it.

A child pointing at nothing, or at anything that is not an `Output` entry, excludes nothing and warns once per run saying so. It does **not** fall back to excluding everything: a half-finished aim is not a licence to clear the place.

### When exclusion is applied

Within a rule, exclusion applies to the whole chain rather than only its last node. Points are tested in **`ScatterPointsAroundPoints`** (before clustering), **`SnapPointsToTerrain`** (before the raycast), and **`PlaceGeometryOnPoints`** (before placing), so a point inside an excluded volume is gone whichever of them a rule happens to use.

Because a rule's identity comes from the `Output` entry that names it, a node shared between two rules is excluded according to whichever rule is being evaluated at the time — so sharing a **`ScatterPoints`** node between a targeted rule and an untargeted one behaves as each rule asks.

---

## Density masking

Where an exclusion volume is a shape in the place that keeps points out of itself, a density is a **greyscale image wired into a node**, and it decides how much of a scatter survives where. It lives in the graph and travels with it: nothing about a texture points at anything in a place, so a density that keeps trees off the roads works in any place that has roads.

**`ScatterPoints`**, **`ScatterPointsAroundPoints`** and **`SnapPointsToTerrain`** each take one input port for it:

| Port | Type | Default | What it is |
|------|------|---------|------------|
| **`Density`** | [Texture 2D](#data-types) | *(nothing wired — nothing thinned)* | The chance a candidate standing there survives. |

**The rule:** each candidate is read in the texture at its own `x, z`, and survives with that chance.

| Where the texture reads | Chance of removal |
|-------------------------|-------------------|
| **White** (`1`) | none — every candidate stays |
| **Mid grey** (`0.5`) | half |
| **Black** (`0`) | certain — nothing stays |

This is a **thinning rather than a cut**: except at pure black and white, whether a given point survives is a roll, so a texture shapes a scatter instead of clipping it. That is also why two textures can be applied one after another, on two nodes in a chain, and the result is what multiplying them would give.

The roll is the same one the [slope filter](#snappointstoterrain) makes, drawn from the stream the rule's **`Seed`** started, so a graph run twice over unchanged ground thins out the same way twice.

**Where in a chain you read a texture barely matters,** since a texture is flat: a candidate is measured by the ground it stands over, whether or not anything has snapped it there yet.

| Reading it on | Tests | Worth knowing |
|---------------|-------|---------------|
| **`ScatterPoints`** | Every candidate the rule starts with | Cheapest: candidates it removes are never raycast by a later snap |
| **`SnapPointsToTerrain`** | What survived the snap's own material and slope filters | Same answer as reading it earlier, over fewer points |
| **`ScatterPointsAroundPoints`** | The cluster points, not the seeds they grew from | A seed may stand on black ground and still spread points onto white |

An empty **`Density`** port thins nothing, and so does one wired to a node that does not produce a texture — that warns and carries on. **Nothing wired keeps everything**, which is the opposite of what an all-black texture does, so a mistake fails towards a scatter that is too dense rather than one that has vanished.

Each texture is built once per evaluation however many rules read it.

**Making one:** [`SDFThreshold2D`](#sdfthreshold2d) cuts a [distance field](#materialsdf2d) into black and white — keep off the water, hold a clearing around the road. [`NoiseTexture2D`](#noisetexture2d) fills one with soft blotches to break a scatter up. Wiring both, on two nodes of one chain, gives patchy ground cover that also respects the roads.

---

## Cross-branch intersection avoidance

Each **`Output`** rule (branch) is normally placed independently, so a tree from one branch and a boulder from another can overlap. To prevent this without restructuring the graph, set **`AvoidIntersections`** = `true` on the **`PlaceGeometryOnPoints`** node of each rule that should not overlap others. **No ordering, wiring, or extra nodes are required** — just mark the nodes.

**How it works:**

- During a graph evaluation — which covers every volume in a [group](#overlapping-volumes) — an **occupancy store** tracks the circular footprint (center + **`Radius`**) of every placed instance.
- Rules **without** **`AvoidIntersections`** are placed immediately and always kept ("solid").
- Rules **with** **`AvoidIntersections`** are **deferred**: their instances become *candidates*.
- After **all** branches have been evaluated, candidates are resolved in one pass, in a fixed global order — **lowest** **`Priority`** number first (`0` = highest priority), ties broken by a deterministic spatial key. A candidate is kept if its footprint circle does not overlap any already-kept footprint; otherwise it is discarded.

Because resolution runs after the whole graph is evaluated and processes candidates in a fixed order, **the result is identical no matter what order the branches were evaluated in.**

**Semantics:**

- **Order-independent.** Marking the nodes is enough; you never need to reason about which branch, or which volume, runs first.
- **Scoped to one biome definition.** The store covers all volumes in a group, but not other biomes. Two different definitions overlapping on the same ground can still intersect each other.
- **Cross-branch only.** A rule's own instances (including cluster nodes) never reject one another, so intended clustering is preserved.
- **Marked yields to unmarked.** An **`AvoidIntersections`** rule always avoids a non-avoiding rule (the latter is placed unconditionally).
- **`Priority` decides contested space.** When two avoiding rules compete for the same spot, the **lower** **`Priority`** number is kept (`0` is the highest priority). Equal priority is resolved by a stable spatial tiebreak (still deterministic).
- **Radius test.** Overlap uses each rule's **`Radius`** as a horizontal footprint circle; two placements clash when the distance between centers is less than the sum of their radii. Registration uses **`Radius`** even for non-avoiding rules, so opt-in rules avoid them too.
- **Density trade-off.** Discarded placements are skipped, so an avoiding rule may end up sparser where it competes with denser geometry.

**Example — trees and boulders never intersect:**

| Rule | `AvoidIntersections` | `Radius` | `Priority` |
|------|----------------------|----------|------------|
| `Cypress_Tree_A` | `true` | `8` | `0` |
| `Boulder_Large` | `true` | `4` | `10` |

Both rules avoid each other regardless of evaluation order. Where a tree and a boulder would overlap, the tree (lower **`Priority`** number = higher priority) is kept and the boulder is dropped. If you only mark one rule (e.g. only `Boulder_Large`), boulders avoid trees but trees are placed freely — still order-independent.

---

## Persisting hand edits

Placed instances can be edited by hand after a run and keep those edits through the next one. You do not have to mark anything: move, rotate, scale, retint, restructure or delete a placed instance, and the system notices and leaves your work alone.

**How a placement remembers itself.** Every instance the placer creates is stamped with where it came from and what it looked like:

| Attribute | Type | Written on | Meaning |
|-----------|------|------------|---------|
| **`ScatterGraph`** | `string` | Placed instance | Which graph placed it (the graph's name, or `Asset:<id>` for an asset-loaded graph). |
| **`ScatterRule`** | `string` | Placed & promoted instance | Which rule placed it — the rule's **`RuleId`** if it has one, otherwise its name. |
| **`ScatterOrigin`** | `Vector3` | Placed & promoted instance | The point the placer used. Only **X** and **Z** identify the placement; the height is shown for legibility but never matched on. |
| **`ScatterOccurrence`** | `number` | Placed & promoted instance | Tells apart two placements of one rule that share an X and Z (ordered by height, then placement order). |
| **`ScatterRadius`** | `number` | Placed & promoted instance | The footprint radius, so a promoted instance still contests space the way its rule does. |
| **`ScatterStamp`** | `number` | Placed instance | A fingerprint folded from the pivot, scale, and every descendant's shape and look. Removed on promotion. |

Height is deliberately never part of a placement's identity: it comes from the terrain raycast for a snapped rule and from the volume group's vertical span for a floating one, and both move for reasons that are not edits (sculpting terrain, moving or resizing a volume). Matching on **X** and **Z** alone means those legitimate shifts re-place cleanly, while a hand nudge — height included — is still caught by the stamp.

**The deep stamp.** **`ScatterStamp`** is a single number folded from the instance's pivot and `Model` scale and, for every descendant in order, its class and name and — for a `BasePart` — its transform *relative to the pivot*, size, colour, material, transparency and anchored state, and for a `SurfaceAppearance` its colour. Relative transforms mean dragging or turning the whole model is caught by the pivot term while nudging one part inside it is caught by that part's term. Values are rounded to a thousandth before folding, so a save and reload does not read as an edit.

**The ledger.** A run records what it placed so an absence can be told from a point that was never placed. Records live in **`Workspace.ScatterGraphRecords/<graph>/<rule>`** as a `StringValue` (base64 of packed entries; the readable name is the rule, the durable **`RuleId`** is an attribute). Each entry is in one of three states:

- **placed** — the system owns a live instance here.
- **promoted** — a hand-edited instance now claims this point; the system keeps clear of it.
- **removed** — the author deleted it; never place here again.

Only **placed** entries are ever pruned. **promoted** and **removed** entries persist across runs, so raising a volume onto a new plane, or nudging one sideways and back, never resurrects a prop you threw away.

**What a run does.** Before placing, the run sweeps every tagged instance: an untouched one is destroyed and re-placed as before; an edited one is **promoted**. During placement, a point that is claimed or removed is skipped — while still drawing the same random values, so deleting one prop never restyles the ones scattered after it — and a placed point whose instance has vanished is recognised as a deletion and tombstoned. At the end, stale placed entries are pruned and the ledgers are written.

**Promotion** untags **`ScatterGraphInstance`**, tags **`ScatterGraphPromoted`**, and reparents the instance into a flat **`Workspace.ScatterGraphPromoted`** folder, keeping its **`ScatterRule`** and **`ScatterOrigin`**. A promoted instance keeps asserting its point on every later run, and is registered into that run's occupancy at its **current** position, so **`AvoidIntersections`** rules keep clear of where you actually put it. Delete a promoted instance and its point flips to **removed**.

**Commands** (Spreadsheet View rule ribbon):

- **Promote Selection** — lifts the instances currently selected in Studio out of the system for good, whatever their stamp says. The escape hatch for an edit the stamp cannot see, or a prop you want held even though it is untouched.
- **Forget Edits** — discards the selected rule's records and its promotions and removes the instances it had promoted, so the rule regenerates from nothing on the next run.

**Clear Instances** destroys every placed instance and drops the ledgers' **placed** entries (keeping **promoted** and **removed**), so the next run does not misread the cleared props as hand deletions. Promoted instances are left untouched.

A rule that loses a large fraction of its placements between runs — usually a folder deleted by hand rather than props edited one at a time — is called out with a warning suggesting **Forget Edits**. Instances placed before this feature existed carry no stamp and are destroyed on the first run after it lands, a clean reset with no false tombstones.

---

## CollectionService tags

| Tag | Applied to | Effect |
|-----|------------|--------|
| **`ScatterGraphVolume`** | `BasePart` | Volume evaluated by the plugin. Any [shape](#volume-shapes). Volumes sharing a biome definition are [unioned](#overlapping-volumes). |
| **`ExclusionVolume`** | `BasePart` | Points inside this part are removed, using the part's actual [shape](#volume-shapes) and orientation. Applies to every rule, or only to the rules its **`ObjectValue`** children point at — see [Exclusion volumes](#exclusion-volumes). Tested in **`ScatterPointsAroundPoints`**, **`SnapPointsToTerrain`**, and **`PlaceGeometryOnPoints`**. |
| **`NoTint`** | `MeshPart` | Skips color tinting from **`ColorRange`** on that part. |
| **`ScatterGraphInstance`** | Placed instance | Applied to every instance the placer creates; marks it as the system's to sweep and re-place. Removed when the instance is promoted. |
| **`ScatterGraphPromoted`** | Promoted instance | A hand-edited instance lifted out of the system (see [Persisting hand edits](#persisting-hand-edits)). Its point is kept clear on every run; deleting it retires the point for good. |

---

## Plugin workspace requirements

| Instance | Location | Purpose |
|----------|----------|---------|
| **`ScatterGraphInstances`** | `Workspace` | Created automatically if missing. All placed geometry is parented here, in a `<graph>/<rule>` subfolder per rule. |
| **`ScatterGraphs`** | `ReplicatedStorage` | Created automatically if missing. Holds biome graph definitions. |
| **`ScatterGraphRecords`** | `Workspace` | Created on the first run that places anything. One `StringValue` per rule, holding the ledger that persists hand edits (see [Persisting hand edits](#persisting-hand-edits)). |
| **`ScatterGraphPromoted`** | `Workspace` | Created on the first promotion. A flat folder holding every instance the author edited and the system stepped away from. |
| **`Terrain`** | `Workspace` | Raycast target for **`SnapPointsToTerrain`**. |

---

## Quick reference: all attributes

| Node | Attributes |
|------|------------|
| Biome root | `NodeType` = `ScatterGraph` |
| `Output` | `NodeType` = `Output` |
| `Output` registry entry | `NodeType` = `OutputNode` |
| `ScatterPoints` | `NodeType`, `Seed`, `Spacing` |
| `ScatterPointsAroundPoints` | `NodeType`, `Seed`, `InnerRadius`, `OuterRadius`, `Count` |
| `SnapPointsToTerrain` | `NodeType`, `MaterialFilter`, `SlopeFilter` |
| `MaterialSDF2D` | `NodeType`, `Materials`, `VoxelSize` |
| `SDFThreshold2D` | `NodeType` *(both parameters are wires)* |
| `NoiseTexture2D` | `NodeType`, `Scale`, `Phase`, `VoxelSize` |
| `Number` | `NodeType`, `Value` |
| `Reroute` | `NodeType` *(its one input is a wire)* |
| `PlaceGeometryOnPoints` | `NodeType`, `GeometryAssetID`, `ScaleRange`, `RotationType`, `ColorRange`, `AvoidIntersections`, `Radius`, `Priority`, `RuleId` |
| `Output` registry entry | `NodeType` = `OutputNode` |
| Scatter volume | `Enabled`, `BiomeDefinitionAssetID` |
| Exclusion volume | *(no attributes; `ObjectValue` children aim it — see [Exclusion volumes](#exclusion-volumes))* |
| Wire: `Points` | `NodeType` = `Points` |
| Wire: `Asset` | `NodeType` = `Asset` |
| Wire: `Density` | `NodeType` = `Texture2D` |
| Wire: `Input` | `NodeType` = whatever the [reroute](#reroute) carries |
| Wire: `SDF` | `NodeType` = `SDFGrid2D` |
| Wire: `Distance` | `NodeType` = `Number` |

A **`PlaceGeometryOnPoints`** node added from a rule template also carries
**`RuleId`** (a `string` GUID), the rule's durable identity for the records that
persist hand edits (see [Persisting hand edits](#persisting-hand-edits)). It lets
those records survive renaming the node. Rules without one fall back to their
name. Placed instances additionally carry `ScatterGraph`, `ScatterRule`,
`ScatterOrigin`, `ScatterOccurrence`, `ScatterRadius` and `ScatterStamp`; those
are written by the placer, not authored by hand.

Any node may also carry **`GraphPosition`** (a `Vector2`), which is where the
Graph View canvas last saw it dragged to. It is written only by dragging a node
there, is ignored by evaluation, and is hidden from both windows' parameter
lists. Deleting it just returns the node to the automatic column layout.

---

## Source layout

| Path | Role |
|------|------|
| `src/shared/ScatterGraph/ScatterGraph.client.lua` | Plugin entry; volume grouping, node registry, evaluation loop |
| `src/shared/ScatterGraph/ScatterGraphHelpers.luau` | Terrain snap, clustering, placement, exclusion zones |
| `src/shared/ScatterGraph/GridLayout2D.luau` | Where the flat [grid](#the-grid) every field and texture of one evaluation shares sits over the ground, and how a value is read back out of one at a world position |
| `src/shared/ScatterGraph/SDFGrid2D.luau` | A shape on the ground measured onto that grid as the distance to it, from cells already marked off as `MaterialSDF2D` marks them |
| `src/shared/ScatterGraph/Texture2D.luau` | A greyscale image on that grid, filled cell by cell or from a function of position, and read as a [density](#density-masking) |
| `src/shared/ScatterGraph/RulesWindow.luau` | "Spreadsheet View" dock widget: lists the place's graphs and the chosen graph's outputs, edits the attributes and Asset wire of the nodes feeding each one, and adds or deletes both graphs and rules |
| `src/shared/ScatterGraph/GraphView.luau` | "Graph View" dock widget: one graph as a canvas of wired nodes that can be added, moved, rewired and deleted, beside the parameters of the selected node |
| `src/shared/ScatterGraph/Graphs.luau` | Which graphs the place holds, and which one the Studio selection names for the Graph View button to open |
| `src/shared/ScatterGraph/NodeInspector.luau` | The attribute panel both windows use: a row and a suitable editor for every value of every node it is given |
| `src/shared/ScatterGraph/GraphUi.luau` | Shared window furniture: theme colours, the tooltip and dropdown Roblox does not provide, and the undo recording every edit runs inside |
| `src/shared/ScatterGraph/AttributeSchema.luau` | Which values each node type takes, which editor it gets, and the description shown on hover |
| `src/shared/ScatterGraph/DataTypes.luau` | What travels along a wire: which node produces or reads points or instances, and the colour each type is drawn in |
| `src/shared/ScatterGraph/SequenceEditor.luau` | Popout keypoint editor for the `SlopeFilter` and `ColorRange` sequences, with a colour picker for the latter |
| `src/shared/ScatterGraph/VolumeShape.luau` | Per-shape volume geometry: containment, footprint, and raycast extent for every part shape |
| `src/shared/ScatterGraph/VolumeGroup.luau` | The volumes sharing one biome definition, queried as a single unioned region |
| `src/shared/ScatterGraph/OccupancyStore.luau` | Spatial hash of placed footprint circles (center + `Radius`) for cross-branch intersection avoidance |
| `src/shared/ScatterGraph/PlacementStamp.luau` | The deep fingerprint one placed instance folds down to, for telling an untouched placement from a hand-edited one |
| `src/shared/ScatterGraph/PlacementLedger.luau` | The durable per-rule record of placed, promoted and removed points that persists hand edits across runs |
| `src/shared/ScatterGraph/Nodes/` | Per-node evaluation logic |
