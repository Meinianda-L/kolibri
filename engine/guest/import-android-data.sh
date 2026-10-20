#!/system/bin/sh
# Runs inside a Kolibri guest as root. Imports apps (APK + splits), their data, external
# data and OBB from another Android /data partition (ext4) mounted read-only at $SRC.
# Usage: import-android-data.sh <src-mount> <pkg>...
SRC=$1; shift
for P in "$@"; do
  echo "== $P"
  dir=$(ls -d $SRC/app/*/$P-* 2>/dev/null | head -1)
  [ -z "$dir" ] && { echo "  no apk, skipped"; continue; }
  sid=$(pm install-create -r -g | grep -o '[0-9][0-9]*')
  for f in $dir/*.apk; do
    cat "$f" | pm install-write -S $(stat -c %s "$f") $sid $(basename "$f") - >/dev/null || echo "  write failed: $f"
  done
  pm install-commit $sid | sed 's/^/  install: /'
  am force-stop $P
  uid=$(stat -c %u /data/data/$P 2>/dev/null)
  [ -z "$uid" ] && { echo "  not installed, data skipped"; continue; }
  cgid=$((uid - 10000 + 20000))
  # Internal data (credential- and device-protected); the old lib symlink is left out.
  for base in data/$P user_de/0/$P; do
    [ -d $SRC/$base ] || continue
    dst=/data/${base#data/}; [ "$base" = "data/$P" ] && dst=/data/data/$P
    for item in $SRC/$base/* $SRC/$base/.[!.]*; do
      [ -e "$item" ] || continue
      [ "$(basename $item)" = lib ] && continue
      cp -a "$item" $dst/
    done
    chown -R $uid:$uid $dst
    for c in cache code_cache; do [ -d $dst/$c ] && chown -R $uid:$cgid $dst/$c; done
    restorecon -RF $dst
  done
  # External data and OBB (shared storage).
  for kind in data:1078 obb:1079; do
    k=${kind%%:*}; g=${kind##*:}; s=$SRC/media/0/Android/$k/$P
    [ -d $s ] || continue
    d=/data/media/0/Android/$k/$P
    mkdir -p $d && cp -a $s/. $d/ && chown -R $uid:$g $d && restorecon -RF $d
    echo "  $k: $(du -sm $d | cut -f1) MB"
  done
  echo "  done"
done
echo "ALL DONE"
