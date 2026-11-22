// Runs the game's dedicated server (net.minecraft.server.Main, unchanged) and
// adds two console commands:
//
//   lerping generate X0 Z0 X1 Z1     (chunk coordinates, inclusive)
//   lerping villages X0 Z0 X1 Z1     (block coordinates, inclusive)
//
// `villages` lists every village the game places in the area, without
// generating terrain: for each cell of the villages structure set's random
// spread it asks the game's placement for the cell's candidate chunk, loads
// that chunk to STRUCTURE_STARTS, and reports the start the game made there
// (type, bounding box, and every jigsaw piece by template), one line each.
// This is what `locate` does, for every village instead of the nearest.
//
// About `generate`:
// Why: the game decorates a chunk (trees, ores, plants, the FEATURES step) by
// writing into its eight neighbours too, and a feature looks at what is
// already there. When the server generates many chunks at once, neighbours
// decorate in whatever order its threads reach them, so two runs from the
// same seed differ wherever features meet across a chunk border; measured on
// the shared world, 463,586 blocks in 1,603 of 4,225 chunks. Every step
// before FEATURES depends only on the seed and the chunk's position, so this
// brings the whole area to CARVERS in parallel, then runs FEATURES one chunk at
// a time in row order, then brings the square to FULL one chunk at a time.
// Each step is the game's own; only the order is fixed.
//
// Every other console line is passed to the server untouched. Progress and
// the result are logged as lines starting "lerping-generate:". Run as a
// source file with the client jar and its libraries on the class path.
import com.mojang.logging.LogUtils;
import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.io.PipedInputStream;
import java.io.PipedOutputStream;
import java.io.Writer;
import java.lang.reflect.Field;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import net.minecraft.core.Holder;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.level.ChunkResult;
import net.minecraft.server.level.ServerChunkCache;
import net.minecraft.world.level.ChunkPos;
import net.minecraft.world.level.chunk.ChunkAccess;
import net.minecraft.world.level.chunk.ChunkGeneratorStructureState;
import net.minecraft.world.level.chunk.LevelChunk;
import net.minecraft.world.level.chunk.status.ChunkStatus;
import net.minecraft.world.level.levelgen.structure.BoundingBox;
import net.minecraft.world.level.levelgen.structure.PoolElementStructurePiece;
import net.minecraft.world.level.levelgen.structure.StructurePiece;
import net.minecraft.world.level.levelgen.structure.StructureSet;
import net.minecraft.world.level.levelgen.structure.StructureStart;
import net.minecraft.world.level.levelgen.structure.placement.RandomSpreadStructurePlacement;
import org.slf4j.Logger;

public class Driver {
    // Rings of chunks around the square, in chunks. FEATURES writes one chunk
    // out and light reaches at most 15 blocks, so a square chunk's blocks and
    // light are settled by the decoration of the square plus one ring. Three
    // rings are decorated in order so the chunks FULL pulls in beside the
    // square are settled too; CARVERS goes one ring further for them to read.
    static final int FEATURE_RING = 3;
    static final int CARVER_RING = FEATURE_RING + 1;

    static Logger log;

    public static void main(String[] args) throws Exception {
        InputStream real = System.in;
        PipedInputStream console = new PipedInputStream(1 << 20);
        PipedOutputStream toConsole = new PipedOutputStream(console);
        System.setIn(console);
        Thread relay = new Thread(() -> relay(real, toConsole), "Lerping console");
        relay.setDaemon(true);
        relay.start();
        net.minecraft.server.Main.main(args);
    }

    static void relay(InputStream in, PipedOutputStream out) {
        try (BufferedReader r = new BufferedReader(new InputStreamReader(in, StandardCharsets.UTF_8));
             Writer w = new OutputStreamWriter(out, StandardCharsets.UTF_8)) {
            String line;
            while ((line = r.readLine()) != null) {
                if (line.startsWith("lerping ")) {
                    handle(line);
                } else {
                    w.write(line);
                    w.write('\n');
                    w.flush();
                }
            }
        } catch (Exception e) {
            logger().error("lerping-generate: FAILED: console relay stopped", e);
        }
    }

    static Logger logger() {
        if (log == null) log = LogUtils.getLogger();
        return log;
    }

    static void handle(String line) throws Exception {
        String[] a = line.trim().split("\\s+");
        if (a.length != 6 || !(a[1].equals("generate") || a[1].equals("villages"))) {
            logger().error("lerping-generate: FAILED: usage: lerping generate|villages X0 Z0 X1 Z1 (got: {})", line);
            return;
        }
        boolean villages = a[1].equals("villages");
        int x0 = Integer.parseInt(a[2]), z0 = Integer.parseInt(a[3]);
        int x1 = Integer.parseInt(a[4]), z1 = Integer.parseInt(a[5]);
        MinecraftServer server = server();
        server.execute(() -> {
            try {
                if (villages) villages(server, x0, z0, x1, z1);
                else generate(server, x0, z0, x1, z1);
            } catch (Throwable e) {
                logger().error((villages ? "lerping-villages" : "lerping-generate") + ": FAILED: " + e, e);
            }
        });
    }

    // The server object is not published anywhere static: Main keeps it in a
    // local and MinecraftServer.spin hands it to the server thread through an
    // AtomicReference captured by the thread's Runnable. Reading that needs
    // --add-opens java.base/java.lang=ALL-UNNAMED.
    static MinecraftServer server() throws Exception {
        for (Thread t : Thread.getAllStackTraces().keySet()) {
            if (!t.getName().equals(MinecraftServer.SERVER_THREAD_NAME)) continue;
            Field holderField = Thread.class.getDeclaredField("holder");
            holderField.setAccessible(true);
            Object holder = holderField.get(t);
            Field taskField = holder.getClass().getDeclaredField("task");
            taskField.setAccessible(true);
            Object task = taskField.get(holder);
            for (Field f : task.getClass().getDeclaredFields()) {
                f.setAccessible(true);
                if (f.get(task) instanceof AtomicReference<?> ref && ref.get() instanceof MinecraftServer s) return s;
            }
            throw new IllegalStateException("the server thread's task holds no server; MinecraftServer.spin has changed");
        }
        throw new IllegalStateException("no thread named " + MinecraftServer.SERVER_THREAD_NAME);
    }

    // Runs on the server thread; getChunk blocks it while running the
    // chunk system's tasks, as the game's own forceload does.
    static void generate(MinecraftServer server, int x0, int z0, int x1, int z1) {
        ServerChunkCache cache = server.overworld().getChunkSource();
        long t0 = System.nanoTime();

        // managedBlock runs one main-thread task per check, so the check is a
        // counter: scanning every future each time made this phase quadratic.
        List<CompletableFuture<ChunkResult<ChunkAccess>>> carved = new ArrayList<>();
        AtomicInteger pending = new AtomicInteger();
        for (int z = z0 - CARVER_RING; z <= z1 + CARVER_RING; z++) {
            for (int x = x0 - CARVER_RING; x <= x1 + CARVER_RING; x++) {
                var f = cache.getChunkFuture(x, z, ChunkStatus.CARVERS, true);
                pending.incrementAndGet();
                f.whenComplete((r, e) -> pending.decrementAndGet());
                carved.add(f);
            }
        }
        server.managedBlock(() -> pending.get() == 0);
        for (var f : carved) {
            ChunkResult<ChunkAccess> r = f.join();
            if (!r.isSuccess()) throw new IllegalStateException("CARVERS failed: " + r.getError());
        }
        logger().info("lerping-generate: carvers {} chunks ({} s)", carved.size(), secs(t0));

        int n = 0, total = (x1 - x0 + 1 + 2 * FEATURE_RING) * (z1 - z0 + 1 + 2 * FEATURE_RING);
        for (int z = z0 - FEATURE_RING; z <= z1 + FEATURE_RING; z++) {
            for (int x = x0 - FEATURE_RING; x <= x1 + FEATURE_RING; x++) {
                ChunkAccess c = cache.getChunk(x, z, ChunkStatus.FEATURES, true);
                if (c == null || !c.getPersistedStatus().isOrAfter(ChunkStatus.FEATURES))
                    throw new IllegalStateException("FEATURES failed at chunk " + x + " " + z);
                if (++n % 512 == 0) logger().info("lerping-generate: features {} / {} ({} s)", n, total, secs(t0));
            }
        }
        logger().info("lerping-generate: features {} chunks ({} s)", n, secs(t0));

        int full = 0;
        for (int z = z0; z <= z1; z++) {
            for (int x = x0; x <= x1; x++) {
                ChunkAccess c = cache.getChunk(x, z, ChunkStatus.FULL, true);
                if (!(c instanceof LevelChunk)) throw new IllegalStateException("FULL failed at chunk " + x + " " + z);
                full++;
            }
        }
        logger().info("lerping-generate: done {} full chunks ({} s)", full, secs(t0));
    }

    static void villages(MinecraftServer server, int bx0, int bz0, int bx1, int bz1) {
        ServerChunkCache cache = server.overworld().getChunkSource();
        ChunkGeneratorStructureState state = cache.getGeneratorState();
        long seed = state.getLevelSeed(), t0 = System.nanoTime();
        int cx0 = bx0 >> 4, cz0 = bz0 >> 4, cx1 = bx1 >> 4, cz1 = bz1 >> 4;
        int sets = 0, candidates = 0, found = 0;
        for (Holder<StructureSet> set : state.possibleStructureSets()) {
            StructureSet s = set.value();
            if (s.structures().stream().noneMatch(e -> e.structure().getRegisteredName().contains("village_"))) continue;
            if (!(s.placement() instanceof RandomSpreadStructurePlacement rs))
                throw new IllegalStateException(set.getRegisteredName() + " is not placed by random spread");
            sets++;
            int sp = rs.spacing();
            for (int rz = Math.floorDiv(cz0, sp); rz <= Math.floorDiv(cz1, sp); rz++) {
                for (int rx = Math.floorDiv(cx0, sp); rx <= Math.floorDiv(cx1, sp); rx++) {
                    // Takes any chunk in the cell and returns the cell's candidate.
                    ChunkPos p = rs.getPotentialStructureChunk(seed, rx * sp, rz * sp);
                    if (p.x() < cx0 || p.x() > cx1 || p.z() < cz0 || p.z() > cz1) continue;
                    if (!rs.isStructureChunk(state, p.x(), p.z())) continue;
                    candidates++;
                    ChunkAccess c = cache.getChunk(p.x(), p.z(), ChunkStatus.STRUCTURE_STARTS, true);
                    boolean any = false;
                    for (StructureSet.StructureSelectionEntry e : s.structures()) {
                        StructureStart st = c.getStartForStructure(e.structure().value());
                        if (st == null || !st.isValid()) continue;
                        any = true;
                        found++;
                        BoundingBox b = st.getBoundingBox();
                        StringBuilder pieces = new StringBuilder();
                        for (StructurePiece piece : st.getPieces()) {
                            if (pieces.length() > 0) pieces.append('|');
                            pieces.append(piece instanceof PoolElementStructurePiece pe ? pe.getElement().toString() : piece.getClass().getSimpleName());
                        }
                        logger().info("lerping-village: {} {} {} {} {} {} {} {} {} {} {}", e.structure().getRegisteredName(),
                                p.x(), p.z(), b.minX(), b.minY(), b.minZ(), b.maxX(), b.maxY(), b.maxZ(), st.getPieces().size(), pieces);
                    }
                    if (!any) logger().info("lerping-village-none: {} {}", p.x(), p.z());
                }
            }
        }
        if (sets == 0) throw new IllegalStateException("no structure set places villages");
        logger().info("lerping-villages: done {} villages in {} candidate chunks from {} structure sets ({} s)", found, candidates, sets, secs(t0));
    }

    static String secs(long t0) {
        return String.format("%.1f", (System.nanoTime() - t0) / 1e9);
    }
}
