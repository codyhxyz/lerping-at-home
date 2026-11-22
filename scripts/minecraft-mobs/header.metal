// ==== Minecraft mobs kit =====================================================
// The game's own mobs: their skins (the MCS_* / MCM_* layers) on the box
// models of the installed @VERSION@ client. The boxes, pivots, rest rotations and
// every face's skin rectangle are read from the game's baked models
// (LayerDefinitions.createRoots(), dumped and flattened by scripts/minecraft-mobs),
// not typed in, so each face shows the part of the PNG the game puts there.
//
// Space. A mob stands in its own "mob space": blocks at the game's scale
// (16 model pixels to a block), y up, feet on y = 0, centred on x = z = 0,
// facing +z (its right side is -x). mcMobRay takes a world ray there for a
// mob at a position and heading; mcMobNormal turns the hit normal back.
// Distances come back in the units of your ray, unchanged by the transform.
//
//   mcMobRay(ro, rd, at, heading, lro, lrd)                  world -> mob space
//   float2   mcMobBounds(type, lro, lrd)                     cheap box test, call first
//   MCMOB_Hit mcMobTrace(type, pose, skin, lro, lrd, tMax, mcSkins, mcMaps)
//   float4   mcMobColor(type, hit, skin, w, mcSkins, mcMaps) unlit rgb, .a = glow
//   float3   mcMobNormal(hit.n, heading)                     back to world, for mcFaceShade
//   mcMobStill(), mcMobSkin(layer), mcMobVillagerSkin(...), mcMobSheepSkin(...),
//   mcMobEndermanSkin()
//
// Pose (MCMOB_Pose): walk phase and stride for legs and arms (the game's
// walkAnimation position and speed: 0.3-0.6 is a walk, 1 a run), head yaw
// and pitch, graze (head down), flap (wings), wag (tail). Each part turns
// about the game's own pivot in the game's Z*Y*X order. The bounds hold for
// |yaw| <= 1.2, |pitch| <= 0.8 and every speed, graze, flap and wag.
//
// In (constant MCMOB_*):
//   VILLAGER, VILLAGER_BABY (base + biome + profession + level overlays)
//   PIG, PIG_COLD, PIG_BABY            (warm pig: PIG with MCS_PIG_WARM)
//   COW, COW_COLD, COW_WARM, COW_BABY, COW_COLD_BABY, COW_WARM_BABY
//                                      (mooshroom: COW / COW_BABY with its skin, no mushrooms)
//   SHEEP, SHEEP_BABY                  (body, undercoat and wool model, dyed by tint; shorn = no wool)
//   CHICKEN, CHICKEN_COLD, CHICKEN_BABY (warm: CHICKEN with MCS_CHICKEN_WARM)
//   WOLF, WOLF_BABY, CAT, CAT_BABY     (ocelot: CAT / CAT_BABY with its skin; no collars)
//   FOX, FOX_BABY, BEE, BEE_BABY
//   HORSE, HORSE_BABY, DONKEY, DONKEY_BABY (mule: DONKEY with MCS_HORSE_MULE; markings as over1;
//                                      zombie and skeleton horses: HORSE with their skins)
//   IRON_GOLEM (skin in mcMaps), ZOMBIE, ZOMBIE_BABY (husk: same with its skin),
//   SKELETON (stray, wither skeleton: same with their skins), CREEPER,
//   ENDERMAN (eyes glow), ALLAY, PARROT, BAT
//   LLAMA, TRADER_LLAMA (skins in mcMaps; mcMobLlamaSkin(coat, decor) lays a carpet or
//                                      the trader llama's blanket on the decor model)
// The lead: mcMobLead(ro, rd, from, to, tMax) between MCMOB_LLAMA_LEASH on a llama
// (mcMobPoint(MCMOB_LLAMA_LEASH, at, heading)) and MCMOB_TRADER_HOLD above a trader's feet.
// Not in, for llamas: their chests, baby llamas, the spit.
// The ground shadow: mcMobShadow(type, at, p, cam, light, w, mcSkins), the opacity of the
// round shadow the game lays under a mob, radius MCMOB_SHADOW[type] from its renderer.
// Not in: saddles, armour, chests on donkeys, held items, the mooshroom's
// mushrooms, collars, the iron golem's cracks and flower, the bee's stinger
// model for an angry bee, the sitting / sleeping / eating poses beyond the
// graze tilt, keyframed animations (the bat's and allay's are approximated
// by the flap value), the allay's translucency, the creeper's charge, the
// drowned and bogged outer layers.
//
// Cost: a ray inside a mob's bounds tests each part's bounding sphere and
// pays one sin/cos triple only for the parts it can hit, then a slab test per
// box (5 to 14 boxes a mob). Cut-out boxes read up to two texels while
// tracing; the colour reads one texel per layer, once, for the winning hit.
// Loop over only the mobs a ray can reach (a grid, a row, a screen-space
// cull): 41 bounds tests per pixel cost more at Retina size than the mobs.
