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
OVERWRITE_MULT_FROM_ENV="${OVERWRITE_MULT:-}"     # config.env 를 읽기 전에 밖에서 받은 값을 기록
set -a; . "$HERE/config.env"; set +a
. "$HERE/lib/dbbench_args.sh"
. "$HERE/lib/runlib.sh"

DB_BENCH="$WORK/bin/db_bench_torfs"
TORFS_DB_DIR="${TORFS_DB_DIR:-$WORK/torfs_db}"   # TorFS가 쓰는 로컬 보조 폴더 (Lan도 이렇게 씀)
                                                 #   RocksDB LOG 도 여기 로컬 파일로 생겨요 (lib/runlib.sh 참고)
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
if [[ "$RUH_METHOD" == "femu" ]] && ! python3 "$HERE/pilot.py" usage >/dev/null; then
  echo "FEMU 사용량 로그(C1h)를 못 읽었어요. 이 브랜치(fdp-pilot)의 FEMU로 띄웠는지, NVME_DEV 를 확인하세요."; exit 1
fi
# PID 0 ~ NUM_PIDS-1 이 쓰는 RUH의 격리 방식이 EXPECT_RUHT 인지 (원본 FEMU의 isolation_mode=1 은
# 마지막 RUH만 II 라서, 그대로 띄우면 데이터 RUH는 PI 가 돼요)
if [[ "${EXPECT_RUHT:-any}" != "any" ]]; then
  RUHT=$(python3 "$HERE/pilot.py" ruhtypes) || { echo "FDP 설정 로그를 못 읽었어요 ('nvme fdp configs')."; exit 1; }
  BAD=$(awk -v want="$EXPECT_RUHT" -v n="$NUM_PIDS" '$1 < n && $2 != want' <<< "$RUHT")
  if [[ -n "$BAD" ]]; then
    echo "PID 0–$((NUM_PIDS-1)) 가 쓰는 RUH가 $EXPECT_RUHT 가 아니에요. FEMU를 fdp.isolation_mode 맞게 띄웠는지 확인하세요:"
    echo "$RUHT"; exit 1
  fi
fi

sample() {   # $1 = run 폴더, $2 = phase 이름 (없으면 phase 파일)
  local d="$1" ph="${2:-}" ts
  [[ -n "$ph" ]] || ph=$(cat "$d/phase" 2>/dev/null || echo end)
  ts=$(now_ms)
  read -r H M < <(python3 "$HERE/pilot.py" counters)
  echo "$ts,$ph,$H,$M" >> "$d/counters.csv"
  case "$RUH_METHOD" in
    femu)   # 실제 사용률과 RUH별 쓰기량을 한 번에 (첫 줄 = 유효 데이터·용량, 다음 줄부터 RUH별)
      python3 "$HERE/pilot.py" usage 2>/dev/null | {
        read -r V C && echo "$ts,$ph,$V,$C" >> "$d/usage.csv"
        while read -r pid hb mb live; do echo "$ts,$ph,$pid,$hb,$mb,$live" >> "$d/ruh_usage.csv"; done
      } || true ;;
    none) ;;
    *)
      python3 "$HERE/pilot.py" ruh 2>/dev/null | while read -r pid val; do
        echo "$ts,$ph,$pid,$val" >> "$d/ruh.csv"
      done ;;
  esac
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
    # 장치의 LBA 크기 (RUAMW 단위). summary 는 장치가 없는 호스트에서 돌아서 여기 남겨 둬요
    python3 "$HERE/pilot.py" lbasize > "$RUN/lba_bytes"
    python3 "$HERE/pilot.py" ruhtypes > "$RUN/ruh_types" 2>/dev/null || echo "읽기 실패" > "$RUN/ruh_types"
    dbbench_common_args "$U"
    write_run_params "$RUN" \
      "script=02_femu_run.sh" "policy=$POL" "util=$U" "REP=$REP" "SCALE=1 (FEMU는 크기 줄이기 없음)" \
      "TORFS_FORCE_PID=${TORFS_FORCE_PID:-unset}  (single=0, lan=unset -> Lan 패치의 레벨별 hint)" \
      "N(--num)=$N" "W(--writes, 스레드당)=$W" \
      "overwrite 전체 연산 수 = W x THREADS = $((W * THREADS))" \
      "논리 데이터 대비 배수 = W x THREADS / N = $(python3 -c "print(f'{$W*$THREADS/$N:.4f}')")" \
      "logical_bytes = N x (KEY_SIZE + VALUE_SIZE) = $(( N * (KEY_SIZE + VALUE_SIZE) ))" \
      "TORFS_DB_DIR=$TORFS_DB_DIR" "FS_URI=$FS_URI" "RESULTS=$RESULTS" "db_bench=$DB_BENCH"
    { echo "policy=$POL util=$U N=$N W_per_thread=$W threads=$THREADS lba_bytes=$(cat "$RUN/lba_bytes")"
      echo "TORFS_FORCE_PID=${TORFS_FORCE_PID:-unset} fs_uri=$FS_URI"
      echo "config:"; grep -v '^\s*#' "$HERE/config.env" | grep -v '^\s*$'
      echo "db_args:"; printf '  %s\n' "${DB_ARGS[@]}"; } > "$RUN/meta.txt"

    echo "ts,phase,host_bytes,media_bytes" > "$RUN/counters.csv"
    case "$RUH_METHOD" in
      femu) echo "ts,phase,valid_bytes,capacity_bytes" > "$RUN/usage.csv"
            echo "ts,phase,ruh,hbmw,mbmw,live_bytes" > "$RUN/ruh_usage.csv" ;;
      none) ;;
      *)    echo "ts,phase,pid,value" > "$RUN/ruh.csv" ;;
    esac

    # 3) 샘플러: SAMPLE_SEC 마다 + 단계가 바뀔 때 (바뀌기 전·후 이름으로 한 번씩, lib/runlib.sh start_sampler)
    #    단계: idle -> load_open -> load -> load_wait -> load_logsave
    #          -> overwrite_open -> overwrite -> overwrite_wait -> overwrite_logsave -> end
    #    주 WAF·뒤 1/3·RUH 비율은 overwrite(실제 실행) 구간만, 대기·LOG 저장 중 쓰기는 summary 에 따로 나와요.
    set_phase "$RUN" idle
    start_sampler "$RUN" "$SAMPLE_SEC" sample

    # 4) load: 키 N개를 겹치지 않게 랜덤 순서로 한 번씩
    #    stdout·stderr 는 db_bench_load.stdout / .stderr 로 따로, LOG 옵션 대조는 options_check_load.txt
    rc=0
    run_dbbench load "$RUN" "$TORFS_DB_DIR" \
      "$DB_BENCH" --db="$TORFS_DB_DIR" --fs_uri="$FS_URI" "${DB_ARGS[@]}" \
      --benchmarks=filluniquerandom,waitforcompaction --threads=1 --num="$N" || rc=$?
    if [[ $rc -ne 0 ]]; then
      rm -f "$RUN/phase"; wait "$SAMPLER" 2>/dev/null || true; echo "[femu] load 실패 (rc=$rc): $RUN"; exit $rc
    fi

    # 5) overwrite: 같은 키들을 랜덤으로 덮어쓰기 (이 구간의 WAF 를 봄). load 와 따로 한 프로세스, 중간에 다시 열지 않음
    run_dbbench overwrite "$RUN" "$TORFS_DB_DIR" \
      "$DB_BENCH" --db="$TORFS_DB_DIR" --fs_uri="$FS_URI" "${DB_ARGS[@]}" --use_existing_db=1 \
      --benchmarks=overwrite,waitforcompaction,levelstats,stats --threads="$THREADS" \
      --num="$N" --writes="$W" || rc=$?
    if [[ $rc -ne 0 ]]; then
      rm -f "$RUN/phase"; wait "$SAMPLER" 2>/dev/null || true; echo "[femu] overwrite 실패 (rc=$rc): $RUN"; exit $rc
    fi
    grep -A 12 "Level Files Size" "$RUN/db_bench_overwrite.stdout" > "$RUN/levelstats.txt" || true

    set_phase "$RUN" end; sleep 2
    rm -f "$RUN/phase"; wait "$SAMPLER" 2>/dev/null || true
    python3 "$HERE/pilot.py" phasetimes "$RUN" > "$RUN/time.txt" || true
    unset TORFS_FORCE_PID
    date +%s > "$RUN/done"
    echo "[femu] 완료: $RUN"
  done
done

if [[ "${NO_SUMMARY:-0}" != "1" ]]; then
  python3 "$HERE/pilot.py" summary "$RESULTS" | tee "$RESULTS/summary.txt"
fi
