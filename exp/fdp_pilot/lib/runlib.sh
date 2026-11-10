# 01_pc_calibrate.sh(PC)·02_femu_run.sh(FEMU) 공통: db_bench 한 프로세스 실행 + 단계 경계 기록 + 실효 옵션 확인.
#   source 해서 씁니다. HERE(스크립트 폴더)와 config.env 값이 있어야 해요.
#
# 단계(phase) 이름. 프로세스 하나(load 또는 overwrite)를 다시 열지 않고, 출력에 찍은 시각으로 나눠요:
#   <단계>_open     프로세스 시작 ~ DB 열림 (LOG 의 "DB pointer" 줄 시각)
#   <단계>          실제 실행 (filluniquerandom / overwrite). 끝 = 결과 줄("... micros/op ...")이 나온 시각
#   <단계>_wait     waitforcompaction (+ levelstats·stats 출력, DB 닫기) ~ 프로세스 끝
#   <단계>_logsave  LOG 앞부분·OPTIONS·LOG 전체 gzip 저장
#   주 WAF 와 뒤 1/3 은 <단계>=overwrite 구간만으로 계산해요.
# 기록:
#   phase_events.txt          "epoch(초.밀리초) 이벤트" 줄들 (경계 시각)
#   phase                     지금 단계 (샘플러가 1초마다 보고, 바뀌면 바뀌기 전·후 이름으로 한 번씩 샘플)
#   db_bench_<단계>.stdout/.stderr       원래 출력 그대로
#   db_bench_<단계>.stdout.ts/.stderr.ts 줄마다 받은 시각을 앞에 붙인 사본
#   cmd_<단계>.txt, options_check_<단계>.txt, rocksdb_LOG_<단계>_head.txt, rocksdb_OPTIONS_<단계>.ini,
#   rocksdb_LOG_<단계>.gz (SAVE_FULL_LOG=1)
# 버퍼링: 결과 줄은 db_bench 가 fflush 해요. waitforcompaction 줄은 안 해서 liblinebuf.so 로 stdout 을
#   줄 버퍼로 만들어요 (lib/linebuf.c). stderr 는 원래 버퍼 없음.

now_ms() { date +%s.%N | cut -c1-14; }
event()  { printf '%s %s\n' "${3:-$(now_ms)}" "$2" >> "$1/phase_events.txt"; }
set_phase() { echo "$2" > "$1/phase.tmp" && mv -f "$1/phase.tmp" "$1/phase"; }

ensure_linebuf() {
  LINEBUF_LIB="$WORK/bin/liblinebuf.so"
  if [[ ! -f "$LINEBUF_LIB" || "$HERE/lib/linebuf.c" -nt "$LINEBUF_LIB" ]]; then
    mkdir -p "$WORK/bin"
    gcc -O2 -shared -fPIC -o "$LINEBUF_LIB" "$HERE/lib/linebuf.c" || { echo "liblinebuf.so 빌드 실패" >&2; return 1; }
  fi
}

# run_dbbench <단계: load|overwrite> <결과 폴더> <DB 로컬 폴더> <명령...>
#   PC: DB 로컬 폴더 = PC_DB_DIR. FEMU: TORFS_DB_DIR (TorFS 0a6e399 의 TorFS::NewLogger 가 LOG 를
#   target_ = FileSystem::Default() 로 넘겨서 RocksDB LOG 가 여기 로컬 파일로 생겨요).
#   시작 전에 이전 단계 LOG 를 지워요 (이미 저장함). RocksDB 는 다시 열 때 LOG 를 LOG.old.* 로 바꾸는데,
#   없으면 그냥 넘어가요 (오류 무시. TorFS::RenameFile 도 자기 파일이 아니면 로컬 rename 만 하고 OK).
run_dbbench() {
  local ph="$1" out="$2" dbdir="$3"; shift 3
  local log="$dbdir/LOG" pid rc=0 i pido pide t_open preload
  ensure_linebuf || return 1
  preload="$LINEBUF_LIB${LD_PRELOAD:+:$LD_PRELOAD}"
  { printf '%q ' "$@"; echo; echo "LD_PRELOAD=$preload  (db_bench 프로세스에만)"; } > "$out/cmd_$ph.txt"
  rm -f "$log" "$out/.fo_$ph" "$out/.fe_$ph"
  mkfifo "$out/.fo_$ph" "$out/.fe_$ph"
  python3 "$HERE/pilot.py" tsw --raw "$out/db_bench_$ph.stdout" --ts "$out/db_bench_$ph.stdout.ts" \
      --events "$out/phase_events.txt" --phase-file "$out/phase" \
      --once '^[A-Za-z0-9_]+ +: +[0-9.]+ micros/op' "${ph}_exec_end" "${ph}_wait" \
      --every '^waitforcompaction\(.*\): (started|finished)' "${ph}_waitforcompaction_\1" \
      < "$out/.fo_$ph" &
  pido=$!
  python3 "$HERE/pilot.py" tsw --raw "$out/db_bench_$ph.stderr" --ts "$out/db_bench_$ph.stderr.ts" \
      < "$out/.fe_$ph" &
  pide=$!
  set_phase "$out" "${ph}_open"; event "$out" "${ph}_proc_start"
  LD_PRELOAD="$preload" "$@" > "$out/.fo_$ph" 2> "$out/.fe_$ph" &
  pid=$!
  for ((i = 0; i < ${OPTCHECK_WAIT_SEC:-1800}; i++)); do
    grep -q "DB pointer" "$log" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  # DB 가 열린 시각 = LOG 의 "DB pointer" 줄 시각 (마이크로초). 이때부터 실제 실행 구간
  if t_open=$(python3 "$HERE/pilot.py" logopen "$log" 2>/dev/null); then
    event "$out" "${ph}_exec_start" "$t_open"
  else
    event "$out" "${ph}_exec_start_unknown"
  fi
  set_phase "$out" "$ph"
  # 실제로 올라온 공유 라이브러리 확인 (stdbuf 처럼 LD_PRELOAD 를 덮어쓰는 문제가 없는지)
  { echo "로드된 preload 라이브러리 (/proc/$pid/maps):"
    grep -o '[^ /]*\(linebuf\|nofsync\|stdbuf\)[^ ]*\.so' "/proc/$pid/maps" 2>/dev/null | sort -u | sed 's/^/  /'
  } >> "$out/cmd_$ph.txt"
  if ! check_options "$ph" "$log" "$out"; then
    if [[ "${OPTCHECK_STRICT:-1}" == "1" ]]; then
      echo "[옵션] $ph: 실효 옵션이 기대와 달라요 -> db_bench 를 멈춰요 ($out/options_check_$ph.txt)" >&2
      kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; wait "$pido" "$pide" 2>/dev/null
      event "$out" "${ph}_killed_optcheck"
      save_rocksdb_log "$ph" "$dbdir" "$out"
      rm -f "$out/.fo_$ph" "$out/.fe_$ph"
      return 90
    fi
    echo "[옵션] $ph: 실효 옵션 불일치·누락이 있어요 (OPTCHECK_STRICT=0 이라 계속)" >&2
  fi
  wait "$pid" || rc=$?
  event "$out" "${ph}_proc_exit rc=$rc"
  wait "$pido" "$pide" 2>/dev/null || true
  rm -f "$out/.fo_$ph" "$out/.fe_$ph"
  set_phase "$out" "${ph}_logsave"; event "$out" "${ph}_logsave_start"
  save_rocksdb_log "$ph" "$dbdir" "$out"
  event "$out" "${ph}_logsave_end"
  return $rc
}

# check_options <단계> <LOG> <결과 폴더> -> rocksdb_LOG_<단계>_head.txt, options_check_<단계>.txt
check_options() {
  local ph="$1" log="$2" out="$3" rc=0
  if [[ ! -s "$log" ]]; then
    echo "결과: 누락 - LOG 파일이 없어요 ($log). 옵션을 확인하지 못했어요." | tee "$out/options_check_$ph.txt" >&2
    return 1
  fi
  awk '{print} /DB pointer/{exit}' "$log" > "$out/rocksdb_LOG_${ph}_head.txt"
  python3 "$HERE/pilot.py" optcheck "$out/rocksdb_LOG_${ph}_head.txt" > "$out/options_check_$ph.txt" 2>&1 || rc=$?
  tail -1 "$out/options_check_$ph.txt" | sed "s/^/[옵션] $ph: /" >&2
  return $rc
}

# save_rocksdb_log <단계> <DB 로컬 폴더> <결과 폴더>
#   gzip 은 원본 LOG 를 지우지 않아요 (원본은 DB 폴더에 남고, 다음 단계 시작 때 지워짐).
#   gzip 하는 동안 원본(DB 폴더)과 압축본(결과 폴더)이 같이 있어요.
save_rocksdb_log() {
  local ph="$1" dbdir="$2" out="$3" f
  f=$(ls -t "$dbdir"/OPTIONS-* 2>/dev/null | head -1)
  [[ -n "$f" ]] && cp "$f" "$out/rocksdb_OPTIONS_$ph.ini"
  if [[ -f "$dbdir/LOG" ]]; then
    echo "$ph LOG 원본 $(stat -c %s "$dbdir/LOG") B" >> "$out/log_sizes.txt"
    if [[ "${SAVE_FULL_LOG:-1}" == "1" ]]; then
      gzip -c "$dbdir/LOG" > "$out/rocksdb_LOG_$ph.gz"
      echo "$ph LOG gzip $(stat -c %s "$out/rocksdb_LOG_$ph.gz") B" >> "$out/log_sizes.txt"
    fi
  fi
  return 0
}

# start_sampler <결과 폴더> <간격 초> <샘플 함수>
#   1초마다 phase 를 보고, 바뀌면 바뀌기 전 이름으로 한 번(그 구간의 끝), 바뀐 이름으로 한 번(다음 구간의 시작)
#   샘플을 찍어요. 안 바뀌면 <간격> 마다 찍어요. phase 파일이 없어지면 끝나요. 샘플 함수는 "<결과> <phase>" 를 받아요.
start_sampler() {
  local out="$1" every="$2" fn="$3"
  (
    local last="" cur t_last=0 t
    while [[ -f "$out/phase" ]]; do
      cur=$(cat "$out/phase" 2>/dev/null) || cur="$last"
      t=$(date +%s)
      if [[ "$cur" != "$last" ]]; then
        [[ -n "$last" ]] && "$fn" "$out" "$last"
        "$fn" "$out" "$cur"; last="$cur"; t_last=$t
      elif (( t - t_last >= every )); then
        "$fn" "$out" "$cur"; t_last=$t
      fi
      sleep 1
    done
    [[ -n "$last" ]] && "$fn" "$out" "$last"
  ) &
  SAMPLER=$!
}

# write_run_params <결과 폴더> <키=값 줄들...> : 스크립트가 최종으로 정한 값 기록 (LOG 확인과 별도)
write_run_params() {
  local out="$1"; shift
  {
    echo "# 스크립트가 최종으로 정한 값 ($(date '+%F %T'))"
    printf '%s\n' "$@"
    echo "OVERWRITE_MULT=$OVERWRITE_MULT  (밖에서 받은 값: ${OVERWRITE_MULT_FROM_ENV:-없음 -> config.env 기본값})"
    echo "SEED=$SEED"
    echo "THREADS=$THREADS  (load 는 1)"
    echo "TRACK_STATS=$TRACK_STATS STATS_INTERVAL_SEC=${STATS_INTERVAL_SEC:-60} SAVE_FULL_LOG=$SAVE_FULL_LOG OPTCHECK_STRICT=$OPTCHECK_STRICT"
    if [[ -n "${LD_PRELOAD:-}" ]]; then
      echo "LD_PRELOAD(밖에서)=$LD_PRELOAD  (+ db_bench 에는 liblinebuf.so 를 앞에 붙임)"
      [[ "$LD_PRELOAD" == *nofsync* ]] && echo "NOFSYNC=1 (fsync·fdatasync·sync_file_range 를 건너뜀: PC 예비 보정용. FEMU 공간 상한·성능값 아님)" || echo "NOFSYNC=0"
    else
      echo "LD_PRELOAD(밖에서)=(없음)  (db_bench 에는 liblinebuf.so 만)"; echo "NOFSYNC=0"
    fi
  } > "$out/run_params.txt"
}
