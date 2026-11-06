#!/usr/bin/env bash
# =====================================================================
# 01_pc_calibrate.sh — 인구 담당. PC(일반 파일시스템)에서 FEMU와 같은 설정으로 돌려
#   1) 공간 증폭(SPACE_AMP): 최대 사용량 / 논리 데이터
#   2) 레벨별 데이터 비중 (Lan과 구조가 비슷한지)
#   3) MANIFEST 쓰기 비중
#   4) 걸리는 시간
# 을 재요. 결과로 config.env 의 SPACE_AMP 를 채우면 FEMU에서 공간 부족 없이 돌릴 수 있어요.
#
#   ./01_pc_calibrate.sh            TARGET_UTILS 의 모든 사용률로 실행
#   ./01_pc_calibrate.sh 0.70       한 사용률만
#   SCALE=0.05 ./01_pc_calibrate.sh 0.70   크기를 줄여 스크립트만 빠르게 점검 (결과는 쓰지 않음)
#
# 필요: ./00_build.sh pc, 디스크 여유 = DEV_CAPACITY_GIB 이상
# =====================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "$HERE/config.env"; set +a
. "$HERE/lib/dbbench_args.sh"

DB_BENCH="$WORK/bin/db_bench_pc"
PC_DB_DIR="${PC_DB_DIR:-$WORK/pcdb}"
SCALE="${SCALE:-1}"
[[ -x "$DB_BENCH" ]] || { echo "먼저 ./00_build.sh pc 를 실행하세요."; exit 1; }

UTILS="${1:-$TARGET_UTILS}"
for U in $UTILS; do
  N=$(python3 "$HERE/pilot.py" get "$U" N)
  W=$(python3 "$HERE/pilot.py" get "$U" overwrite_writes_per_thread)
  N=$(python3 -c "print(int($N*$SCALE))"); W=$(python3 -c "print(int($W*$SCALE))")
  OUT="$RESULTS/pc_calib_u$U"; [[ "$SCALE" != "1" ]] && OUT="${OUT}_scale$SCALE"
  rm -rf "$OUT" "$PC_DB_DIR"; mkdir -p "$OUT" "$PC_DB_DIR"
  echo $(( N * (KEY_SIZE + VALUE_SIZE) )) > "$OUT/logical_bytes"
  dbbench_common_args "$U"
  printf '%s\n' "${DB_ARGS[@]}" > "$OUT/db_args.txt"
  echo "[pc] 사용률 $U: N=$N, overwrite 스레드당 $W, 결과 -> $OUT"

  # 디스크 사용량 샘플러 (5초마다, 파일 종류별)
  echo "ts,phase,total_bytes,sst_bytes,wal_bytes,manifest_bytes" > "$OUT/du.csv"
  echo load > "$OUT/phase"
  (
    while [[ -f "$OUT/phase" ]]; do
      python3 - "$PC_DB_DIR" "$(cat "$OUT/phase" 2>/dev/null || echo end)" >> "$OUT/du.csv" <<'EOF'
import os, sys, time
d, ph = sys.argv[1], sys.argv[2]
t = s = w = m = 0
for f in os.listdir(d):
    try: sz = os.path.getsize(os.path.join(d, f))
    except OSError: continue
    t += sz
    if f.endswith(".sst"): s += sz
    elif f.endswith(".log") and f[:-4].isdigit(): w += sz
    elif f.startswith("MANIFEST"): m += sz
print(f"{time.time():.0f},{ph},{t},{s},{w},{m}")
EOF
      sleep 5
    done
  ) &
  SAMPLER=$!
  T0=$(date +%s)

  "$DB_BENCH" --db="$PC_DB_DIR" "${DB_ARGS[@]}" \
    --benchmarks=filluniquerandom,waitforcompaction --threads=1 --num="$N" \
    > "$OUT/db_bench_load.log" 2>&1
  T1=$(date +%s); echo overwrite > "$OUT/phase"

  "$DB_BENCH" --db="$PC_DB_DIR" "${DB_ARGS[@]}" --use_existing_db=1 \
    --benchmarks=overwrite,waitforcompaction,levelstats --threads="$THREADS" \
    --num="$N" --writes="$W" \
    > "$OUT/db_bench_overwrite.log" 2>&1
  T2=$(date +%s)

  rm -f "$OUT/phase"; wait "$SAMPLER" 2>/dev/null || true
  grep -A 12 "Level Files Size" "$OUT/db_bench_overwrite.log" > "$OUT/levelstats.txt" || true
  echo "load_sec=$((T1-T0)) overwrite_sec=$((T2-T1))" > "$OUT/time.txt"
  cat "$OUT/time.txt"
  python3 "$HERE/pilot.py" pcsummary "$OUT" | tee "$OUT/summary.txt"
done
echo
echo "[pc] 끝. summary.txt 의 '공간 증폭' 중 큰 값을 config.env 의 SPACE_AMP 에 넣고"
echo "     python3 pilot.py calc 로 N 이 바뀌었는지 확인한 뒤 지윤에게 넘겨 주세요."
