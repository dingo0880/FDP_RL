#!/usr/bin/env bash
# =====================================================================
# 02_femu_run.sh — 지윤 담당. FEMU 게스트 안에서 실행.
#   정책 2개(single, lan) x 사용률(TARGET_UTILS) 를 한 번씩 돌리고
#   장치 카운터(host/media 쓰기량)와 RUH별 상태를 SAMPLE_SEC 마다 기록해요.
#
#   sudo -E ./02_femu_run.sh                 전부 (single·lan x 모든 사용률)
#   sudo -E ./02_femu_run.sh lan 0.93        하나만
#   REP=2 sudo -E ./02_femu_run.sh ...       두 번째 반복 (폴더 이름 끝에 _r2)
#
# 보통은 호스트에서 ./03_host_loop.sh 로 돌려요. 그러면 run마다 FEMU를 새로 띄우고
# 이 스크립트를 FRESH_FEMU=1 로 run 하나씩 불러요.
#
# 주의: NG_DEV 장치의 데이터가 전부 지워져요. FEMU 전용 장치에서만 돌리세요.
# 필요: ./00_build.sh femu, nvme-cli(fdp 지원), python3
# =====================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "$HERE/config.env"; set +a
. "$HERE/lib/dbbench_args.sh"

DB_BENCH="$WORK/bin/db_bench_torfs"
TORFS_DB_DIR="${TORFS_DB_DIR:-$WORK/torfs_db}"   # TorFS가 쓰는 로컬 보조 폴더 (Lan도 이렇게 씀)
FS_URI="torfs:xnvme:${NG_DEV}?be=io_uring_cmd"
[[ -x "$DB_BENCH" ]] || { echo "먼저 ./00_build.sh femu 를 실행하세요."; exit 1; }

POLICIES="${1:-single lan}"
UTILS="${2:-$TARGET_UTILS}"
REP="${REP:-1}"
SUFFIX=""; [[ "$REP" != "1" ]] && SUFFIX="_r$REP"

if [[ "${FORCE:-0}" != "1" ]]; then
  echo "장치 $NG_DEV ($NVME_DEV) 의 데이터가 지워져요. 계속하려면 yes 를 입력하세요."
  read -r ans; [[ "$ans" == "yes" ]] || exit 1
fi

# 카운터 읽기가 되는지 먼저 확인
if ! python3 "$HERE/pilot.py" counters >/dev/null; then
  echo "장치 카운터를 못 읽었어요. config.env 의 COUNTER_METHOD / COUNTER_CMD 를 확인하세요."; exit 1
fi

sample() {   # $1 = run 폴더
  local d="$1" ph ts
  ph=$(cat "$d/phase" 2>/dev/null || echo end); ts=$(date +%s)
  read -r H M < <(python3 "$HERE/pilot.py" counters)
  echo "$ts,$ph,$H,$M" >> "$d/counters.csv"
  if [[ "$RUH_METHOD" != "none" ]]; then
    python3 "$HERE/pilot.py" ruh 2>/dev/null | while read -r pid val; do
      echo "$ts,$ph,$pid,$val" >> "$d/ruh.csv"
    done
  fi
}

for POL in $POLICIES; do
  for U in $UTILS; do
    RUN="$RESULTS/${POL}_u${U}${SUFFIX}"
    if [[ -e "$RUN" ]]; then echo "[건너뜀] $RUN 이 이미 있어요 (지우고 다시 돌리려면 폴더 삭제)"; continue; fi
    mkdir -p "$RUN"

    # 1) FEMU 초기화
    if [[ "${FRESH_FEMU:-0}" == "1" ]]; then
      echo "[femu] 방금 새로 띄운 FEMU라 초기화는 건너뛰어요."
    elif [[ -n "$FEMU_RESET_CMD" ]]; then
      echo "[femu] 초기화: $FEMU_RESET_CMD"; bash -c "$FEMU_RESET_CMD"
    else
      echo "[femu] FEMU를 새로 띄워 장치를 깨끗하게 만든 뒤 Enter 를 누르세요 ($POL, 사용률 $U)"; read -r _
    fi
    rm -rf "$TORFS_DB_DIR"; mkdir -p "$TORFS_DB_DIR"

    # 2) 정책
    if [[ "$POL" == "single" ]]; then export TORFS_FORCE_PID=0; else unset TORFS_FORCE_PID; fi

    N=$(python3 "$HERE/pilot.py" get "$U" N)
    W=$(python3 "$HERE/pilot.py" get "$U" overwrite_writes_per_thread)
    dbbench_common_args "$U"
    { echo "policy=$POL util=$U N=$N W_per_thread=$W threads=$THREADS"
      echo "TORFS_FORCE_PID=${TORFS_FORCE_PID:-unset} fs_uri=$FS_URI"
      echo "config:"; grep -v '^\s*#' "$HERE/config.env" | grep -v '^\s*$'
      echo "db_args:"; printf '  %s\n' "${DB_ARGS[@]}"; } > "$RUN/meta.txt"

    echo "ts,phase,host_bytes,media_bytes" > "$RUN/counters.csv"
    [[ "$RUH_METHOD" != "none" ]] && echo "ts,phase,pid,value" > "$RUN/ruh.csv"

    # 3) 샘플러
    echo idle > "$RUN/phase"; sample "$RUN"
    ( while [[ -f "$RUN/phase" ]]; do sleep "$SAMPLE_SEC"; [[ -f "$RUN/phase" ]] && sample "$RUN"; done ) &
    SAMPLER=$!

    # 4) load: 키 N개를 겹치지 않게 랜덤 순서로 한 번씩
    echo load > "$RUN/phase"; sample "$RUN"
    "$DB_BENCH" --db="$TORFS_DB_DIR" --fs_uri="$FS_URI" "${DB_ARGS[@]}" \
      --benchmarks=filluniquerandom,waitforcompaction --threads=1 --num="$N" \
      > "$RUN/db_bench_load.log" 2>&1
    sample "$RUN"

    # 5) overwrite: 같은 키들을 랜덤으로 덮어쓰기 (이 구간의 WAF 를 봄)
    echo overwrite > "$RUN/phase"; sample "$RUN"
    "$DB_BENCH" --db="$TORFS_DB_DIR" --fs_uri="$FS_URI" "${DB_ARGS[@]}" --use_existing_db=1 \
      --benchmarks=overwrite,waitforcompaction,levelstats --threads="$THREADS" \
      --num="$N" --writes="$W" \
      > "$RUN/db_bench_overwrite.log" 2>&1
    sample "$RUN"

    echo end > "$RUN/phase"; sample "$RUN"
    rm -f "$RUN/phase"; kill "$SAMPLER" 2>/dev/null || true; wait "$SAMPLER" 2>/dev/null || true
    unset TORFS_FORCE_PID
    date +%s > "$RUN/done"
    echo "[femu] 완료: $RUN"
  done
done

if [[ "${NO_SUMMARY:-0}" != "1" ]]; then
  python3 "$HERE/pilot.py" summary "$RESULTS" | tee "$RESULTS/summary.txt"
fi
