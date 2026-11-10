#!/usr/bin/env bash
# =====================================================================
# 01_pc_calibrate.sh — 인구 담당. PC(일반 파일시스템)에서 FEMU와 같은 설정으로 돌려
#   1) 최대 사용량과 논리 데이터 (두 사용률로 SPACE_SLOPE, SPACE_FIXED_GIB 를 맞춤)
#   2) 레벨별 데이터 비중 (Lan과 구조가 비슷한지)
#   3) MANIFEST 쓰기 비중
#   4) 걸리는 시간
# 을 재요. pilot.py pcfit 결과로 config.env 의 SPACE_SLOPE·SPACE_FIXED_GIB 를 채우면
# FEMU에서 공간 부족 없이 돌릴 수 있어요.
#
#   ./01_pc_calibrate.sh            TARGET_UTILS 의 모든 사용률로 실행
#   ./01_pc_calibrate.sh 0.70       한 사용률만
#   SCALE=0.05 ./01_pc_calibrate.sh 0.70   크기를 줄여 스크립트만 빠르게 점검 (결과는 쓰지 않음)
#   OVERWRITE_MULT=1 ./01_pc_calibrate.sh  덮어쓰기 양만 바꿈 (키 공간 --num=N 은 그대로)
#
# run 폴더에 남는 것:
#   run_params.txt          스크립트가 최종으로 정한 값 (SCALE, OVERWRITE_MULT, N, 스레드당 writes, ...)
#   cmd_<단계>.txt          실제 실행 명령
#   db_bench_<단계>.stdout / .stderr   db_bench 출력 그대로 (stderr 에 60초 진행 줄·통계), .ts 는 줄마다 받은 시각
#   phase_events.txt        단계 경계 시각 (DB 열림 / 실행 끝 / 대기 끝 / 프로세스 끝 / LOG 저장), lib/runlib.sh 참고
#   options_check_<단계>.txt, rocksdb_LOG_<단계>_head.txt   LOG 의 실효 옵션 대조 결과와 그 근거
#   rocksdb_LOG_<단계>.gz, rocksdb_OPTIONS_<단계>.ini      LOG 전체(SAVE_FULL_LOG=1)·OPTIONS 파일
#   du.csv, levelstats.txt, time.txt, summary.txt
#
# 필요: ./00_build.sh pc, 디스크 여유 = DEV_CAPACITY_GIB 이상
# =====================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OVERWRITE_MULT_FROM_ENV="${OVERWRITE_MULT:-}"     # config.env 를 읽기 전에 밖에서 받은 값을 기록
set -a; . "$HERE/config.env"; set +a
. "$HERE/lib/dbbench_args.sh"
. "$HERE/lib/runlib.sh"

DB_BENCH="$WORK/bin/db_bench_pc"
PC_DB_DIR="${PC_DB_DIR:-$WORK/pcdb}"
SCALE="${SCALE:-1}"
[[ -x "$DB_BENCH" ]] || { echo "먼저 ./00_build.sh pc 를 실행하세요."; exit 1; }

# du 샘플 한 줄: <결과> <phase>. LOG 파일은 빼요 (TorFS에서 FDP 장치에 안 써져서)
du_sample() {
  python3 - "$PC_DB_DIR" "$2" >> "$1/du.csv" <<'PYEOF'
import os, sys, time
d, ph = sys.argv[1], sys.argv[2]
t = s = w = m = 0
try: names = os.listdir(d)
except OSError: names = []
for f in names:
    try: sz = os.path.getsize(os.path.join(d, f))
    except OSError: continue
    if f.startswith("LOG"): continue
    t += sz
    if f.endswith(".sst"): s += sz
    elif f.endswith(".log") and f[:-4].isdigit(): w += sz
    elif f.startswith("MANIFEST"): m += sz
print(f"{time.time():.3f},{ph},{t},{s},{w},{m}")
PYEOF
}

UTILS="${1:-$TARGET_UTILS}"
for U in $UTILS; do
  N_FULL=$(python3 "$HERE/pilot.py" get "$U" N)
  W_FULL=$(python3 "$HERE/pilot.py" get "$U" overwrite_writes_per_thread)
  # SCALE 이 1이 아니면 키 수만 줄이고, 스레드당 writes 는 줄인 N 으로 다시 올림해서 계산해요
  #   (W_FULL x SCALE 을 버림하면 W x THREADS 가 OVERWRITE_MULT x N 보다 조금 모자랄 수 있어서)
  if [[ "$SCALE" == "1" ]]; then N=$N_FULL; W=$W_FULL; else
    N=$(python3 -c "print(int($N_FULL*$SCALE))")
    W=$(python3 -c "import math; print(math.ceil($OVERWRITE_MULT*$N/$THREADS))")
  fi
  OUT="$RESULTS/pc_calib_u$U"; [[ "$SCALE" != "1" ]] && OUT="${OUT}_scale$SCALE"
  rm -rf "$OUT" "$PC_DB_DIR"; mkdir -p "$OUT" "$PC_DB_DIR"
  echo $(( N * (KEY_SIZE + VALUE_SIZE) )) > "$OUT/logical_bytes"
  dbbench_common_args "$U"
  printf '%s\n' "${DB_ARGS[@]}" > "$OUT/db_args.txt"
  write_run_params "$OUT" \
    "script=01_pc_calibrate.sh" "util=$U" "SCALE=$SCALE" \
    "N_full=$N_FULL W_per_thread_full=$W_FULL  (pilot.py calc, SCALE 곱하기 전)" \
    "N(--num)=$N" "W(--writes, 스레드당)=$W" \
    "overwrite 전체 연산 수 = W x THREADS = $((W * THREADS))" \
    "논리 데이터 대비 배수 = W x THREADS / N = $(python3 -c "print(f'{$W*$THREADS/$N:.4f}')")" \
    "logical_bytes = N x (KEY_SIZE + VALUE_SIZE) = $(( N * (KEY_SIZE + VALUE_SIZE) ))" \
    "PC_DB_DIR=$PC_DB_DIR" "RESULTS=$RESULTS" "db_bench=$DB_BENCH"
  echo "[pc] 사용률 $U: N=$N, overwrite 스레드당 $W (x$THREADS = 키 수의 $(python3 -c "print(f'{$W*$THREADS/$N:.2f}')")배), 결과 -> $OUT"

  # 디스크 사용량 샘플러: 5초마다 + 단계가 바뀔 때 (바뀌기 전·후 이름으로 한 번씩). load·overwrite·대기·LOG 저장 내내
  echo "ts,phase,total_bytes,sst_bytes,wal_bytes,manifest_bytes" > "$OUT/du.csv"
  set_phase "$OUT" start
  start_sampler "$OUT" 5 du_sample

  rc=0
  run_dbbench load "$OUT" "$PC_DB_DIR" \
    "$DB_BENCH" --db="$PC_DB_DIR" "${DB_ARGS[@]}" \
    --benchmarks=filluniquerandom,waitforcompaction --threads=1 --num="$N" || rc=$?
  if [[ $rc -ne 0 ]]; then rm -f "$OUT/phase"; wait "$SAMPLER" 2>/dev/null || true; echo "[pc] load 실패 (rc=$rc)"; exit $rc; fi

  run_dbbench overwrite "$OUT" "$PC_DB_DIR" \
    "$DB_BENCH" --db="$PC_DB_DIR" "${DB_ARGS[@]}" --use_existing_db=1 \
    --benchmarks=overwrite,waitforcompaction,levelstats,stats --threads="$THREADS" \
    --num="$N" --writes="$W" || rc=$?

  set_phase "$OUT" end; sleep 2; rm -f "$OUT/phase"; wait "$SAMPLER" 2>/dev/null || true
  if [[ $rc -ne 0 ]]; then echo "[pc] overwrite 실패 (rc=$rc)"; exit $rc; fi
  grep -A 12 "Level Files Size" "$OUT/db_bench_overwrite.stdout" > "$OUT/levelstats.txt" || true
  python3 "$HERE/pilot.py" phasetimes "$OUT" > "$OUT/time.txt"
  cat "$OUT/time.txt"
  python3 "$HERE/pilot.py" pcsummary "$OUT" | tee "$OUT/summary.txt"
done
echo
echo "[pc] 끝. 두 사용률이 다 끝났으면: python3 pilot.py pcfit $RESULTS/pc_calib_u0.70 $RESULTS/pc_calib_u0.93"
echo "     출력된 SPACE_SLOPE·SPACE_FIXED_GIB 를 config.env 에 넣고 python3 pilot.py calc 로 N 을 확인하세요."
