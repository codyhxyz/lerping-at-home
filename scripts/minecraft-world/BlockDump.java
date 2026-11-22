// Dumps what the game itself knows about every block state, for materials.py:
// light emission and dampening, whether the state is a full opaque cube, its
// fluid, which faces it occludes, the random offset of plants, the tint
// source behind each tint index, and the matrices the model baker uses for a
// blockstate's x/y/z rotation with and without uvlock. It runs the installed
// jar's own classes headless (like scripts/minecraft-mobs/Dump.java), so no
// table of block behaviour is kept by hand. Exits 1 with one line on stderr
// if the game's classes have moved.
//
// Output, one record per line, tab separated:
//   S  name  props  emission  dampening  solidRender  canOcclude  skyDown
//      renderShape  emissiveRendering  fluid  amount  falling  selfSkip  faceFull
//      offset  maxH  maxV  shadeBrightness  blockEntity  hasCollision
//   T  name  props  tintIndex  kind  colour          one per tint source
//   O  name  x  y  z  dx  dy  dz                     offsets at sample positions
//   G  x  y  z  seed  pick4  pick16  multiSeed       the renderer's RNG at sample positions
//   M  x  y  z  uvlock  transform(16)  inverseFace(6 x 16)
import java.lang.reflect.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.util.Mth;
import net.minecraft.util.RandomSource;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.*;
import net.minecraft.world.level.block.state.properties.Property;
import net.minecraft.world.level.material.FluidState;
import net.minecraft.world.phys.Vec3;
import net.minecraft.client.color.block.*;
import com.mojang.math.Quadrant;
import org.joml.Matrix4fc;

public class BlockDump {
  static StringBuilder sb = new StringBuilder();

  static String props(BlockState s) {
    StringBuilder p = new StringBuilder();
    for (Property<?> prop : s.getProperties()) {
      if (p.length() > 0) p.append(',');
      p.append(prop.getName()).append('=').append(name(prop, s));
    }
    return p.length() == 0 ? "-" : p.toString();
  }
  @SuppressWarnings({"unchecked", "rawtypes"})
  static String name(Property prop, BlockState s) { return prop.getName(s.getValue(prop)); }

  static String mat(Matrix4fc m) {
    StringBuilder o = new StringBuilder();
    for (int c = 0; c < 4; c++) for (int r = 0; r < 4; r++) o.append(String.format(Locale.ROOT, " %.7f", m.get(c, r)));
    return o.toString().trim().replace(' ', ',');
  }

  static float callFloat(Block b, String method) throws Exception {
    Class<?> c = b.getClass();
    while (c != null) {
      try { Method m = c.getDeclaredMethod(method); m.setAccessible(true); return (float) m.invoke(b); }
      catch (NoSuchMethodException e) { c = c.getSuperclass(); }
    }
    throw new NoSuchMethodException(method);
  }

  public static void main(String[] a) {
    try { run(); }
    catch (Throwable t) {
      Throwable c = t; while (c.getCause() != null) c = c.getCause();
      System.err.println("minecraft-world: the game's block classes have moved (" + c.getClass().getSimpleName() + ": " + c.getMessage() + ")");
      System.exit(1);
    }
  }

  static void run() throws Exception {
    net.minecraft.SharedConstants.tryDetectVersion(); net.minecraft.server.Bootstrap.bootStrap();
    BlockColors colors = BlockColors.createDefault();
    Map<Class<?>, String> kinds = new HashMap<>();
    kinds.put(BlockTintSources.grass().getClass(), "grass");
    kinds.put(BlockTintSources.grassBlock().getClass(), "grass");
    kinds.put(BlockTintSources.doubleTallGrass().getClass(), "grass");
    kinds.put(BlockTintSources.sugarCane().getClass(), "grass");
    kinds.put(BlockTintSources.foliage().getClass(), "foliage");
    kinds.put(BlockTintSources.dryFoliage().getClass(), "dry_foliage");
    kinds.put(BlockTintSources.water().getClass(), "water");
    kinds.put(BlockTintSources.redstone().getClass(), "fixed");
    kinds.put(BlockTintSources.stem().getClass(), "fixed");
    kinds.put(BlockTintSources.constant(0).getClass(), "fixed");
    kinds.put(BlockTintSources.constant(0, 0).getClass(), "fixed");
    Field blankField = BlockColors.class.getDeclaredField("BLANK_LAYER"); blankField.setAccessible(true);
    Object blank = blankField.get(null);
    Direction[] dirs = Direction.values();
    BlockPos[] samples = new BlockPos[64];
    Random r = new Random(1234);
    for (int i = 0; i < samples.length; i++) samples[i] = new BlockPos(r.nextInt(60000) - 30000, r.nextInt(380) - 64, r.nextInt(60000) - 30000);

    for (Block block : BuiltInRegistries.BLOCK) {
      String bname = BuiltInRegistries.BLOCK.getKey(block).toString();
      boolean offsetsDone = false;
      for (BlockState s : block.getStateDefinition().getPossibleStates()) {
        String p = props(s);
        FluidState f = s.getFluidState();
        String fluid = f.isEmpty() ? "none" : BuiltInRegistries.FLUID.getKey(f.getType()).toString();
        int falling = (!f.isEmpty() && f.hasProperty(net.minecraft.world.level.material.FlowingFluid.FALLING) && f.getValue(net.minecraft.world.level.material.FlowingFluid.FALLING)) ? 1 : 0;
        int selfSkip = 0, faceFull = 0;
        for (int d = 0; d < 6; d++) {
          if (s.skipRendering(s, dirs[d])) selfSkip |= 1 << d;
          if (s.canOcclude() && Block.isFaceFull(s.getFaceOcclusionShape(dirs[d]), dirs[d])) faceFull |= 1 << d;
        }
        String offset = "none"; float maxH = 0, maxV = 0;
        if (s.hasOffsetFunction()) {
          maxH = callFloat(block, "getMaxHorizontalOffset"); maxV = callFloat(block, "getMaxVerticalOffset");
          boolean anyY = false;
          for (BlockPos q : samples) if (s.getOffset(q).y != 0) anyY = true;
          offset = anyY ? "xyz" : "xz";
          if (!offsetsDone) {
            offsetsDone = true;
            for (BlockPos q : samples) { Vec3 o = s.getOffset(q); sb.append(String.format(Locale.ROOT, "O\t%s\t%d\t%d\t%d\t%.9f\t%.9f\t%.9f\n", bname, q.getX(), q.getY(), q.getZ(), o.x, o.y, o.z)); }
          }
        }
        boolean collision = !s.getCollisionShape(net.minecraft.world.level.EmptyBlockGetter.INSTANCE, BlockPos.ZERO).isEmpty();
        sb.append(String.format(Locale.ROOT, "S\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%s\t%d\t%s\t%d\t%d\t%d\t%d\t%s\t%.6f\t%.6f\t%.6f\t%d\t%d\n",
          bname, p, s.getLightEmission(), s.getLightDampening(), s.isSolidRender() ? 1 : 0, s.canOcclude() ? 1 : 0,
          s.propagatesSkylightDown() ? 1 : 0, s.getRenderShape().name(), s.emissiveRendering() ? 1 : 0,
          fluid, f.getAmount(), falling, selfSkip, faceFull, offset, maxH, maxV,
          s.getShadeBrightness(net.minecraft.world.level.EmptyBlockGetter.INSTANCE, BlockPos.ZERO), s.hasBlockEntity() ? 1 : 0, collision ? 1 : 0));
        List<BlockTintSource> sources = colors.getTintSources(s);
        for (int i = 0; i < sources.size(); i++) {
          BlockTintSource src = sources.get(i);
          if (src == blank) { sb.append("T\t").append(bname).append('\t').append(p).append('\t').append(i).append("\tnone\t0\n"); continue; }
          String kind = kinds.getOrDefault(src.getClass(), "unknown:" + src.getClass().getName());
          String colour;
          try { colour = String.format("%08x", src.colorInWorld(s, null, null)); }
          catch (RuntimeException e) { colour = "error:" + e.getClass().getSimpleName(); }
          sb.append("T\t").append(bname).append('\t').append(p).append('\t').append(i).append('\t').append(kind).append('\t').append(colour).append('\n');
        }
      }
    }

    // The renderer's random source: seeded per block with state.getSeed(pos)
    // (Mth.getSeed for every block that has random variants), one nextInt for
    // a weighted list, one nextLong first for a multipart.
    RandomSource rs = RandomSource.createThreadLocalInstance(0L);
    for (BlockPos q : samples) {
      long seed = Mth.getSeed(q);
      rs.setSeed(seed); int p4 = rs.nextInt(4);
      rs.setSeed(seed); int p16 = rs.nextInt(16);
      rs.setSeed(seed); int p6 = rs.nextInt(6);
      rs.setSeed(seed); long ml = rs.nextLong();
      sb.append(String.format(Locale.ROOT, "G\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", q.getX(), q.getY(), q.getZ(), seed, p4, p16, p6, ml));
    }

    // Model-state matrices for every x/y/z quarter turn, with and without uvlock.
    Class<?> sms = Class.forName("net.minecraft.client.renderer.block.dispatch.Variant$SimpleModelState");
    Constructor<?> ctor = sms.getConstructor(Quadrant.class, Quadrant.class, Quadrant.class, boolean.class);
    Method asModelState = sms.getMethod("asModelState");
    for (Quadrant qx : Quadrant.values()) for (Quadrant qy : Quadrant.values()) for (Quadrant qz : Quadrant.values()) for (boolean lock : new boolean[]{false, true}) {
      net.minecraft.client.renderer.block.dispatch.ModelState ms =
        (net.minecraft.client.renderer.block.dispatch.ModelState) asModelState.invoke(ctor.newInstance(qx, qy, qz, lock));
      sb.append(String.format("M\t%d\t%d\t%d\t%d\t%s", qx.ordinal() * 90, qy.ordinal() * 90, qz.ordinal() * 90, lock ? 1 : 0, mat(ms.transformation().getMatrix())));
      for (Direction d : dirs) sb.append('\t').append(mat(ms.inverseFaceTransformation(d)));
      sb.append('\n');
    }
    entities();
    System.out.print(sb);
  }

  // ---- Block entities: the game's own baked models, posed as the renderer poses
  // them at rest, the renderers' per-facing transforms, and the sprites they use.
  //   P  job  cube  pose(16, column-major: part space in pixels/16 -> model space)  min(3)  max(3)   (pixels)
  //   Q  job  cube  nx,ny,nz  then 4 x (x,y,z pixels, u,v texture pixels)
  //   X  transform-name  key  matrix(16, column-major)
  //   K  sprite-name  texture path
  //   D  dye  rrggbb (texture diffuse colour)
  static Map<String, net.minecraft.client.model.geom.builders.LayerDefinition> layers;

  @SuppressWarnings("unchecked")
  static void dumpModel(String job, net.minecraft.client.model.geom.ModelPart root) throws Exception {
    com.mojang.blaze3d.vertex.PoseStack ps = new com.mojang.blaze3d.vertex.PoseStack();
    int[] counter = {0};
    walk(job, root, ps, counter);
  }

  @SuppressWarnings("unchecked")
  static void walk(String job, net.minecraft.client.model.geom.ModelPart p, com.mojang.blaze3d.vertex.PoseStack ps, int[] counter) throws Exception {
    if (!p.visible) return;
    ps.pushPose();
    p.translateAndRotate(ps);
    if (!p.skipDraw) {
      List<net.minecraft.client.model.geom.ModelPart.Cube> cubes = (List<net.minecraft.client.model.geom.ModelPart.Cube>) getField(p, "cubes");
      for (net.minecraft.client.model.geom.ModelPart.Cube c : cubes) {
        int id = counter[0]++;
        sb.append(String.format(Locale.ROOT, "P\t%s\t%d\t%s\t%.5f,%.5f,%.5f\t%.5f,%.5f,%.5f\n", job, id, mat(ps.last().pose()), c.minX, c.minY, c.minZ, c.maxX, c.maxY, c.maxZ));
        for (net.minecraft.client.model.geom.ModelPart.Polygon q : c.polygons) {
          if (q == null) continue;
          sb.append(String.format(Locale.ROOT, "Q\t%s\t%d\t%.0f,%.0f,%.0f", job, id, q.normal().x(), q.normal().y(), q.normal().z()));
          for (net.minecraft.client.model.geom.ModelPart.Vertex v : q.vertices())
            sb.append(String.format(Locale.ROOT, "\t%.5f,%.5f,%.5f,%.5f,%.5f", v.x(), v.y(), v.z(), v.u() * texW, v.v() * texH));
          sb.append('\n');
        }
      }
    }
    Map<String, net.minecraft.client.model.geom.ModelPart> ch = (Map<String, net.minecraft.client.model.geom.ModelPart>) getField(p, "children");
    for (net.minecraft.client.model.geom.ModelPart c : new TreeMap<>(ch).values()) walk(job, c, ps, counter);
    ps.popPose();
  }
  static int texW, texH;

  static Object getField(Object o, String f) throws Exception {
    Class<?> c = o.getClass();
    while (c != null) { try { Field x = c.getDeclaredField(f); x.setAccessible(true); return x.get(o); } catch (NoSuchFieldException e) { c = c.getSuperclass(); } }
    throw new NoSuchFieldException(f);
  }

  static Object getStatic(Class<?> c, String f) throws Exception {
    Field x = c.getDeclaredField(f); x.setAccessible(true); return x.get(null);
  }

  static net.minecraft.client.model.geom.ModelPart bake(String layer) throws Exception {
    net.minecraft.client.model.geom.builders.LayerDefinition def = layers.get(layer);
    if (def == null) throw new IllegalStateException("no model layer " + layer);
    Object material = getField(def, "material");
    texW = (int) getField(material, "xTexSize"); texH = (int) getField(material, "yTexSize");
    return def.bakeRoot();
  }

  static void transform(String name, String key, com.mojang.math.Transformation t) {
    sb.append("X\t").append(name).append('\t').append(key).append('\t').append(mat(t.getMatrix())).append('\n');
  }

  static void sprite(String name, net.minecraft.client.resources.model.sprite.SpriteId s) {
    sb.append("K\t").append(name).append('\t').append(s.texture().toString()).append('\n');
  }

  @SuppressWarnings("unchecked")
  static void entities() throws Exception {
    layers = new HashMap<>();
    for (Map.Entry<net.minecraft.client.model.geom.ModelLayerLocation, net.minecraft.client.model.geom.builders.LayerDefinition> e
         : net.minecraft.client.model.geom.LayerDefinitions.createRoots().entrySet()) layers.put(e.getKey().toString(), e.getValue());

    // Chests: closed lid (the model's rest pose).
    dumpModel("chest", bake("minecraft:chest#main"));
    dumpModel("chest_left", bake("minecraft:double_chest_left#main"));
    dumpModel("chest_right", bake("minecraft:double_chest_right#main"));
    for (Direction d : Direction.Plane.HORIZONTAL) transform("chest", d.getName(), net.minecraft.client.renderer.blockentity.ChestRenderer.modelTransformation(d));
    for (net.minecraft.client.renderer.blockentity.state.ChestRenderState.ChestMaterialType m : net.minecraft.client.renderer.blockentity.state.ChestRenderState.ChestMaterialType.values())
      for (net.minecraft.world.level.block.state.properties.ChestType t : net.minecraft.world.level.block.state.properties.ChestType.values())
        sprite("chest/" + m.name() + "/" + t.name(), net.minecraft.client.renderer.Sheets.chooseSprite(m, t));

    // Bell body: at rest (not ringing), no transform.
    dumpModel("bell", bake("minecraft:bell#main"));
    sprite("bell", net.minecraft.client.renderer.blockentity.BellRenderer.BELL_TEXTURE);

    // Banners: pole and bar, and the flag at the middle of its sway (phase 0.25:
    // xRot = (-0.0125 + 0.01 cos(2 pi phase)) pi).
    for (String kind : new String[]{"standing_banner", "wall_banner"}) {
      dumpModel(kind, bake("minecraft:" + kind + "#main"));
      net.minecraft.client.model.geom.ModelPart flag = bake("minecraft:" + kind + "#flag");
      new net.minecraft.client.model.object.banner.BannerFlagModel(flag).setupAnim(0.25f);
      dumpModel(kind + "_flag", flag);
    }
    Object tr = net.minecraft.client.renderer.blockentity.BannerRenderer.TRANSFORMATIONS;
    for (Direction d : Direction.Plane.HORIZONTAL) transform("banner_wall", d.getName(), (com.mojang.math.Transformation) ((net.minecraft.client.renderer.blockentity.WallAndGroundTransformations<?>) tr).wallTransformation(d));
    for (int i = 0; i < 16; i++) transform("banner_ground", Integer.toString(i), (com.mojang.math.Transformation) ((net.minecraft.client.renderer.blockentity.WallAndGroundTransformations<?>) tr).freeTransformations(i));
    sprite("banner_base", net.minecraft.client.renderer.Sheets.BANNER_BASE);
    sprite("banner_pattern_base", net.minecraft.client.renderer.Sheets.BANNER_PATTERN_BASE);

    // Skulls and heads: the renderer's rest state (no yRot/xRot: a placed head's
    // turn is in the transformation; animationPos 0, as when not powered).
    String[][] skulls = {{"skeleton_skull", "SKELETON"}, {"wither_skeleton_skull", "WITHER_SKELETON"},
                         {"zombie_head", "ZOMBIE"}, {"creeper_head", "CREEPER"}, {"piglin_head", "PIGLIN"}};
    for (String[] s : skulls) {
      net.minecraft.client.model.geom.ModelPart root = bake("minecraft:" + s[0] + "#main");
      net.minecraft.client.model.object.skull.SkullModelBase m = s[1].equals("PIGLIN")
        ? new net.minecraft.client.model.object.skull.PiglinHeadModel(root)
        : new net.minecraft.client.model.object.skull.SkullModel(root);
      m.setupAnim(new net.minecraft.client.model.object.skull.SkullModelBase.State());
      dumpModel("skull/" + s[1], root);
    }
    Object st = net.minecraft.client.renderer.blockentity.SkullBlockRenderer.TRANSFORMATIONS;
    for (Direction d : Direction.Plane.HORIZONTAL) transform("skull_wall", d.getName(), (com.mojang.math.Transformation) ((net.minecraft.client.renderer.blockentity.WallAndGroundTransformations<?>) st).wallTransformation(d));
    for (int i = 0; i < 16; i++) transform("skull_ground", Integer.toString(i), (com.mojang.math.Transformation) ((net.minecraft.client.renderer.blockentity.WallAndGroundTransformations<?>) st).freeTransformations(i));
    Map<?, ?> skins = (Map<?, ?>) getStatic(net.minecraft.client.renderer.blockentity.SkullBlockRenderer.class, "SKIN_BY_TYPE");
    for (Map.Entry<?, ?> e : skins.entrySet()) {
      String path = e.getValue().toString().replace("minecraft:textures/", "minecraft:").replaceAll("\\.png$", "");
      sb.append("K\tskull/").append(((Enum<?>) e.getKey()).name()).append('\t').append(path).append('\n');
    }

    // Shulker boxes: closed.
    net.minecraft.client.model.geom.ModelPart shulker = bake("minecraft:shulker_box#main");
    Class<?> sbm = Class.forName("net.minecraft.client.renderer.blockentity.ShulkerBoxRenderer$ShulkerBoxModel");
    Constructor<?> sbc = sbm.getDeclaredConstructor(net.minecraft.client.model.geom.ModelPart.class); sbc.setAccessible(true);
    Object model = sbc.newInstance(shulker);
    Method setup = sbm.getDeclaredMethod("setupAnim", Float.class); setup.setAccessible(true); setup.invoke(model, 0f);
    dumpModel("shulker_box", shulker);
    for (Direction d : Direction.values()) transform("shulker_box", d.getName(), net.minecraft.client.renderer.blockentity.ShulkerBoxRenderer.modelTransform(d));
    sprite("shulker_box/default", net.minecraft.client.renderer.Sheets.DEFAULT_SHULKER_TEXTURE_LOCATION);
    for (net.minecraft.world.item.DyeColor c : net.minecraft.world.item.DyeColor.values()) {
      sprite("shulker_box/" + c.getName(), net.minecraft.client.renderer.Sheets.getShulkerBoxSprite(c));
      sb.append(String.format("D\t%s\t%06x\n", c.getName(), c.getTextureDiffuseColor() & 0xFFFFFF));
    }
  }
}
