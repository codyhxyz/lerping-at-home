# Baked Minecraft worlds: file format

A bake turns one save into the files in
`~/Library/Application Support/Lerping/Minecraft/Worlds/<name>/`. This file is
the contract between the bake (Python, `scripts/minecraft-world/`) and the
runtime (Swift loader and Metal tracer). Each owner writes their own section.
All multi-byte values are little endian. No file has a header unless its
section says so; sizes come from `world.json`.

## Volume, light, tints, far field, routes, world.json, world.metal

Owner: VOLUME (`anvil.py`, `bake.py`, `biomecolor.py`, `blocknames.py`, `preview_world.py`).

### Coordinates

The volume is a box of `W x H x D` blocks (`size` in `world.json`, x, y, z).
Texel `(x, y, z)` holds the world block at `origin + (x, y, z)` (`origin` in
`world.json`, world block coordinates, y absolute, so it can be negative).
`W` and `D` are multiples of 16 and `origin.x`, `origin.z` are multiples of 16
(the box is whole chunks). Minecraft's axes: +x east, +y up, +z south.

Linear index of a voxel, used by every 3D file:

```
i = x + W * (y + H * z)
```

The tracer works in volume space: a point `p` in blocks with `0 <= p < size`
is in cell `int3(floor(p))`. Everything in `world.metal` is in volume space.
To convert a world position: `p = world - origin`.

### `blocks.r16`: material and skip distance

`W*H*D` uint16, index `i`. Load as a `texture3d<ushort>` of format `r16Uint`,
width `W`, height `H`, depth `D` (so texel `(x, y, z)` is `read(ushort3(x, y, z))`).

```
ushort v   = blocks.read(ushort3(cell)).r;
uint   mid = v & 0x0FFF;          // material id, 0 = air (and cave_air, void_air)
uint   skip = v >> 12;            // air only: Chebyshev distance to the nearest non-air voxel, 0..15
```

- `mid` indexes the MATERIALS tables (`materials.*`). 4095 ids at most; the
  bake fails if a world needs more.
- `skip` is 0 for every non-air voxel. For an air voxel it is the largest `k`
  (at most 15) such that every voxel in the cube of half-width `k - 1` around
  it is air, i.e. `skip = min(15, min over non-air voxels n of max(|dx|, |dy|, |dz|))`.
  Air with a non-air neighbour (including diagonal) has `skip = 1`. A ray in an
  air cell with skip `k` can advance to the boundary of the cube
  `[cell - (k-1), cell + k]` per axis without missing anything. Voxels
  outside the volume are not considered (the tracer leaves the box there).
- Air that is not inside any 15-cube of non-air reads 15.

### `light.rgba8`: block light and sky light

`W*H*D*4` bytes, index `4*i + channel`, channels r, g, b, a. Load as a
`texture3d<float>` of format `rgba8Unorm` (not `_srgb`; decode yourself as
below). Same dimensions as `blocks.r16`.

```
float4 L = light.sample(linearClamp, (p + 0.5 * n) / float3(size));  // p on a hit face, n its normal
float  sky   = L.a * 15.0;                           // the game's sky light level, 0..15
float  block = max3(L.r, L.g, L.b) * 15.0;           // the game's block light level, 0..15
float3 tint  = block > 0 ? mcFromSRGB(L.rgb / max3(L.r, L.g, L.b)) : 1;  // the light's colour
```

- `a = sky / 15` where `sky` is the game's sky light level (no time of day:
  the look scales it by `mcLightDay` / `mcLightmap`).
- `rgb = (level / 15) * c` per channel, where `level` is the game's block
  light level at that voxel from one colour of source and `c` is that source's
  colour from `table.emission` (sRGB, rescaled so its largest channel is 1).
  When sources of different colours overlap, each channel is the maximum over
  them. So `max3(rgb) * 15` is the game's block light level (exact where one
  colour dominates) and `rgb / max3(rgb)` is the colour, sRGB-encoded.
- A voxel filled by an opaque block (`table.opaque`) holds `(0, 0, 0, 0)`,
  emitters included. Sampling half a block out from a face with linear
  filtering blends the four cells beside the face's corner, which is the
  game's smooth lighting and ambient-occlusion darkening.
- How it is computed (so a look knows what it gets): sky light 15 in every
  cell from the top of the volume down to the first cell whose material has
  `light_filter > 0` or that light cannot enter from above; then both lights
  spread to the 6 neighbours, losing `max(1, light_filter)` of the cell
  entered, never entering an opaque cell, and never crossing a full face of a
  partial block (a stair's back and bottom, a slab's bottom, a path's bottom:
  the game's `getFaceOcclusionShape`, from MATERIALS' per-state face bits), so
  a stair roof keeps a house's lamp light in and the daylight out.
  Block light starts at `emission` level in the emitter's cell. Cells outside
  the box contribute nothing, except that sky light entering the top of the
  box is reduced by anything above the box that `--max-height` cut off
  (column only, no sideways spread there).
- A block MATERIALS cannot draw yet (`unhandled`) still floods its light, in
  white (its colour would come from a texture).
- Checked against the light the game itself stored in the save (`SkyLight` /
  `BlockLight` nibbles, `preview_world.py --compare-save`), one chunk in from
  the box's edges, opaque voxels left out (the game keeps an opaque emitter's
  own level in its cell; the bake stores 0 there, as above): `shared` sky and
  block light 100.00% of cells equal (4.09M and 42k lit cells); `mine` 99.99%
  and 99.97% (the rest are cells lit from outside the box).

### `tints.rgba8`: grass, foliage, water and dry foliage colour per column

Four layers of `W x D` texels, 4 bytes each, layer-major:

```
offset(layer, x, z) = 4 * (x + W * (z + D * layer))   // layer 0 grass, 1 foliage, 2 water, 3 dry foliage
```

Load as a `texture2d_array<float>` of format `rgba8Unorm`, width `W`, height
`D`, 4 slices. Layer index = MATERIALS' tint code - 1 (grass 1, foliage 2,
water 3, dry foliage 4). `rgb` is the colour, sRGB-encoded (decode with
`mcFromSRGB`); `a` is 255, or 0 (and rgb 0) for a column whose chunk the save
does not have (those columns are air). A tinted face multiplies its texture by
it.

How the bake gets it, the client's way (each step checked against the 26.2
classes with javap, and the zoom and swamp noise against the jar's own code at
2000 random positions):

- The biome of a column is the game's `BiomeManager.getBiome` at the column's
  surface (highest non-air block): one of the 8 surrounding 4x4x4 biome cells,
  picked by the seeded jitter, the seed being sha256 of the world seed.
- Its colours: `colormap/grass.png`, `foliage.png`, `dry_foliage.png` at the
  biome's (float) temperature and downfall clamped to 0..1, pixel
  `(int)((1 - downfall * temperature) * 255) * 256 + (int)((1 - temperature) * 255)`,
  or the biome's `grass_color` / `foliage_color` / `dry_foliage_color`
  override; then `grass_color_modifier` (`dark_forest`:
  `((c & 0xFEFEFE) + 0x28340A) >> 1`; `swamp`: `0x4C763C` where the game's
  `BIOME_INFO_NOISE` at `(x, z) * 0.0225` is below -0.1, else `0x6A7039`).
  Water is the biome's `water_color`.
- Blend: the mean of the 8-bit channels over the 5 x 5 columns around (the
  default blend radius 2), integer division, as the client does. One
  difference: each neighbour's biome is taken at its own surface height, where
  the client takes all 25 at the centre column's height (the same except where
  biomes change with height right at the surface).

### `far.rg16` and `far.rgba8`: the horizon

A 2D picture of a wider square around the volume, one texel per block column,
`FW x FD` texels (`far.size` in `world.json`), texel `(i, j)` is the world
column `far.origin + (i, j)` (`far.origin` is x, z). The volume's columns are
inside it. Built from every chunk in the square that the save has finished
(`Status` `minecraft:full`; in a generated save, only inside the square its
`lerping-generate.json` names); columns of missing chunks are marked missing.

`far.rg16`: `FW*FD` pairs of uint16, offset `4 * (i + FW * j)`. Load as
`texture2d<ushort>` `rg16Uint`.

```
ushort2 h = far.read(uint2(i, j)).rg;
// h.r: ground height: world y of the top face of the highest non-air, non-fluid block, minus far.min_y (-64), plus 1
//      -> topY = h.r - 1 + far.min_y;  h.r == 0 means no chunk here (draw nothing / fog)
// h.g: water surface: world y of the top of the highest water or lava block above the ground, same encoding, 0 = dry
```

`far.rgba8`: two layers of `FW x FD` texels, 4 bytes each, layer-major
(`offset = 4 * (i + FW * (j + FD * layer))`). Load as `texture2d_array<float>`
`rgba8Unorm`, 2 slices. sRGB-encoded.

- Layer 0: the ground's colour: `table.map_color` of the top non-fluid block
  times its column tint (grass, foliage, water or dry foliage by
  `table.tint_kind`, same blend as `tints.rgba8`), multiplied in sRGB as the
  game multiplies tints. `a` = 255 where the chunk exists, 0 where missing.
  For a block with random model variants the colour is that of one variant
  (they share their texture).
- Layer 1: the fluid's colour: water's biome water colour times water's map
  colour, or lava's map colour. `a` = 255 where `h.g != 0`, else 0.

### `routes.u16`: walkable loops for mobs

uint16 throughout. A header, a loop table, then points:

```
u16 loopCount, u16 pointCount
loopCount  x { u16 first, u16 count, u16 kind, u16 reserved }   // points [first, first+count)
pointCount x { u16 x, u16 y, u16 z, u16 flags }                  // volume space
```

- A point is a stand position: cell `(x, y, z)` is where a mob's feet are.
  Cell `y - 1` is ground and cells `y` and `y + 1` are passable (both
  defined below).
  Feet stand at `float3(x + 0.5, y + (rise - drop) / 16.0, z + 0.5)` with
  `drop` and `rise` from the flags below.
- Each loop is closed: point `first + count - 1` steps back to `first`.
  Consecutive points differ by exactly 1 in x or in z (never both) and by at
  most 1 in y. A point may repeat: a path loop walks out along each branch of
  the path network and back. So a mob walking a loop at
  speed `v` blocks per second is at `mix(P[k], P[k+1], f)` with
  `k + f = fmod(v * t, count)`; a step with `dy = 1` is a jump.
- `kind`: 0 = village (links the bell, beds and job-site blocks), 1 = path
  (follows path blocks), 2 = open ground (untouched terrain, near the centre).
- `flags` per point: bit 0 = standing on `dirt_path`, bit 1 = standing on
  farmland, bit 2 = beside a waypoint (a bell, bed or job-site block is within
  one block), bit 3 = feet in a door's lower cell (see `MCW_DOORS`: the look
  draws that door open while a mob is in it), bit 12 = swimming (feet in the
  top water cell of a river or lake); bits 4-7 `drop` = `(flags >> 4) & 15`, sixteenths the feet are
  below `y` for what is under them (1 on a path or farmland, 8 on a bottom
  slab, 4 on a bottom stair, half way between its step heights, `16 - 2 *
  (layers - 1)` on snow of 4+ layers); bits 8-11 `rise` = `(flags >> 8) & 15`,
  sixteenths above `y` for thin snow in the feet cell (`2 * (layers - 1)`).
  Other bits are 0.
- Ground: a block MATERIALS calls opaque and not fluid, or one of
  `dirt_path`, `farmland`, ice, glass, `snow_block`, snow of 4+ layers,
  stairs and slabs (feet go on the cell above, so over a bottom slab or the
  low half of a stair they are half a block high).
  Passable: air, plants, torches, rails, carpets, buttons, signs, doors
  (villagers open them), snow of 1-3 layers. The lists are in
  `blocknames.py`. Routes stay inside the volume. They may swim: the top
  water cell of a body of water with air above counts as a stand cell, at a
  cost of 8 a step, so a route swims only to reach something it cannot walk
  to (a house across a river).
- How loops are chosen: with a bell, loops from the bell through up to five
  beds and job sites each (sorted by angle around the bell), along the
  cheapest walk (path blocks cost 1, other ground 3, water 8, a step up 1 more; a
  step up needs head room for a jump unless it lands on a bottom slab or
  stair, which is walked).
  Without one, a walk over each of the largest path networks. Without paths,
  three rings (radius 8, 14, 22) over the largest patch of connected ground
  within 64 blocks of the centre. `world.json` `routes.rule` says which.

The same data is in `world.metal` as constant arrays.

### Places and mobs (`village.py`)

What lives in the world, for a look to run a day by: beds, job sites, bells,
doors, the stops routes make at them, and the save's own mobs. Nothing is
village-only; a world without them has counts of 0. In `world.metal`, every
array has at least one element (zeros) so it compiles; read only below its
count. Same lists, with names and notes, in `world.json` `places` and `mobs`.

```metal
constant int     MCW_BED_COUNT;
constant float4  MCW_BEDS[];      // head half: (x + 0.5, y + 9/16, z + 0.5) of its cell, the mattress top;
                                  //   w = heading from foot to head as mcMobRay takes it (0 +z, pi/2 +x)
constant int     MCW_JOB_COUNT;
constant float4  MCW_JOBS[];      // job-site block: its cell centre; w = the profession it gives:
                                  //   0 armorer (blast furnace), 1 butcher (smoker), 2 cartographer, 3 cleric (brewing stand),
                                  //   4 farmer (composter), 5 fisherman (barrel), 6 fletcher, 7 leatherworker (any cauldron),
                                  //   8 librarian (lectern), 9 mason (stonecutter), 10 shepherd (loom), 11 toolsmith
                                  //   (smithing table), 12 weaponsmith (grindstone)
constant int     MCW_BELL_COUNT;
constant float4  MCW_BELLS[];     // cell centre; w = attachment: 0 floor, 1 ceiling, 2 single wall, 3 double wall
constant int     MCW_STOP_COUNT;
constant ushort4 MCW_STOPS[];     // (route, point index within the route, kind 0 bell / 1 bed / 2 job site, item index)
constant int     MCW_DOOR_COUNT;
constant int4    MCW_DOORS[];     // lower half's cell; w bits: 0-1 facing (0 south, 1 west, 2 north, 3 east, the game's
                                  //   2D order), 2 hinge on the right, 3 open in the save, 4-5 the panel's side when
                                  //   closed, 6-7 its side when open (sides: 0 -z, 1 +x, 2 +z, 3 -x; the panel is 3/16 thick)
constant int     MCW_MOB_COUNT;
constant float4  MCW_MOB_POS[];   // feet, volume space; w = heading as mcMobRay takes it
constant int4    MCW_MOB_INFO[];  // x kind (below); y villager profession (-1 none, 0..12 as MCW_JOBS.w, 13 nitwit)
                                  //   or the variant (below); z villager type (0 desert, 1 jungle, 2 plains,
                                  //   3 savanna, 4 snow, 5 swamp, 6 taiga), -1 for other mobs; w bit 0 baby
constant int2    MCW_MOB_PLACE[]; // villager's bed (index into MCW_BEDS) and job site (into MCW_JOBS), -1 none
```

- **Stops.** Per route loop, one stop per bell, bed and job site it passes:
  the point nearest the item among those within 2 blocks of it (Chebyshev,
  from the point's feet to the item's centre), and for a bed or job site
  only a point flagged bit 2. A ceiling bell hangs 2 above the feet, so a
  bell stop need not carry the flag. An item no loop reaches has no stop.
- **Doors.** Every door's lower half (`*_door`, not trapdoors). The panel
  sides are the game's: the door models put the panel at x 0..3/16 and the
  blockstate turns it, which puts a closed panel on the side opposite the
  facing and an open one a quarter turn on (+1 with the hinge left, +3
  right; checked against the 26.2 door blockstates). `world.json` gives each
  door's `route_steps`: `[route, point]` whose feet stand in it (also flag
  bit 3 on those points).
- **Mobs.** The save's own entities (`entities/r.*.mca`), only those whose
  feet are inside the box (and, in a generated save, in its square), in save
  order: region files by z then x, chunks by z then x, each chunk's list in
  order. So the table is the same on every Mac. Kinds: 0 villager, 1 iron
  golem, 2 cat, 3 cow, 4 sheep, 5 pig, 6 chicken, 7 horse, then
  `village.MOB_KINDS` in order (8 wandering trader, 9 trader llama, 10 llama,
  11 donkey, 12 mule, 13 rabbit, 14 wolf, 15 fox, 16 goat, ...; the full list
  is in `world.json` `mobs.kinds`). Entities that are not in it (minecarts,
  items, frames) and those outside the box are left out and counted in
  `world.json` `mobs.not_in_table`. Variant `y`: cat 0 tabby, 1 black, 2
  red, 3 siamese, 4 british shorthair, 5 calico, 6 persian, 7 ragdoll, 8
  white, 9 jellie, 10 all black; cow, pig, chicken, frog 0 temperate, 1 warm,
  2 cold; wolf 0 pale, 1 ashen, 2 black, 3 chestnut, 4 rusty, 5 snowy, 6
  spotted, 7 striped, 8 woods; fox 0 red, 1 snow; mooshroom 0 red, 1 brown;
  the save's own number for horse (`Variant`), sheep (`Color`), rabbit,
  parrot, axolotl, llama and tropical fish; -1 otherwise. A variant name the
  tables lack fails the bake.
- **Claims** (`MCW_MOB_PLACE`). A villager's own `home` and `job_site`
  memories when the save has them. A save that never ran a tick (a generated
  one) has none: then beds go nearest pair first to every villager, job
  sites nearest pair first to employed villagers of the same profession and
  then to unemployed ones (who take the profession the site gives), nitwits
  none, and only beds and job sites some route reaches. The game hands them
  out first come, first served; nearest first stands in for who gets there
  first. `world.json` `mobs.claims` says which rule was used.

### `world.metal`: constants for a look's prelude

Plain MSL text, spliced verbatim into the prelude of a look that uses this
world. Everything is in volume space (blocks, `0..size`). Names all start with
`MCW_`; nothing else is declared. Every `constant` line carries `[[maybe_unused]]`
(left out below), so a look that reads only some of them compiles without
warnings.

```metal
#define MCW_NAME "mine"
constant int3   MCW_SIZE       = int3(W, H, D);
constant int3   MCW_ORIGIN     = int3(ox, oy, oz);      // world block of texel 0
constant int    MCW_SEA_LEVEL  = 63;                    // world y; volume y = MCW_SEA_LEVEL - MCW_ORIGIN.y
constant int    MCW_MATERIALS  = n;                     // highest material id + 1
constant int2   MCW_FAR_SIZE   = int2(FW, FD);
constant int2   MCW_FAR_ORIGIN = int2(fx, fz);          // far.origin minus MCW_ORIGIN.xz (volume space)
constant int    MCW_FAR_MIN_Y  = -64;                   // far.min_y minus MCW_ORIGIN.y (volume space)
constant float3 MCW_CENTER     = float3(cx, cy, cz);    // the centre the bake chose, at ground height
constant float  MCW_DAY_TIME   = t;                     // the save's time of day in ticks (0..24000), from level data

// Points of interest, best first.
#define MCW_POI_CLUSTER   0   // a cluster of built blocks
#define MCW_POI_STRUCTURE 1   // one building: a connected group of built blocks
#define MCW_POI_BELL      2   // a village bell
#define MCW_POI_HILLTOP   3
#define MCW_POI_SHORE     4   // where land meets water
#define MCW_POI_LIT       5   // a spot lit by block light, for night shots
constant int    MCW_POI_COUNT = n;                      // >= 1
constant float4 MCW_POI[]      = { float4(x, y, z, radius), ... };  // centre at ground or feature height, radius in blocks
constant int    MCW_POI_KIND[] = { kind, ... };
constant float4 MCW_POI_VIEW[]    = { float4(dx, 0, dz, 0), ... };  // from the point toward a good camera; 0 = any side
constant float4 MCW_POI_BOX_MIN[] = { float4(x0, y0, z0, 0), ... }; // its box, volume space, max exclusive
constant float4 MCW_POI_BOX_MAX[] = { float4(x1, y1, z1, 0), ... };

// Routes (as routes.u16).
constant int     MCW_ROUTE_COUNT = n;                   // >= 1
constant ushort4 MCW_ROUTES[]       = { ushort4(first, count, kind, 0), ... };
constant int     MCW_ROUTE_POINT_COUNT = m;
constant ushort4 MCW_ROUTE_POINTS[] = { ushort4(x, y, z, flags), ... };
```

`MCW_POI_KIND` values are the `MCW_POI_*` defines.

Box and view, per point (same in `world.json`):

- Structure: the box of its building blocks (paths and fields left out; when
  its columns also hold something far below, such as a mineshaft in a cave
  under a house, only the band of heights with the most building blocks).
  Cluster: the union of its structures' boxes. Bell: its cell. Hilltop, shore,
  lit spot: the circle's square, from 4 below to 12 above its height.
- View (structure, cluster, bell): a horizontal unit vector, one of the 8
  compass directions, from the box toward where a camera sees it best: for
  each direction, the share of passable cells in a slab 3 to 17 blocks out
  from the box, across its width, from its floor to 6 above its top, plus
  0.15 per door on that side (doors are how a house's front is told apart,
  up to 0.3). `(0, 0, 0)` for the other kinds, and for a box at the volume's
  edge with nothing to judge by. `world.json` notes say which side and how
  open it is.

Both tables always have at
least one entry: the bake fails rather than write an empty one (untouched
terrain still has hilltops, shores and open-ground loops). `world.json` `poi`
has the same list with notes.

### `world.json`

Written last; its presence means every other file is complete. Keys:

| Key | Value |
|---|---|
| `version` | format version of this section, integer (currently 1) |
| `name` | the bake's name (`mine`, `shared`) |
| `source` | `{ "save": path, "level_name": str, "seed": int, "data_version": int, "game_version": str, "spawn": [x, y, z], "player": [x, y, z], "generated": null or { "version", "seed", "seed_text", "structure", "structure_at": [x, z], "square_chunks": {x0, z0, x1, z1, count} } }` (`generated` from the save's `lerping-generate.json`) |
| `size` | `[W, H, D]` |
| `origin` | `[x, y, z]` world block of texel 0 |
| `sea_level` | world y |
| `day_time` | ticks |
| `center` | `{ "x", "y", "z" (world), "rule": "generated-structure" \| "built-blocks" \| "player" \| "spawn" \| "given", "detail": str }`. A generated save is centred on the structure generate.sh located. Otherwise: the densest 128 x 128 window of built blocks near the surface and above water (128 wide so a spread-out village outweighs a compact tower), then their centre of mass within 64 blocks; with fewer than 64 there, the player's last position, then the spawn. |
| `vertical` | `{ "content_min_y", "content_max_y", "capped": bool }` world y the content spans; when capped also `"columns_floor_below"`, `"columns_top_above"`: columns whose lowest surface is below the box / with blocks above it |
| `box_notes` | `[str]`: the box moved to stay inside the save, missing chunks, the cap |
| `chunks` | `{ "in_box", "missing_in_box", "in_save", "finished_in_save", "statuses": {status: n}, "in_far" }` |
| `counts` | `{ "non_air", "materials" (distinct ids in the volume), "material_ids" (= MCW_MATERIALS), "emitters", "light_colours": {colour: emitters}, "water", "lava", "built_near_surface_in_save", "built_in_box": {block: n} }` |
| `atlas` | `{ "hash": sha256 hex of atlas.txt, "path": the atlas folder }` |
| `materials` | `{ "count": n, "unhandled": [ { "state": str, "reason": str, "voxels": int }, ... ] }` sorted by voxels in the volume (0 = only in the far field or a stand-in id) |
| `tints` | `{ "biomes": [names in the volume], "swamp_noise": bool, "blend_radius": 2 }` |
| `far` | `{ "origin": [x, z], "size": [FW, FD], "min_y": -64, "missing_columns": int, "chunks": int, "biomes": [...], "unknown_biome_samples": int }` |
| `poi` | `[ { "kind": str, "pos": [x, y, z] (volume space), "radius": float, "score": float, "box": [[x0, y0, z0], [x1, y1, z1]], "view": [dx, 0, dz], "note": str }, ... ]` same order as `MCW_POI` |
| `routes` | `{ "loops": n, "points": m, "rule": "village" \| "path" \| "open-ground", "notes": [str] }` |
| `places` | `{ "beds": [ {cell, block, facing, pos, yaw} ], "jobs": [ {cell, block, profession, pos} ], "bells": [ {cell, attachment, pos} ], "doors": [ {cell, block, facing, hinge, open, closed_side, open_side, code, route_steps} ], "stops": [[route, point, kind, item]] }`, the same order as the `world.metal` arrays |
| `mobs` | `{ "list": [ {id, pos, yaw, info, profession?, type?, level?, home_memory?, job_memory?, home, job} ], "claims": {"home", "job"}, "kinds": [names by kind], "not_in_table": {"why: id": count} }` |
| `files` | `{ filename: byte size }` |
| `bake` | `{ "seconds": float, "date": ISO-8601 }` |

### Writing

A bake writes into `Worlds/.NAME.baking-PID/` and, when every file is there,
exchanges that folder with `Worlds/NAME/` in one step (`renamex_np`
`RENAME_SWAP`), then deletes the old one. A reader sees the old world or the
new one, never a mix; a failed bake leaves the old world as it was.

### Changelog

- v1: first version.
- v1 (before any reader shipped): `tints.rgba8` has 4 layers (dry foliage
  added, answering the request below); a = 0 marks columns of missing chunks.
  Routes may repeat points; flag bit 3 dropped. `world.json` keys filled in
  as written.
- v1, additions only (no byte layout moved; a v1 reader keeps working):
  light now respects partial blocks' full faces (stairs, slabs, paths), which
  makes it equal to the game's stored light; route flags gain `drop` (bits
  4-7) and `rise` (bits 8-11) for standing height; `world.metal` gains
  `MCW_POI_VIEW`, `MCW_POI_BOX_MIN`, `MCW_POI_BOX_MAX` and `world.json` `poi`
  gains `box` and `view`; `world.json` `source.generated` and the
  `generated-structure` centre rule; a generated save's chunks outside its
  square are treated as absent.
- v1, additions only: "Places and mobs" (`MCW_BEDS`, `MCW_JOBS`, `MCW_BELLS`,
  `MCW_STOPS`, `MCW_DOORS`, `MCW_MOB_POS`, `MCW_MOB_INFO`, `MCW_MOB_PLACE` and
  their counts; `world.json` `places` and `mobs`); route flag bit 3 (in a
  door) and bit 12 (swimming), and routes may now cross water; the bake
  swaps a finished world in whole.

## Materials and elements

Owner: MATERIALS (`materials.py`, `entities.py`, `BlockDump.java`, `preview_block.py`).

One material record per distinct block state the bake resolved (and per
random model variant of it, see below). The material id in `blocks.r16`
is the record's row. Everything is taken from the installed jar: blockstate
and model JSON for the geometry and textures, the game's own classes (run
headless by `BlockDump.java`) for light, fluids, tints, occlusion, offsets and
the model baker's rotation matrices.

### Files

| File | Texture | Width | Rows |
|---|---|---|---|
| `materials.u32` | `texture2d<uint>`, `rgba32Uint` | 8 texels (32 words) | one per material id, row 0 = air |
| `elements.u32` | `texture2d<uint>`, `rgba32Uint` | 20 texels (80 words) | one per element, at most 16384 |
| `materials.json` | (for people and tools) | | id -> block state, counts, unhandled list |

Raw little-endian uint32, no header, row-major: word `k` of row `r` is at byte
`4 * (r * W + k)` with `W = 32` (materials) or `80` (elements); texel `k / 4`,
component `k % 4`. Rows = file size / (16 * texels per row). Floats are
stored as their IEEE bits (`as_type<float>(word)`); an integer texture never
changes bits, so read with `.read()` (no sampler). `materials.json` has
`{"version": 1, "atlas_hash", "jar", "materials": [{"id", "states": [...], "kind": "empty" | "cube" | "elements",
"elements", "opaque", "light_filter", "emission": [level, [r, g, b]], "fluid": [kind, amount] | null,
"map_color", "tint_kind", "entity", "unhandled"?: reason}], "element_rows": n, "unhandled": {state: reason}}`.
`atlas_hash` is sha256 of the `atlas.txt` the layers were resolved against.

```
uint  W(uint id, uint k)  { return materials.read(uint2(k / 4, id))[k % 4]; }
uint  E(uint row, uint k) { return elements.read(uint2(k / 4, row))[k % 4]; }
float EF(uint row, uint k) { return as_type<float>(E(row, k)); }
```

Coordinates: block space is the voxel's unit cube, `p` in `[0,1]^3` with
`p = hit - float3(cell)`, Minecraft axes (+x east, +y up, +z south).
Directions are numbered as the game does:

```
0 down (-y)   1 up (+y)   2 north (-z)   3 south (+z)   4 west (-x)   5 east (+x)
```

### Material record (`materials.u32`, 32 words)

```
w0   flags
       bits 0-1   kind: 0 nothing to draw (air, or fluid only), 1 cube, 2 elements
       bit  2     OPAQUE        the game's isSolidRender: fills the cell, blocks all light, hides every neighbour face against it
       bit  3     CUTOUT        some face is alpha-tested (leaves, glass, plants)
       bit  4     TRANSLUCENT   some face is blended (stained glass, ice, slime, honey, water)
       bit  5     FULLBRIGHT    the game's emissiveRendering: draw at full brightness (magma, sculk catalyst bloom, ...)
       bit  6     NO_AO         the model says "ambientocclusion": false (torches, plants, signs)
       bits 8-13  selfCull      per direction: hide this material's face toward a neighbour with the same cull group (glass, ice)
       bits 14-19 faceFull      per direction: this material's face on that side is a full occluder (neighbour cullface faces behind it are hidden)
       bits 20-21 offset        0 none, 1 xz, 2 xyz: the game's random plant offset (see below)
       bit  22    ENTITY        geometry built from a block-entity model (chest, bell, banner ...), not from block model JSON
       bit  23    SHADOW        has geometry (kind != 0): casts a shadow in a look that traces one
w1   first element row (kind 2)
w2   element count (kind 2), 1..MAX_ELEMENTS
w3   bits 0-1   fluid: 0 none, 1 water, 2 lava (includes waterlogged blocks)
     bits 2-5   fluid amount 1..8 (8 = source or falling; height = amount / 9, or 1 when the cell above holds the same fluid)
     bit  6     falling (level >= 8: a column of falling fluid, full height)
     bit  7     waterlogged: the fluid shares the cell with this record's geometry
     bits 8-11  light emission level 0..15 (the game's)
     bits 12-15 light dampening 0..15 (the game's; opaque = 15)
     bits 16-27 cull group (0 = none): two materials with the same non-zero group cull each other per selfCull
w4   fixed tint colour A, 0x00RRGGBB sRGB (tint code 5)
w5   fixed tint colour B, 0x00RRGGBB sRGB (tint code 6)
w6   light colour, 0x00RRGGBB sRGB, largest channel 255 (what the light bake floods)
w7   offset limits: bits 0-15 max horizontal, bits 16-31 max vertical, both in 1/1000 block
w8  .. w19   kind 1: face d's descriptor in words (8 + 2d, 9 + 2d)
w20 .. w31   kind 1: face d's overlay descriptor in words (20 + 2d, 21 + 2d), all zero when absent
```

Row 0 (air) has kind 0 and holds the fluid textures, as face descriptors:
`w8,w9` water still (top), `w10,w11` water flow (sides and sloped tops,
`skins`, 32 px), `w12,w13` water overlay (the side of water seen against
glass and leaves), `w14,w15` lava still, `w16,w17` lava flow (`skins`).
Water takes tint code 3, lava none; water is translucent.

### Face descriptor (2 words)

```
A  bits 0-11   layer (first frame) in the array
   bit  12     array: 0 mcTiles (16 x 16), 1 mcSkins (64 x 64, picture in the top-left corner)
   bits 13-15  cube faces only: orientation (see "Cube faces")
   bits 16-19  tint: 0 none, 1 grass, 2 foliage, 3 water, 4 dry foliage, 5 fixed colour A (w4), 6 fixed colour B (w5)
   bits 20-21  render: 0 solid, 1 cutout (discard texels with a < 0.5), 2 translucent (discard a < 0.1, blend the rest)
   bit  22     shade: apply the game's directional face shade (mcFaceShade); 0 = the element said "shade": false
   bit  23     present (an absent face has A == 0 and B == 0)
   bits 24-27  the face's own light emission 0..15 (element "light_emission": draw at least this bright)
   bits 28-30  cullface + 1 (0 = none): hide this face when the neighbour in that direction has faceFull on the opposite side, or is OPAQUE
B  bits 0-7    frames (1 = still)
   bits 8-23   game ticks per frame
```

Animated textures are consecutive layers in playing order (that is how the
atlas packs them):

```
uint layerAt(uint A, uint B, float time) {      // time in seconds; 20 game ticks per second
    uint frames = B & 0xFF, ticks = (B >> 8) & 0xFFFF;
    uint base = A & 0xFFF;
    if (frames <= 1) return base;
    return base + (uint(time * 20.0) / ticks) % frames;
}
```

Tint codes 1-4 read the column's colour from `tints.rgba8` (layer = code - 1:
grass, foliage, water, dry foliage); 5 and 6 are the record's fixed colours
(birch and spruce leaves, lily pads, stems by age, redstone wire by power, a
banner's dye). The game multiplies the 8-bit encoded texture by the 8-bit
encoded tint (its shaders do not linearise); do the same multiply the kit's
`mcGrassTint` looks do, so world and looks agree.

Render layer, per face, is the game's own rule: the texels the face's uv
rectangle covers (every frame) decide it: any alpha 0 -> cutout, any alpha
strictly between 0 and 255 -> translucent (wins over cutout), else solid; a
texture marked `force_translucent` in the model (stained glass panes) is
translucent. The game's terrain pipelines discard `a < 0.5` on the cutout
layer and `a < 0.1` on the translucent layer (`ALPHA_CUTOUT` in
`RenderPipelines`); a discarded texel lets the ray continue.

### Cube faces (kind 1)

A full cube needs no element walk. The ray enters the cell through face `d`
(the face of the cell it crosses) at block-space point `p`; draw face `d`'s
descriptor, then its overlay (if present) over it with the overlay's alpha.
Map `p` to the face's canonical coordinates `(s, t)`, which is how the game
maps a full-tile face with no rotation (`uv.y = 0` is the top row of the
picture):

```
float2 st;
switch (d) {
  case 0: st = float2(p.x, 1 - p.z); break;   // down
  case 1: st = float2(p.x, p.z);     break;   // up
  case 2: st = float2(1 - p.x, 1 - p.y); break; // north
  case 3: st = float2(p.x, 1 - p.y); break;   // south
  case 4: st = float2(p.z, 1 - p.y); break;   // west
  case 5: st = float2(1 - p.z, 1 - p.y); break; // east
}
uint o = (A >> 13) & 7;                         // the face's orientation, from the model and blockstate
float2 uv = (o & 4) ? st.yx : st;               // bit 2: swap
if (o & 1) uv.x = 1 - uv.x;                     // bit 0: mirror u
if (o & 2) uv.y = 1 - uv.y;                     // bit 1: mirror v
float2 texel = uv * 16.0;                       // pixel in the 16 x 16 layer
```

This covers the game's face `rotation`, blockstate `x`/`y` with and without
uvlock, and mirrored models (`cube_mirrored`, as stone and bedrock use).
Cube faces are always in `mcTiles`.

### Elements (kind 2, `elements.u32`, 80 words per element)

Rows `w1 .. w1 + w2 - 1`. Each element is a box, `lo <= q <= hi`, in its own
space `q`, which is block space for most elements. The blockstate's rotation is
already applied. An element with its own `rotation` (or a block-entity part
with a pose) carries the affine map from block space to its space.

```
w0..w2    lo.xyz (float, block units, 0..1 for most; may be outside the cell)
w3        bit 0 XFORM: q = M * p + m (else q = p); bits 1-6 face present mask (bit 1 + d)
w4..w6    hi.xyz (float); lo == hi on one axis for a flat element (cross plants, chains, sign hangers)
w7        0
w8..w19   M and m as three rows (float): q.x = dot(row0.xyz, p) + row0.w, q.y = row1, q.z = row2
          (identity rows when XFORM is clear)
w20 + 8d .. w27 + 8d   face d (0..5, in the element's own space): U.xyzw, V.xyzw (float)
          texel = float2(dot(U.xyz, q) + U.w, dot(V.xyz, q) + V.w)  -- pixel in the layer
          (0..16 for mcTiles, 0..64 for mcSkins; the picture sits in the top-left corner)
w68 + 2d, w69 + 2d     face d's descriptor (A, B); orientation bits are 0 (the planes carry it)
```

A ray hits an element only through the face it enters by (faces are one-sided,
outward, as the game culls back faces): intersect the ray, mapped into `q`
space, with the box; the entry face is the slab that gave `tNear`. If that face
is not present, or its texel is cut out, the element is missed and the ray goes
on to the other elements and past the cell. A flat element (`lo.a == hi.a`) is
entered through the side facing the ray. Choose the nearest hit over all
elements of the cell.

```
float3 qo = xform ? M * o + m : o,  qd = xform ? M * d : d;   // o in block space (o = rayOrigin - cell), d the ray direction
// the hit distance t is the same in both spaces because q is affine in p along the ray
float3 t0 = (lo - qo) / qd, t1 = (hi - qo) / qd;
float3 tn = min(t0, t1), tf = max(t0, t1);
float tNear = max3(tn), tFar = min3(tf);
if (tNear > tFar || tFar < tMin) miss;
int axis = argmax(tn);  int face = axis == 0 ? (qd.x > 0 ? 4 : 5) : axis == 1 ? (qd.y > 0 ? 0 : 1) : (qd.z > 0 ? 2 : 3);
// careful with qd.a == 0 on a flat element's axis: use a tiny epsilon or test that axis separately
float3 q = qo + qd * tNear;
float3 nq = face normal in q space;   float3 n = xform ? normalize(transpose(M) * nq) : nq;   // block-space normal
```

Elements may reach outside the unit cell (fence gates in walls, tall grass
offsets, the bell's bar, beds and doors do not, but a random plant offset and
some entity parts do by up to 0.25 block). A tracer that only looks inside the
cell the ray is in will clip those by at most that much.

`MAX_ELEMENTS` per material is 64. The bake reports any state that would need
more in `unhandled()` and draws nothing for it; it never truncates the list.

### Random variants and offsets

- **Weighted model variants** (stone, dirt, grass block top rotations, sand,
  netherrack, ...): the bake picks the game's variant for each voxel from its
  position, exactly as the renderer does (`Mth.getSeed(pos)` into the game's
  LCG, `nextInt(total weight)`; multipart: `nextLong()` then per part), and
  gives each variant its own material id. The runtime does nothing for them.
- **Plant offsets** (`offset` in w0): the game shifts grass, flowers, ferns,
  bamboo, dripstone etc. inside the cell by a hash of the column. Add `off` to
  every element point (equivalently subtract it from the ray origin):

```
// x, y, z: world block coordinates (cell + MCW_ORIGIN). uint maths gives the same low bits as the game's long maths.
uint  l  = (uint(x) * 3129871u) ^ (uint(z) * 116129781u);           // Mth.getSeed(x, 0, z), y = 0
l = l * l * 42317861u + l * 11u;
uint  h  = l >> 16;
float mh = float(w7 & 0xFFFF) / 1000.0, mv = float(w7 >> 16) / 1000.0;
float3 off;
off.x = clamp((float(h & 15u) / 15.0 - 0.5) * 0.5, -mh, mh);
off.z = clamp((float((h >> 8) & 15u) / 15.0 - 0.5) * 0.5, -mh, mh);
off.y = (offset == 2) ? (float((h >> 4) & 15u) / 15.0 - 1.0) * mv : 0.0;
```

Checked against the game's `getOffset` at 64 positions for every offset block.

### Fluids

A cell's fluid comes from `w3` (water and lava blocks have kind 0; a
waterlogged block has its own geometry and `waterlogged` set). The surface
height is `amount / 9` (a source is 8/9), or 1 when the cell above holds the
same fluid; the game also averages the height at each corner with the three
neighbouring cells (a look may do the same, reading their `w3`). Textures are
in row 0. Water faces are not drawn against water; lava faces not against lava.

### Block entities

Blocks the game draws with a block-entity renderer have no elements in the
jar's models. In 26.2 beds, signs and hanging signs are JSON models (drawn as
such; sign text is not drawn). Built from the game's own baked entity model
(cubes, part poses and skin uvs dumped by `BlockDump.java`) and the renderer's
own per-facing transform, on the entity texture in `mcSkins`, with `ENTITY`
set in w0:

- chests: single and double (`type` left / right), normal, trapped, ender and
  the copper chests by weathering; lid closed. (The game swaps in its
  Christmas textures on 24-26 December; the bake does not.)
- the bell's body (the frame is JSON), still.
- banners, standing (16 rotations) and on walls: pole, bar and flag, the flag
  at the middle of its sway (the game sways it about +-0.6 degrees over 5
  seconds), base colour only: the flag is `entity/banner/base` with the dye's
  colour as fixed tint A (it covers the whole flag, so the untinted cloth under
  it never shows). Patterns live in the block entity, not the state.
- shulker boxes, closed, by colour and facing.
- skulls and heads on the ground (16 rotations) and on walls: skeleton,
  wither skeleton, zombie (with its hat layer), creeper, piglin (ears at
  rest). Not the dragon head (its skin is 256 px, in `maps`) or player heads
  (the skin is the block entity's profile).

Entity elements are axis-aligned and baked into block space where the
transform allows (chests, shulker boxes, the bell); banner parts carry XFORM
(rotation and the renderer's 2/3 scale, so `M` is not orthonormal: normalise
the transformed normal). The game lights entities with its two directional
lights rather than the block face shade; these faces say `shade` and take the
block shade, which is close but not identical.

Not built, listed by `unhandled()` and drawn as nothing: dragon and player
heads, decorated pots (sherds are block-entity data), conduits, end portals
and gateways, copper golem statues, moving pistons, a lectern holding a book
(the book), the enchanting table (its floating book).

### Python side (for VOLUME)

- `Table.resolve(name, props, pos=None)`: `pos` is the world block `(x, y, z)`.
  It is required for states with weighted variants (`table.needs_pos(name, props)`
  says which); without it those raise `ValueError` rather than pick one.
  `air`, `cave_air` and `void_air` resolve to 0.
- `table.parts(name, props)`: `("variants" | "multipart", [[entry, ...], ...])`,
  the blockstate's model entries that apply to the state, one inner list per
  part, more than one entry where the game picks by weight (`entry["weight"]`,
  default 1). For bake.py's vectorised pick; `_parts` stays as an alias.
- A state that cannot be drawn still gets an id (kind 0, drawn as nothing),
  so voxels can be counted; `opaque`, `light_filter` and `emission` level are
  the game's for it (its light colour is white, there being no texture to take
  it from), and `unhandled()` names it with the reason. The invisible `light`
  block is drawn (as nothing) and lights white.
- `fluid(mid)`: `None` or `("water" | "lava", amount)`, amount 1..8 where 8 is a
  source or falling fluid (the game's `FluidState.getAmount`).
- `emission(mid)`: `(level, (r, g, b))`, the colour from the block's own
  texture: per face texture, the mean of its brightest third of pixels (linear
  light); of those, the brightest and most coloured texture (a lit furnace's
  flame front rather than its stone); sRGB, scaled so the largest channel is 1.
- `map_color(mid)`: mean colour of the highest up-facing face (or of any face,
  for flat plants), sRGB, before biome tint; `tint_kind(mid)` is that face's
  tint: `None`, `"grass"`, `"foliage"`, `"water"` or `"dry_foliage"`. A fixed
  tint is already multiplied into `map_color` (and `tint_kind` is `None`).

### Changelog

- v1: first version.
- v1 (before any reader shipped): dry foliage is layer 3 of `tints.rgba8`;
  tint multiply described as the game does it; `materials.json` keys listed;
  block entities section added (chests, bell body, banners, shulker boxes,
  skulls); Python side spelled out (`parts`, air -> 0, unhandled ids, light
  colour rule). No byte layout changed.

## Generated saves

Owner: GENERATE (`generate.sh`, `server.zsh`, `Driver.java`, `audition.sh`, `villages.sh`, `survey.py`, `compare.py`).

`generate.sh` writes an ordinary save folder for the installed game version
(`level.dat`, `dimensions/minecraft/overworld/{region,entities,poi}/*.mca`,
deflate-compressed chunks), so the bake reads it exactly as it reads the
user's own save. What is particular to a generated save:

- Every chunk in the square is at `Status` `minecraft:full`. Chunks around it
  (up to about 12 chunks out, from structure starts) are present at partial
  statuses and should be treated as not there. The server's start-up spawn
  area near 0,0 is also present and full; it is not part of the square.
- Nothing has been simulated: ticking was frozen before the first tick, so
  there are no fluid flows, crop growth, mob movement or weather. Mobs placed
  by worldgen (animals, villagers) are in `entities/` where they spawned.
- Gamerules saved in `level.dat` keep it that way if the save is opened:
  `random_tick_speed 0`, `advance_time` / `advance_weather` / `spawn_*` /
  `mob_griefing` false.
- `lerping-generate.json` (one JSON object, the same line generate.sh prints):

```
structure             "minecraft:village_plains" (what --structure asked for), or null
                      when the square was centred on a bare --at position
x, z                  the centre: the block locate printed (the structure's start
                      chunk corner), or the --at position itself
distance_from_origin  blocks from 0,0 to x, z, rounded
centred_on            "structure" or "position" (which of the two x, z is)
at                    [X, Z] given with --at, or null (then locate searched from 0,0)
chunks                {x0, z0, x1, z1, count}: the full square, inclusive
blocks                {x0, z0, x1, z1}: the same square in blocks, inclusive
seed                  the seed as the game resolved it (text seeds are hashed)
seed_text             the seed as given
version               game version that generated it, e.g. "26.2"
seconds               wall time of the whole run
save                  absolute path the save was written to
```

- `lerping-generate.log` is the server's full console output for the run.

Two runs with the same seed and game version give the same square: every
block state, biome, light value, heightmap, block entity, scheduled tick and
point of interest, and the same entities apart from their UUIDs (which the
game draws from an unseeded random). `compare.py SAVE_A SAVE_B` checks this.

## Requests

- RUNTIME -> MATERIALS (what the tracer can read fastest; any equivalent shape is fine, just say it here):
  1. Blockstate rotation (`x`, `y`, `uvlock`) baked into the elements, so every element is in the block's final orientation, axis-aligned except for its own single-axis `rotation`.
  2. Per element face, the texture mapping as the texel (in texture pixels, 0..16) at two or three corners of the face, or a uv rect plus rotation with the corner convention written out, so the runtime does not have to guess FaceBakery's.
  3. A fast path per material: "full cube" with its six face layers (and per-face tint / overlay), so most voxels never walk elements; a separate flag for full cubes that are cut out (leaves, glass).
  4. Raw data as 2D textures of `rgba32Uint` / `rgba32Float` (or `rgba16Uint`), rows at most 16384 texels wide; the material id indexes the material table directly.
  5. Per material: opaque, cutout, translucent, emissive (it is the light bake's), fluid (water / lava, level, waterlogged), tint kind per face, animated layers (first layer, frames, ticks per frame), and whether it casts a sun shadow.
- VOLUME -> MATERIALS:
  1. Dry foliage: done on VOLUME's side, `tints.rgba8` layer 3 (the line in "Face descriptor" that says it "needs layer 3" can now say it is there).
  2. `bake.py` computes the weighted-variant pick for millions of voxels in numpy and checks 64 voxels per state against `table.resolve(pos=...)`. To do that it calls `table._parts(name, props)` for the blockstate's parts and weights. Please keep `_parts` (or give it a public name) so this does not break silently; the bake fails loudly if a pick disagrees.
     MATERIALS: done. `table.parts(name, props)` is the public name; `_parts` stays. Both answered in "Materials and elements" (dry foliage is tint code 4 = layer 3).
  RUNTIME requests 1-5 answered in "Materials and elements": (1) blockstate rotation is baked in; an element with its own rotation (any axis or Euler, as 26.2 allows) carries a full affine map instead of an angle; (2) per face, two planes give the texel at any point, which is exact for face rotation, uvlock and mirroring (checked against the game's FaceBakery on every face of every model in every rotation the jar uses: 67,726 faces, largest difference 5e-7); (3) kind 1 is the full-cube path, with CUTOUT / TRANSLUCENT flags; (4) `rgba32Uint`, 8 and 20 texels wide; (5) all in w0 / w3 / face descriptors; SHADOW is bit 23.
- RUNTIME -> VOLUME: (withdrawn, nothing to do) a skip distance inside water. The runtime loader now derives it itself when it uploads `blocks.r16` (`LerpMinecraftWorld.addWaterSkip`: plain water voxels get the Chebyshev distance to the nearest non-water voxel in their high 4 bits on the GPU copy), so the file stays as specified: 0 in the high bits of every non-air voxel.
- one-world (look) -> VOLUME, 2026-11-21 (full text in the scratch folder's KIT-REQUESTS.md, items 1-3):
  1. A village table in `world.metal`, so a look can run the villagers' day without scanning routes per pixel:
     `MCW_STOPS[]` = `ushort4(route, point index, kind 0 bell / 1 bed / 2 job site, item)` (one per waypoint per loop, the
     point already flagged bit 2), `MCW_BEDS[]` = `float4(head cell centre, yaw foot -> head)`, `MCW_JOBS[]` =
     `float4(job-site cell centre, profession code)`, with `_COUNT`s.
  2. The save's own mobs in the box (worldgen put 7 villagers, an iron golem, a cat and two cows in `shared`):
     `MCW_MOB_POS[]` = `float4(feet, yaw)`, `MCW_MOB_INFO[]` = `int4(kind, profession or variant, villager biome, baby)`, in save order.
  3. Door cells: `MCW_DOORS[]` = `int4(lower half cell, facing | hinge << 2 | open << 3)`, so a look can draw a door
     open while a mob walks through it (routes pass through doors the volume has closed).
  Until these land, one-world carries a stop table copied from the current bake, which breaks whenever routes change.
  VOLUME: done, all three, in "Places and mobs" above: `MCW_STOP_COUNT`/`MCW_STOPS`, `MCW_BED_COUNT`/`MCW_BEDS`,
  `MCW_JOB_COUNT`/`MCW_JOBS`, `MCW_BELL_COUNT`/`MCW_BELLS`, `MCW_MOB_COUNT`/`MCW_MOB_POS`/`MCW_MOB_INFO`, `MCW_MOB_PLACE`
  (each villager's bed and job site, which the look's tool worked out itself), `MCW_DOOR_COUNT`/`MCW_DOORS`, route flag bit 3.
  Shapes are as asked except: `MCW_STOPS.w` for a bell indexes `MCW_BELLS`; `MCW_BEDS.y` is the mattress top (y + 9/16,
  as the tool had it); `MCW_DOORS.w` has the raw facing / hinge / open bits as asked plus the panel's closed and open
  sides in bits 4-5 and 6-7 (the tool's "open side" is bits 6-7 here, not 2-3); `MCW_MOB_INFO.z` is the villager type
  (plains = 2), -1 for other mobs; kinds 5-7 are pig, chicken, horse as the request lists (the tool had horse = 5).
