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
| **SDF Grid** | A shape measured onto a box of voxels as the signed distance to its surface | *(nothing yet)* | *(nothing yet)* | Yellow |

**SDF Grid** is declared and coloured but not yet carried by any wire: `SDFGrid.luau` builds such a field from a part, and the type is reserved for the node that will hand one to another node.

The Graph View draws every port in its type's colour — filled when something is wired to it, a ring of the same colour when nothing is — so what a wire may join reads off the canvas. A wire dropped on a slot that takes another type is refused with a warning, and one dropped on the body of a node goes to whichever of its slots takes what is being dragged. A node type the plugin does not recognise has no type, is drawn grey, and has no slots.

Which node produces which type, and which slots each one reads, lives in `src/shared/ScatterGraph/DataTypes.luau`. Evaluation itself does not check types: a node reads its input by wire name and takes whatever the upstream node returned.

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
| `PlaceGeometryOnPoints` | `NodeType`, `GeometryAssetID`, `ScaleRange`, `RotationType`, `ColorRange`, `AvoidIntersections`, `Radius`, `Priority`, `RuleId` |
| `Output` registry entry | `NodeType` = `OutputNode` |
| Scatter volume | `Enabled`, `BiomeDefinitionAssetID` |
| Exclusion volume | *(no attributes; `ObjectValue` children aim it — see [Exclusion volumes](#exclusion-volumes))* |
| Wire: `Points` | `NodeType` = `Points` |
| Wire: `Asset` | `NodeType` = `Asset` |

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
| `src/shared/ScatterGraph/SDFGrid.luau` | A part's surface measured onto a box of voxels as the distance to it, and how a point is read back out of one. Not yet used by any node |
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
