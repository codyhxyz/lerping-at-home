// Dumps the game's own baked entity models: for each model layer named on the
// command line, every part's pose and every cube's faces with their corner
// positions and skin pixels, as the client bakes them from
// LayerDefinitions.createRoots(). Run by build.sh against the installed jar;
// gen.py reads the output. Exits 1 with one line on stderr if the game's
// classes or fields have moved or a layer is missing.
import java.lang.reflect.*;
import java.util.*;
import net.minecraft.client.model.geom.*;
import net.minecraft.client.model.geom.builders.*;

@SuppressWarnings("unchecked")
public class Dump {
  static Object get(Object o, String f) throws Exception {
    Class<?> c = o.getClass();
    while (c != null) { try { Field x = c.getDeclaredField(f); x.setAccessible(true); return x.get(o); } catch (NoSuchFieldException e) { c = c.getSuperclass(); } }
    throw new NoSuchFieldException(f);
  }
  static StringBuilder sb = new StringBuilder();
  static void part(String name, ModelPart p, float tw, float th, String ind) throws Exception {
    sb.append(String.format(Locale.ROOT, "%sP %s pos=%.4f,%.4f,%.4f rot=%.6f,%.6f,%.6f scale=%.4f,%.4f,%.4f vis=%b\n", ind, name, p.x,p.y,p.z,p.xRot,p.yRot,p.zRot,p.xScale,p.yScale,p.zScale,p.visible));
    List<ModelPart.Cube> cubes = (List<ModelPart.Cube>) get(p, "cubes");
    for (ModelPart.Cube c : cubes) {
      sb.append(String.format(Locale.ROOT, "%s  C min=%.4f,%.4f,%.4f max=%.4f,%.4f,%.4f\n", ind, c.minX,c.minY,c.minZ,c.maxX,c.maxY,c.maxZ));
      for (ModelPart.Polygon q : c.polygons) {
        if (q == null) continue;
        sb.append(String.format(Locale.ROOT, "%s    F n=%.0f,%.0f,%.0f", ind, q.normal().x(), q.normal().y(), q.normal().z()));
        for (ModelPart.Vertex v : q.vertices()) sb.append(String.format(Locale.ROOT, " [%.4f,%.4f,%.4f|%.3f,%.3f]", v.x(),v.y(),v.z(), v.u()*tw, v.v()*th));
        sb.append("\n");
      }
    }
    Map<String, ModelPart> ch = (Map<String, ModelPart>) get(p, "children");
    for (Map.Entry<String, ModelPart> e : ch.entrySet()) part(e.getKey(), e.getValue(), tw, th, ind + "  ");
  }
  public static void main(String[] a) {
    try { run(a); }
    catch (Throwable t) {
      Throwable c = t; while (c.getCause() != null) c = c.getCause();
      System.err.println("minecraft-mobs: the game's model classes have moved (" + c.getClass().getSimpleName() + ": " + c.getMessage() + ")");
      System.exit(1);
    }
  }
  static void run(String[] a) throws Exception {
    net.minecraft.SharedConstants.tryDetectVersion(); net.minecraft.server.Bootstrap.bootStrap();
    Map<ModelLayerLocation, LayerDefinition> roots = LayerDefinitions.createRoots();
    List<String> want = Arrays.asList(a);
    TreeMap<String, LayerDefinition> sorted = new TreeMap<>();
    for (Map.Entry<ModelLayerLocation, LayerDefinition> e : roots.entrySet()) sorted.put(e.getKey().toString(), e.getValue());
    for (Map.Entry<String, LayerDefinition> e : sorted.entrySet()) {
      String k = e.getKey();
      if (want.isEmpty()) { sb.append(k).append("\n"); continue; }
      boolean ok = false; for (String w : want) if (k.equals(w)) ok = true;
      if (!ok) continue;
      Object mat = get(e.getValue(), "material");
      int tw = (int) get(mat, "xTexSize"), th = (int) get(mat, "yTexSize");
      sb.append("LAYER ").append(k).append(" tex=").append(tw).append("x").append(th).append("\n");
      part("root", e.getValue().bakeRoot(), tw, th, "");
    }
    for (String w : want) if (!sorted.containsKey(w)) throw new IllegalStateException("no model layer " + w);
    System.out.print(sb);
  }
}
