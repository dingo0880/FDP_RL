#!/usr/bin/env bash
# =====================================================================
# 00_build.sh — RocksDB 7.2.2 + Lan 패치로 db_bench 빌드
#
#   ./00_build.sh pc     인구: PC용 (TorFS 없음, 일반 파일시스템)
#   ./00_build.sh femu   지윤: FEMU 게스트용 (TorFS + Single PID 패치)
#
# 결과: $WORK/bin/db_bench_pc 또는 $WORK/bin/db_bench_torfs
# 필요한 것(직접 설치):
#   공통: git, make, g++, libgflags-dev, libsnappy-dev, liblz4-dev, libzstd-dev, zlib1g-dev
#   femu: + liburing, xNVMe (TorFS README / Lan 저장소 compile/readme.md 참고)
# =====================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "$HERE/config.env"; set +a

MODE="${1:-}"
if [[ "$MODE" != "pc" && "$MODE" != "femu" ]]; then
  echo "사용법: $0 pc|femu"; exit 1
fi

JOBS="${JOBS:-$(nproc)}"
SRC="$WORK/src"; BIN="$WORK/bin"
mkdir -p "$SRC" "$BIN"

# 1) Lan 저장소 (패치와 OPTIONS 파일 참고용)
if [[ ! -d "$SRC/lan_bench" ]]; then
  git clone https://github.com/sijielan/FDP_Benchmarking.git "$SRC/lan_bench"
fi
LAN_PATCH="$SRC/lan_bench/RocksDB/compile/rocksDB_patch.txt"

# 2) RocksDB 7.2.2 (모드마다 따로 받음: TorFS는 빌드 시 플러그인으로 들어가서)
TREE="$SRC/rocksdb-$MODE"
if [[ ! -d "$TREE" ]]; then
  git clone --depth 1 --branch "$ROCKSDB_TAG" https://github.com/facebook/rocksdb.git "$TREE"
  ( cd "$TREE" && git apply "$LAN_PATCH" )
  echo "[build] Lan 패치 적용: L0–L3 -> MEDIUM, L4 -> LONG, L5+ -> EXTREME"
fi

PLUGINS=""
if [[ "$MODE" == "femu" ]]; then
  # 3) TorFS: Lan이 쓴 커밋 + Single PID 패치(TORFS_FORCE_PID 환경변수)
  if [[ ! -d "$TREE/plugin/torfs" ]]; then
    git clone https://github.com/SamsungDS/TorFS.git "$TREE/plugin/torfs"
    ( cd "$TREE/plugin/torfs" && git checkout -q "$TORFS_COMMIT" \
        && git apply "$HERE/patches/torfs_force_pid.patch" )
    echo "[build] TorFS $TORFS_COMMIT + torfs_force_pid.patch 적용"
  fi
  if ! pkg-config --exists xnvme 2>/dev/null && [[ ! -e /usr/local/lib/libxnvme.so && ! -e /usr/lib/libxnvme.so ]]; then
    echo "[build] 경고: xNVMe를 못 찾았어요. 설치 후 다시 실행하세요 (https://xnvme.io)."; exit 1
  fi
  PLUGINS="torfs"
fi

# 4) 빌드
#   GCC 13 이상에서 옛 RocksDB가 <cstdint> 누락으로 실패하는 경우가 있어 미리 넣어 둠
cd "$TREE"
DEBUG_LEVEL=0 ROCKSDB_DISABLE_JEMALLOC=true DISABLE_WARNING_AS_ERROR=1 \
EXTRA_CXXFLAGS="-include cstdint" ROCKSDB_PLUGINS="$PLUGINS" \
  make -j"$JOBS" db_bench

OUT="$BIN/db_bench_$([[ $MODE == femu ]] && echo torfs || echo pc)"
cp db_bench "$OUT"
echo "[build] 완료: $OUT"
"$OUT" --version 2>/dev/null || true
