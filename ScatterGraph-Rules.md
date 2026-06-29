# ScatterGraph Rules & Parameters

ScatterGraph is a procedural decorator placement system for Roblox. Biome definitions are node graphs stored under `ReplicatedStorage.ScatterGraphs`. A Roblox Studio plugin evaluates those graphs inside tagged **scatter volumes** and places cloned geometry into `Workspace.ScatterGraphInstances`.

This document describes every node type, attribute, wire, tag, and volume setting the backend recognizes.

---

## How evaluation works

1. The plugin finds all instances tagged **`ScatterGraphVolume`**.
2. For each volume with **`Enabled`** = `true`, it loads the linked biome graph (see [Scatter volume](#scatter-volume)).
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
| **`BiomeDefinitionAssetID`** | `number` | One of these | Published asset ID of the biome graph package. Loaded via `InsertService`; first child is used as the graph. |
| Child **`ObjectValue`** | `ObjectValue` | One of these | **`Value`** points directly at the biome root model (in-place definition). Used when **`BiomeDefinitionAssetID`** is not set. |

The volume's **`Size`** and **`CFrame`** define the scatter bounds. Point generation uses the volume's X/Z footprint; terrain raycasts span the volume's Y extent.

---

## Node reference

### ScatterPoints

Generates an initial point cloud using a simplified Poisson-disc grid: one jittered point per grid cell, with cell size derived from **`Spacing`**. Points are placed on the volume floor (Y = 0 in volume local space) and transformed to world space.

| Attribute | Type | Required | Description |
|-----------|------|----------|-------------|
| **`NodeType`** | `string` | Yes | **`ScatterPoints`** |
| **`Seed`** | `number` | Yes | Random seed passed to `math.randomseed`. Controls jitter within each grid cell. |
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

**Note:** Upstream points are collected from all **`Points`** wires. Exclusion volumes are applied before clustering.

---

### SnapPointsToTerrain

Raycasts each point downward through the scatter volume to find terrain. Snaps surviving points to the hit position. Filters by slope probability and material denylist.

| Attribute | Type | Required | Description |
|-----------|------|----------|-------------|
| **`NodeType`** | `string` | Yes | **`SnapPointsToTerrain`** |
| **`MaterialFilter`** | `string` | Yes | Comma-separated **denylist** of terrain material names (e.g. `Water,Ice,Snow`). Points landing on listed materials are rejected. |
| **`SlopeFilter`** | `NumberSequence` | Yes | Maps terrain slope to a **keep probability**. Time **0** = flat ground, **1** = vertical. A point is kept when `random() < evaluated probability`. |

**Slope calculation:** `terrainSlope = clamp(1 - normal · up, 0, 1)`.

| Wire | Required | Description |
|------|----------|-------------|
| **`Points`** | Yes | Upstream node providing candidate positions. |

**Output:** `{ Vector3 }` — terrain-snapped, filtered positions.

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

---

## CollectionService tags

| Tag | Applied to | Effect |
|-----|------------|--------|
| **`ScatterGraphVolume`** | `Part` | Volume evaluated by the plugin. |
| **`ExclusionVolume`** | `Part` | Points inside this part's axis-aligned bounds (in the part's object space) are removed. Applied after upstream evaluation in **`ScatterPointsAroundPoints`**, **`SnapPointsToTerrain`**, and **`PlaceGeometryOnPoints`**. |
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
| `PlaceGeometryOnPoints` | `NodeType`, `GeometryAssetID`, `ScaleRange`, `RotationType`, `ColorRange` |
| Scatter volume | `Enabled`, `BiomeDefinitionAssetID` |
| Wire: `Points` | `NodeType` = `Points` |
| Wire: `Asset` | `NodeType` = `Asset` |

---

## Source layout

| Path | Role |
|------|------|
| `src/shared/ScatterGraph/ScatterGraph.client.lua` | Plugin entry; volume iteration, node registry, evaluation loop |
| `src/shared/ScatterGraph/ScatterGraphHelpers.luau` | Terrain snap, clustering, placement, exclusion zones |
| `src/shared/ScatterGraph/Nodes/` | Per-node evaluation logic |
