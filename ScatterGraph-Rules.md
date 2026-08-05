# ScatterGraph Rules & Parameters

ScatterGraph is a procedural decorator placement system for Roblox. Biome definitions are node graphs stored under `ReplicatedStorage.ScatterGraphs`. A Roblox Studio plugin evaluates those graphs inside tagged **scatter volumes** and places cloned geometry into `Workspace.ScatterGraphInstances`.

This document describes every node type, attribute, wire, tag, and volume setting the backend recognizes.

---

## How evaluation works

1. The plugin finds all instances tagged **`ScatterGraphVolume`**.
2. Volumes with **`Enabled`** = `true` are grouped by the biome graph they link to (see [Scatter volume](#scatter-volume)), and each group is evaluated **once** for all of its volumes (see [Overlapping volumes](#overlapping-volumes)).
3. It finds children of the graph root with **`NodeType`** = **`Output`** and evaluates each one.
4. **`Output`** nodes follow **`ObjectValue`** wires to terminal **`PlaceGeometryOnPoints`** nodes.
5. Each node walks upstream through **`Points`** wires until it reaches a source **`ScatterPoints`** node.
6. Points pass through optional filters (exclusion volumes, terrain snap, slope/material filters) before geometry is cloned.

**Registered node types** (the `NodeType` attribute must match exactly):

| `NodeType` | Implementation |
|------------|----------------|
| `Output` | Entry point; fans out to placement rules |
| `ScatterPoints` | Generates initial point cloud |
| `ScatterPointsAroundPoints` | Expands each upstream point into a local cluster |
| `SnapPointsToTerrain` | Raycasts to terrain; filters by slope and material |
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

### Wires

| Wire name | Instance type | **`NodeType`** | **`Value`** |
|-----------|---------------|----------------|-------------|
| `Points` | `ObjectValue` | `Points` | Upstream node that feeds this node |
| `Asset` | `ObjectValue` (on `PlaceGeometryOnPoints` only) | `Asset` | In-scene template to clone (optional) |

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

**Inputs:** None (source node).

**Output:** `{ Vector3 }` — world-space positions.

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

**Output:** `{ Vector3 }` — cluster offset points only (does **not** pass through upstream seed positions; generates **`Count`** new points per upstream seed).

**Note:** Upstream points are collected from all **`Points`** wires. Exclusion volumes are applied before clustering. Offsets that land outside the volume's footprint are dropped, so clusters seeded near an edge do not spill past it — expect fewer than **`Count`** points per seed there.

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

**Output:** `{ Vector3 }` — terrain-snapped, filtered positions, all inside the volume.

**Example `SlopeFilter` values:**

- Flat-only (trees): `NumberSequence.new(1, 0)` — full density on flat ground, none on vertical.
- Boulders on slopes: `NumberSequence.new(1, 0.5)` — partial density retained on steep terrain.
- Mid-slope peak: use multiple keypoints so density peaks between flat and vertical.

Set via `SetAttribute("SlopeFilter", NumberSequence.new(...))` in Studio so the attribute serializes correctly.

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

## CollectionService tags

| Tag | Applied to | Effect |
|-----|------------|--------|
| **`ScatterGraphVolume`** | `BasePart` | Volume evaluated by the plugin. Any [shape](#volume-shapes). Volumes sharing a biome definition are [unioned](#overlapping-volumes). |
| **`ExclusionVolume`** | `BasePart` | Points inside this part are removed, using the part's actual [shape](#volume-shapes) and orientation. Applied after upstream evaluation in **`ScatterPointsAroundPoints`**, **`SnapPointsToTerrain`**, and **`PlaceGeometryOnPoints`**. |
| **`NoTint`** | `MeshPart` | Skips color tinting from **`ColorRange`** on that part. |

---

## Plugin workspace requirements

| Instance | Location | Purpose |
|----------|----------|---------|
| **`ScatterGraphInstances`** | `Workspace` | Created automatically if missing. All placed geometry is parented here. |
| **`ScatterGraphs`** | `ReplicatedStorage` | Created automatically if missing. Holds biome graph definitions. |
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
| `PlaceGeometryOnPoints` | `NodeType`, `GeometryAssetID`, `ScaleRange`, `RotationType`, `ColorRange`, `AvoidIntersections`, `Radius`, `Priority` |
| `Output` registry entry | `NodeType` = `OutputNode` |
| Scatter volume | `Enabled`, `BiomeDefinitionAssetID` |
| Wire: `Points` | `NodeType` = `Points` |
| Wire: `Asset` | `NodeType` = `Asset` |

---

## Source layout

| Path | Role |
|------|------|
| `src/shared/ScatterGraph/ScatterGraph.client.lua` | Plugin entry; volume grouping, node registry, evaluation loop |
| `src/shared/ScatterGraph/ScatterGraphHelpers.luau` | Terrain snap, clustering, placement, exclusion zones |
| `src/shared/ScatterGraph/VolumeShape.luau` | Per-shape volume geometry: containment, footprint, and raycast extent for every part shape |
| `src/shared/ScatterGraph/VolumeGroup.luau` | The volumes sharing one biome definition, queried as a single unioned region |
| `src/shared/ScatterGraph/OccupancyStore.luau` | Spatial hash of placed footprint circles (center + `Radius`) for cross-branch intersection avoidance |
| `src/shared/ScatterGraph/Nodes/` | Per-node evaluation logic |
