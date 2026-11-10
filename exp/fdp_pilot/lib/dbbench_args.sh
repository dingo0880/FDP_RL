# db_bench 공통 옵션 (PC와 FEMU가 똑같이 씀). source 해서 씁니다.
# 사용: dbbench_common_args <util>  -> 배열 DB_ARGS 를 채움
# 값은 전부 config.env 에서 와요. 두 사용률·두 정책에 같은 값이 들어가요 (사용률은 N 에만 영향).
# 옵션 파일(--options_file)은 쓰지 않고 CLI로만 넘겨요. 실제 적용값은 pilot.py optcheck 가 LOG로 확인해요.
dbbench_common_args() {
  local u="$1"
  local base tfile wbuf
  base=$(python3 "$HERE/pilot.py" get "$u" level_base_bytes)
  tfile=$(python3 "$HERE/pilot.py" get "$u" target_file_bytes)
  wbuf=$(python3 "$HERE/pilot.py" get "$u" write_buffer_bytes)
  DB_ARGS=(
    --key_size="$KEY_SIZE"
    --value_size="$VALUE_SIZE"
    --num_levels="$NUM_LEVELS"
    --max_bytes_for_level_base="$base"
    --max_bytes_for_level_multiplier="$LEVEL_MULT"
    --target_file_size_base="$tfile"
    --target_file_size_multiplier="$TARGET_FILE_MULT"
    --write_buffer_size="$wbuf"
    --max_write_buffer_number="$MAX_WB_NUMBER"
    --min_write_buffer_number_to_merge="$MIN_WB_MERGE"
    --level0_file_num_compaction_trigger="$L0_TRIGGER"
    --level0_slowdown_writes_trigger="$L0_SLOWDOWN"
    --level0_stop_writes_trigger="$L0_STOP"
    # compaction 밀림 한도: Lan usertable 64 / 256 GiB 의 1/128
    --soft_pending_compaction_bytes_limit="$SOFT_PENDING_BYTES"
    --hard_pending_compaction_bytes_limit="$HARD_PENDING_BYTES"
    # 밀렸을 때 쓰기 속도: Lan과 같은 16 MiB/s (db_bench 기본은 8 MiB/s)
    --delayed_write_rate="$DELAYED_WRITE_RATE"
    --level_compaction_dynamic_level_bytes=false
    --compression_type="$COMPRESSION"
    --max_background_jobs="$BG_JOBS"
    --seed="$SEED"
    --statistics
    --stats_interval_seconds="${STATS_INTERVAL_SEC:-60}"
    --histogram=false
    # LOG 크기 묶기 (100 MB x 3개)는 이번에 미적용:
    #   RocksDB 7.2.2 자체에는 DBOptions max_log_file_size·keep_log_file_num 이 있어요 (LOG에 기본값 0·1000이 찍힘).
    #   하지만 db_bench 7.2.2 CLI 에는 이 플래그가 없어서 (tools/db_bench_tool.cc 에 DEFINE 없음)
    #   넣으면 "unknown command line flag"로 멈춰요. 쓰려면 db_bench 패치가 필요해요.
    # --max_log_file_size=104857600
    # --keep_log_file_num=3
  )
  # 추적용 통계: RocksDB 동작은 그대로, 출력만 늘어요
  #   --stats_per_interval=1    : stats_interval_seconds 마다 thread 0 이 rocksdb.stats 를 stderr 로 출력
  #   --stats_dump_period_sec   : LOG 에도 같은 간격으로 통계 출력 (DBOptions)
  if [[ "${TRACK_STATS:-0}" == "1" ]]; then
    DB_ARGS+=(--stats_per_interval=1 --stats_dump_period_sec="${STATS_INTERVAL_SEC:-60}")
  fi
}
