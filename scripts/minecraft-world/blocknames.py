"""Block-name rules the bake needs that are about the world, not about drawing.

Which blocks a player or a structure put there (to find what is worth
filming), which ones a mob can walk through or stand on (for routes), and the
village blocks routes link. These are judgements about game names, kept in one
place so the rules can be read and argued with.
"""

# Blocks that do not generate in open terrain: something built them.
BUILT_EXACT = {
    "bell", "dirt_path", "farmland", "wheat", "carrots", "potatoes", "beetroots",
    "torch", "wall_torch", "soul_torch", "soul_wall_torch", "redstone_torch", "redstone_wall_torch",
    "lantern", "soul_lantern", "campfire", "soul_campfire",
    "glass", "glass_pane", "tinted_glass",
    "hay_block", "composter", "lectern", "smithing_table", "fletching_table",
    "cartography_table", "brewing_stand", "barrel", "blast_furnace", "smoker", "loom",
    "stonecutter", "grindstone", "cauldron", "water_cauldron", "lava_cauldron",
    "powder_snow_cauldron", "crafting_table", "furnace", "chest", "trapped_chest",
    "bookshelf", "chiseled_bookshelf", "bricks", "stone_bricks", "cobblestone",
    "mossy_cobblestone", "smooth_stone", "ladder", "rail", "powered_rail",
    "detector_rail", "activator_rail", "flower_pot", "iron_bars", "lever",
    "jukebox", "note_block", "anvil", "chipped_anvil", "damaged_anvil",
    "enchanting_table", "beacon", "conduit", "sea_lantern", "glowstone",
    "redstone_lamp", "jack_o_lantern", "carved_pumpkin", "scaffolding",
    "iron_chain", "chain", "decorated_pot", "candle", "end_rod", "respawn_anchor",
    "lodestone", "target", "hopper", "dispenser", "dropper", "observer",
    "piston", "sticky_piston", "repeater", "comparator", "daylight_detector",
    "white_concrete",
}
BUILT_SUFFIX = (
    "_planks", "_stairs", "_slab", "_fence", "_fence_gate", "_door", "_trapdoor",
    "_bed", "_carpet", "_wool", "_stained_glass", "_stained_glass_pane", "_wall",
    "_button", "_pressure_plate", "_sign", "_wall_sign", "_hanging_sign",
    "_wall_hanging_sign", "_banner", "_wall_banner", "_concrete", "_glazed_terracotta",
    "_candle", "_shulker_box", "_bricks", "_tiles", "_bulb", "_grate", "_lantern",
)
BUILT_PREFIX = ("potted_", "stripped_", "polished_", "chiseled_", "cut_", "smooth_", "waxed_")
# Generated naturally (amethyst geodes, basalt) despite matching a rule above.
NOT_BUILT = {"smooth_basalt", "polished_basalt"}

def short(name):
    return name[10:] if name.startswith("minecraft:") else name


def is_built(name):
    n = short(name)
    if n in NOT_BUILT:
        return False
    if n in BUILT_EXACT:
        return True
    if n.endswith(BUILT_SUFFIX) or n.startswith(BUILT_PREFIX):
        return True
    return False


# Flat built ground: counts as built (a path is someone's work) but does not
# join buildings into one structure.
FLAT_BUILT = {"dirt_path", "farmland", "wheat", "carrots", "potatoes", "beetroots"}


def is_building(name):
    return is_built(name) and short(name) not in FLAT_BUILT and not short(name).endswith("_carpet")


# Village waypoints.
JOB_SITES = {
    "composter", "lectern", "smithing_table", "fletching_table", "cartography_table",
    "brewing_stand", "barrel", "blast_furnace", "smoker", "loom", "stonecutter",
    "grindstone", "cauldron", "water_cauldron", "lava_cauldron", "powder_snow_cauldron",
}


def is_bed(name):
    return short(name).endswith("_bed")


def is_job_site(name):
    return short(name) in JOB_SITES


# Blocks with no collision box: a mob's feet and head can be in them.
PASSABLE_EXACT = {
    "air", "cave_air", "void_air", "short_grass", "tall_grass", "fern", "large_fern",
    "dead_bush", "bush", "short_dry_grass", "tall_dry_grass", "firefly_bush",
    "dandelion", "poppy", "blue_orchid", "allium", "azure_bluet", "red_tulip",
    "orange_tulip", "white_tulip", "pink_tulip", "oxeye_daisy", "cornflower",
    "lily_of_the_valley", "torchflower", "sunflower", "lilac", "rose_bush", "peony",
    "pink_petals", "wildflowers", "leaf_litter", "open_eyeblossom", "closed_eyeblossom",
    "cactus_flower",
    "torch", "wall_torch", "soul_torch", "soul_wall_torch", "redstone_torch",
    "redstone_wall_torch", "rail", "powered_rail", "detector_rail", "activator_rail",
    "redstone_wire", "tripwire", "tripwire_hook", "lever", "vine", "glow_lichen",
    "sugar_cane", "wheat", "carrots", "potatoes", "beetroots", "brown_mushroom",
    "red_mushroom", "light", "structure_void",
}
PASSABLE_SUFFIX = (
    "_sapling", "_carpet", "_button", "_pressure_plate", "_sign", "_wall_sign",
    "_banner", "_wall_banner", "_door",      # villagers open doors
)


def is_passable(name, props):
    n = short(name)
    if n == "snow":
        return int(dict(props).get("layers", "1")) <= 3
    if n in PASSABLE_EXACT:
        return True
    return n.endswith(PASSABLE_SUFFIX)


# Ground a mob can stand on that the light bake does not call opaque.
GROUND_EXTRA_EXACT = {
    "dirt_path", "farmland", "ice", "packed_ice", "blue_ice", "glass", "tinted_glass",
    "snow_block", "powder_snow", "mud", "soul_sand", "honey_block", "slime_block",
}
# Stairs and slabs: a mob walks up them. The route puts its feet on the cell
# above, half a block high over a bottom slab or the low half of a stair.
GROUND_EXTRA_SUFFIX = ("_stained_glass", "_stairs", "_slab")


def is_ground_extra(name, props):
    n = short(name)
    if n == "snow":
        return int(dict(props).get("layers", "1")) >= 4
    if n in GROUND_EXTRA_EXACT:
        return True
    return n.endswith(GROUND_EXTRA_SUFFIX)


PURE_FLUIDS = {"water", "lava", "bubble_column"}
AIR = {"air", "cave_air", "void_air"}


def foot_drop(name, props):
    """Sixteenths below the top of the cell where a mob standing on this block has its feet."""
    n = short(name)
    p = dict(props)
    if n in ("dirt_path", "farmland"):
        return 1                                    # 15/16 tall
    if n.endswith("_slab") and p.get("type") == "bottom":
        return 8
    if n.endswith("_stairs") and p.get("half") == "bottom":
        return 4                                    # half way between the step's two heights
    if n == "snow":
        return 16 - 2 * (int(p.get("layers", "1")) - 1)    # collision is (layers - 1) / 8 tall
    return 0


def foot_rise(name, props):
    """Sixteenths above the bottom of the feet cell for what is in it (thin snow has a top)."""
    n = short(name)
    if n == "snow":
        return 2 * (int(dict(props).get("layers", "1")) - 1)
    return 0
