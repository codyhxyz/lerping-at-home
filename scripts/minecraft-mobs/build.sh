#!/bin/zsh
# Builds the mobs kit (mobs.metal) from the Minecraft client installed on
# this Mac: the game's own baked models, dumped by running its classes, and
# its skins. Like the textures it is Mojang-derived, so it is built per Mac
# and never committed.
#
#   scripts/minecraft-mobs/build.sh JAR TEXTURES_DIR OUT_DIR
#
# JAR           the client jar, with its version JSON beside it
#               (~/Library/Application Support/minecraft/versions/V/V.jar)
# TEXTURES_DIR  its unpacked assets/minecraft/textures
# OUT_DIR       the Lerping Minecraft folder: reads atlas.txt, writes mobs.metal
#
# Needs: a Java runtime with jdk.compiler at least as new as the jar asks
# for (JAVA_HOME, else the launcher's bundled runtime), python3 with numpy
# and Pillow.
set -u
die() { print -u2 -- "minecraft-mobs: $*"; exit 1 }
(( $# == 3 )) || die "usage: build.sh JAR TEXTURES_DIR OUT_DIR"
HERE=${0:A:h}
JAR=${1:A}; TEX=${2:A}; OUT=${3:A}
[[ -f $JAR ]] || die "no client jar at $JAR"
JSON=${JAR:r}.json
[[ -f $JSON ]] || die "no version JSON beside the jar ($JSON)"
[[ -d $TEX/entity ]] || die "no entity textures in $TEX (run make minecraft first)"
[[ -f $OUT/atlas.txt ]] || die "no atlas.txt in $OUT (run make minecraft first)"
command -v python3 >/dev/null || die "python3 is missing"
python3 -I -c 'import numpy' 2>/dev/null || die "numpy is missing (python3 -m pip install numpy)"
python3 -I -c 'import PIL' 2>/dev/null || die "Pillow is missing (python3 -m pip install Pillow)"

# The version JSON names the Java it needs and the libraries; the launcher
# keeps them under the minecraft folder two levels above versions/V/V.jar.
MC=${JAR:h:h:h}
read -r NEED VERSION CP < <(python3 -I - "$JSON" "$MC" "$JAR" <<'PY'
import json, os, sys
j = json.load(open(sys.argv[1])); mc = sys.argv[2]
paths = [sys.argv[3]]
for lib in j.get('libraries', []):
    a = lib.get('downloads', {}).get('artifact')
    if not a or 'natives' in a['path']: continue
    p = os.path.join(mc, 'libraries', a['path'])
    if os.path.exists(p): paths.append(p)
print(j.get('javaVersion', {}).get('majorVersion', 21), j.get('id', os.path.basename(sys.argv[3])[:-4]), ':'.join(paths))
PY
) || die "cannot read $JSON"
[[ -n ${CP:-} ]] || die "cannot read the libraries from $JSON"

# A Java at least $NEED with the compiler module (the dumper is a source file).
java_major() { "$1" -XshowSettings:properties -version 2>&1 | sed -n 's/^ *java.specification.version = //p' | sed 's/^1\.//' }
JAVA=
for cand in ${JAVA_HOME:+$JAVA_HOME/bin/java} \
            "$MC"/runtime/*/*/*/*/Contents/Home/bin/java(N) "$MC"/runtime/*/*/*/bin/java(N) \
            $(/usr/libexec/java_home -v "$NEED+" 2>/dev/null)/bin/java; do
  [[ -x $cand ]] || continue
  v=$(java_major "$cand"); [[ -n $v ]] && (( v >= NEED )) || continue
  "$cand" --list-modules 2>/dev/null | grep -q '^jdk.compiler@' || continue
  JAVA=$cand; break
done
[[ -n $JAVA ]] || die "no Java $NEED or newer with jdk.compiler (set JAVA_HOME, or start the game once so the launcher installs its runtime)"

TMP=$(mktemp -d -t minecraft-mobs) || die "cannot make a temp directory"
trap 'rm -rf "$TMP"' EXIT
LAYERS=($(python3 -I "$HERE/gen.py" --layers)) || die "gen.py --layers failed"
# Bootstrap writes logs into the working directory: run inside the temp dir.
( cd "$TMP" && "$JAVA" -cp "$CP" "$HERE/Dump.java" $LAYERS > "$TMP/models.txt" 2> "$TMP/dump.err" ) || {
  line=$(grep -m1 '^minecraft-mobs:' "$TMP/dump.err")
  [[ -n $line ]] && { print -u2 -- "$line"; exit 1 }
  err=$(grep -m1 'error:' "$TMP/dump.err")
  [[ -n $err ]] && die "the model dumper does not compile against this jar, the game's classes have moved or a library is missing (${err##*error: })"
  die "the model dumper failed: $(grep -iv warning "$TMP/dump.err" | head -1)"
}
python3 -I "$HERE/gen.py" "$TMP/models.txt" "$OUT/atlas.txt" "$TEX" "$VERSION" "$TMP/mobs.metal" || exit 1
mv -f "$TMP/mobs.metal" "$OUT/mobs.metal" || die "cannot write $OUT/mobs.metal"
print "minecraft-mobs: wrote $OUT/mobs.metal"
