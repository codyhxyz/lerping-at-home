# Shared by generate.sh and villages.sh: starts the Minecraft dedicated
# server from the installed client jar, headless and offline, in a scratch
# folder, with ticking frozen before the first tick, and stops it cleanly.
# Sourced, not run. The caller sets JAR (the client jar), SEED, HERE (this
# folder) and ROOT (the repo), and defines die and say. Sourcing checks the
# EULA assent and starts the server; afterwards send, await, mark and fail
# talk to it, and server_stop saves, stops and checks the log. A trap kills the server if the
# caller exits early, and the scratch folder is kept when it failed.
set -u
setopt pipefail extendedglob
zmodload zsh/datetime

# The server will not start without eula=true, and that is the user's assent
# to give, not this script's.
if [[ ${MINECRAFT_EULA:-} != true ]]; then
  print -u2 -- "minecraft-world: running the Minecraft server needs your assent to Minecraft's EULA:"
  print -u2 -- "  https://aka.ms/MinecraftEULA"
  print -u2 -- "If you accept it, run again with MINECRAFT_EULA=true in the environment, e.g."
  print -u2 -- "  MINECRAFT_EULA=true ${ZSH_ARGZERO:t} ..."
  exit 1
fi

[[ -f $JAR ]] || die "no client jar at $JAR"
JSON=${JAR:r}.json
[[ -f $JSON ]] || die "no version JSON beside the jar ($JSON)"
command -v python3 >/dev/null || die "python3 is missing"

# The version JSON names the Java it needs and the libraries; the launcher
# keeps them under the minecraft folder two levels above versions/V/V.jar.
# The server needs only the plain jars: native classifiers are left out, OS
# rules are applied for macOS, and every library left must be on disk.
MC=${JAR:h:h:h}
read -r NEED CP < <(python3 -I - "$JSON" "$MC" "$JAR" <<'PY'
import json, os, sys
j = json.load(open(sys.argv[1])); mc = sys.argv[2]
def allowed(rules):
    ok = not rules
    for r in rules or []:
        os_ = r.get('os', {})
        if os_.get('name', 'osx') == 'osx' and 'arch' not in os_:
            ok = r['action'] == 'allow'
    return ok
paths = [sys.argv[3]]; missing = []
for lib in j.get('libraries', []):
    a = lib.get('downloads', {}).get('artifact')
    if not a or ':natives-' in lib['name'] or not allowed(lib.get('rules')): continue
    p = os.path.join(mc, 'libraries', a['path'])
    (paths if os.path.exists(p) else missing).append(p)
if missing:
    sys.exit('missing libraries (start the game once so the launcher downloads them): ' + ', '.join(missing))
print(j.get('javaVersion', {}).get('majorVersion', 21), ':'.join(paths))
PY
) || die "cannot build the classpath from $JSON"
[[ -n ${CP:-} ]] || die "cannot read the libraries from $JSON"
for cls in net/minecraft/server/Main.class net/minecraft/server/dedicated/DedicatedServer.class; do
  unzip -l "$JAR" "$cls" >/dev/null 2>&1 || die "$JAR has no $cls, so it cannot run the dedicated server"
done
read -r VERSION DATA_MAJOR DATA_MINOR < <(unzip -p "$JAR" version.json | python3 -I -c '
import json, sys; v = json.load(sys.stdin); p = v["pack_version"]
print(v["id"], p["data_major"], p.get("data_minor", 0))') || die "cannot read version.json in $JAR"

java_major() { "$1" -XshowSettings:properties -version 2>&1 | sed -n 's/^ *java.specification.version = //p' | sed 's/^1\.//' }
JAVA=
for cand in ${JAVA_HOME:+$JAVA_HOME/bin/java} \
            "$MC"/runtime/*/*/*/*/Contents/Home/bin/java(N) "$MC"/runtime/*/*/*/bin/java(N) \
            $(/usr/libexec/java_home -v "$NEED+" 2>/dev/null)/bin/java; do
  [[ -x $cand ]] || continue
  v=$(java_major "$cand"); [[ -n $v ]] && (( v >= NEED )) || continue
  "$cand" --list-modules 2>/dev/null | /usr/bin/grep -q '^jdk.compiler@' || continue
  JAVA=$cand; break
done
[[ -n $JAVA ]] || die "no Java $NEED or newer with jdk.compiler (set JAVA_HOME, or start the game once so the launcher installs its runtime)"
[[ -f $HERE/Driver.java ]] || die "no Driver.java beside $0"

# Scratch folder. Kept on failure for the full log; removed on success.
mkdir -p "$ROOT/build/minecraft-world/work" || die "cannot make $ROOT/build/minecraft-world/work"
WORK=$(mktemp -d "$ROOT/build/minecraft-world/work/run.XXXXXX") || die "cannot make a scratch folder"
LOG=$WORK/server.out
PID=
OK=0
cleanup() {
  exec 3>&- 2>/dev/null
  if [[ -n $PID ]] && kill -0 $PID 2>/dev/null; then
    kill -TERM $PID 2>/dev/null
    for i in {1..100}; do kill -0 $PID 2>/dev/null || break; sleep 0.2; done
    kill -0 $PID 2>/dev/null && kill -KILL $PID 2>/dev/null
  fi
  local left=$(pgrep -f -- "--universe $WORK" 2>/dev/null)
  [[ -n $left ]] && { kill -KILL ${=left} 2>/dev/null; print -u2 -- "minecraft-world: killed leftover server process $left" }
  if (( OK )); then rm -rf "$WORK"; else print -u2 -- "minecraft-world: scratch folder kept for inspection: $WORK"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
fail() {
  print -u2 -- "minecraft-world: $*"
  if [[ -s $LOG ]]; then print -u2 -- "---- server log (last 40 lines) ----"; tail -40 "$LOG" >&2; print -u2 -- "----"; fi
  exit 1
}

PORT=$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])') || die "cannot find a free loopback port"

# server.properties. Values are written with Java properties escaping so any
# printable seed text reaches the game unchanged.
python3 -I - "$WORK/server.properties" "$SEED" "$PORT" <<'PY' || die "cannot write server.properties"
import sys
def esc(s):
    out = []
    for i, c in enumerate(s):
        if c in '\\:=#!': out.append('\\' + c)
        elif c == ' ' and i == 0: out.append('\\ ')
        elif ord(c) > 126 or ord(c) < 32:
            b = c.encode('utf-16-be')
            out.append(''.join('\\u%02x%02x' % (b[i], b[i + 1]) for i in range(0, len(b), 2)))
        else: out.append(c)
    return ''.join(out)
props = {
    'level-seed': sys.argv[2], 'level-name': 'world', 'level-type': 'minecraft:normal',
    'generate-structures': 'true', 'difficulty': 'peaceful', 'gamemode': 'survival',
    'online-mode': 'false', 'server-ip': '127.0.0.1', 'server-port': sys.argv[3],
    'white-list': 'true', 'enforce-whitelist': 'true', 'max-players': '1',
    'enable-status': 'false', 'enable-query': 'false', 'enable-rcon': 'false',
    'management-server-enabled': 'false', 'enable-jmx-monitoring': 'false',
    'log-ips': 'false', 'spawn-protection': '0', 'view-distance': '2', 'simulation-distance': '2',
    'pause-when-empty-seconds': '0', 'max-tick-time': '-1', 'function-permission-level': '4',
    'sync-chunk-writes': 'true', 'region-file-compression': 'deflate',
}
with open(sys.argv[1], 'w', encoding='ascii') as f:
    for k, v in props.items(): f.write(f'{k}={esc(v)}\n')
PY
print 'eula=true' > "$WORK/eula.txt"

# A data pack whose load function runs before the first level tick (functions
# tick ahead of levels in MinecraftServer.tickChildren). It freezes ticking and
# turns off everything that changes blocks or entities over time, so the
# chunks are saved exactly as worldgen left them. Console commands would only
# run after one tick had already happened. Removed from the save at the end.
PACK=$WORK/world/datapacks/lerping-still
mkdir -p "$PACK/data/lerping/function" "$PACK/data/minecraft/tags/function" || die "cannot write the data pack"
print -r -- "{\"pack\": {\"description\": \"Lerping: keep generated chunks still\", \"min_format\": [$DATA_MAJOR, $DATA_MINOR], \"max_format\": [$DATA_MAJOR, $DATA_MINOR]}}" > "$PACK/pack.mcmeta"
print -r -- '{"values": ["lerping:still"]}' > "$PACK/data/minecraft/tags/function/load.json"
cat > "$PACK/data/lerping/function/still.mcfunction" <<'MC'
tick freeze
gamerule random_tick_speed 0
gamerule advance_time false
gamerule advance_weather false
gamerule spawn_mobs false
gamerule spawn_monsters false
gamerule spawn_patrols false
gamerule spawn_phantoms false
gamerule spawn_wandering_traders false
gamerule spawn_wardens false
gamerule mob_griefing false
gamerule fire_spread_radius_around_player 0
gamerule water_source_conversion false
gamerule lava_source_conversion false
gamerule spread_vines false
gamerule spawner_blocks_work false
gamerule raids false
MC

T0=$EPOCHREALTIME
mkfifo "$WORK/console" || die "cannot make the console pipe"
NOWEB=http://127.0.0.1:9
( cd "$WORK" && exec "$JAVA" -Xms1G -Xmx6G -Djava.awt.headless=true \
    --sun-misc-unsafe-memory-access=allow --enable-native-access=ALL-UNNAMED \
    -Djava.io.tmpdir="$WORK/tmp" -Djna.tmpdir="$WORK/tmp/jna" \
    -Dminecraft.api.session.host=$NOWEB -Dminecraft.api.services.host=$NOWEB -Dminecraft.api.profiles.host=$NOWEB \
    --add-opens java.base/java.lang=ALL-UNNAMED \
    -cp "$CP" "$HERE/Driver.java" --nogui --universe "$WORK" --world world \
    < "$WORK/console" > "$LOG" 2>&1 ) &
PID=$!
mkdir -p "$WORK/tmp"
exec 3> "$WORK/console"

# The console is a pipe in and a log out. send writes a command; await
# reads new log lines until one matches, keeping the lines before it in SEG.
send() { print -r -u3 -- "$1" || fail "the server stopped reading its console" }
LINES_READ=0; SEG=; MATCH=
await() {
  local pat=$1 limit=${2:-120} t0=$EPOCHREALTIME n
  while true; do
    n=$(tail -n +$(( LINES_READ + 1 )) "$LOG" 2>/dev/null | /usr/bin/grep -n -m1 -E -- "$pat" | cut -d: -f1)
    if [[ -n $n ]]; then
      SEG=$(tail -n +$(( LINES_READ + 1 )) "$LOG" | head -n $n)
      MATCH=${SEG##*$'\n'}
      (( LINES_READ += n ))
      return 0
    fi
    kill -0 $PID 2>/dev/null || fail "the server exited while waiting for: $pat"
    (( EPOCHREALTIME - t0 < limit )) || fail "timed out after ${limit}s waiting for: $pat"
    sleep 0.2
  done
}
MARKS=0
mark() { (( ++MARKS )); send "say lerping-mark-$MARKS-$$"; await "\[Server\] lerping-mark-$MARKS-$$\$" ${1:-120} }

await 'Done \([0-9.]+s\)! For help' 600
/usr/bin/grep -q 'Found new data pack file/lerping-still' "$LOG" || fail "the server did not load the lerping-still data pack"
SERVER_VERSION=$(sed -n 's/.*Starting minecraft server version \(.*\)$/\1/p' "$LOG" | head -1)
[[ -n $SERVER_VERSION ]] || fail "the log has no server version line"

send 'tick query'; send 'gamerule random_tick_speed'; send 'seed'
mark
[[ $SEG == *'The game is frozen'* ]] || fail "ticking is not frozen (tick query said: $(print -r -- $SEG | /usr/bin/grep -iE 'tick|frozen|running' | head -2))"
[[ $SEG == *'random_tick_speed is currently set to: 0'* ]] || fail "random_tick_speed is not 0"
RESOLVED_SEED=$(print -r -- "$SEG" | sed -n 's/.*Seed: \[\(-\{0,1\}[0-9]*\)\].*/\1/p' | head -1)
[[ -n $RESOLVED_SEED ]] || fail "the seed command printed no seed"
say "server $SERVER_VERSION up, seed $SEED -> $RESOLVED_SEED, ticking frozen"

# Saves every dimension, stops the server and checks what it logged.
server_stop() {
  send 'save-all flush'
  await 'Saved the game|Saving failed|Unable to save' 1200
  [[ $MATCH == *'Saved the game'* ]] || fail "save failed: $MATCH"
  send 'stop'
  exec 3>&-
  for i in {1..1500}; do kill -0 $PID 2>/dev/null || break; sleep 0.2; done
  kill -0 $PID 2>/dev/null && fail "the server did not stop within 300s"
  wait $PID; rc=$?
  PID=
  (( rc == 0 )) || fail "the server exited with status $rc"
  /usr/bin/grep -q 'All dimensions are saved' "$LOG" || fail "the server stopped without saving every dimension"
  [[ -z $(pgrep -f -- "--universe $WORK") ]] || fail "a server process is still running"
  # The one expected error: authlib fetches Mojang's public keys at start-up,
  # and that request goes to the closed loopback port above and is refused.
  ERRS=$(/usr/bin/grep -E '/(ERROR|FATAL)\]' "$LOG" | /usr/bin/grep -v 'Yggdrasil Key Fetcher/ERROR\]: Failed to request yggdrasil public key')
  [[ -z $ERRS ]] || fail "the server logged errors:"$'\n'"$ERRS"
  WEB=$(/usr/bin/grep -oE 'https?://[A-Za-z0-9.:-]+' "$LOG" | sort -u | /usr/bin/grep -v '^http://127\.0\.0\.1:9$')
  [[ -z $WEB ]] || fail "the server named a web host other than the closed loopback one: $WEB"
}
