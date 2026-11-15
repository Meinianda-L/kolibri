#!/system/bin/sh
if ! grep -q zram0 /proc/swaps && [ -e /sys/block/zram0 ]; then
  echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null
  echo $(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 2 ))K > /sys/block/zram0/disksize
  mkswap /dev/block/zram0 >/dev/null && swapon -p 10 /dev/block/zram0
fi
SWAPFILE=/data/kolibri.swap
if ! grep -q kolibri.swap /proc/swaps; then
  # fallocate reserves the space without writing 2 GB of zeros into the phone's disk image;
  # dd stays as the fallback.
  [ -f $SWAPFILE ] || { { fallocate -l 2G $SWAPFILE 2>/dev/null || dd if=/dev/zero of=$SWAPFILE bs=1048576 count=2048 2>/dev/null; } \
      && chmod 600 $SWAPFILE && mkswap $SWAPFILE >/dev/null; }
  swapon -p 1 $SWAPFILE 2>/dev/null
fi
echo 100 > /proc/sys/vm/swappiness
# Swap in one page at a time: zram has no seek cost, and read-ahead only adds latency.
echo 0 > /proc/sys/vm/page-cluster
