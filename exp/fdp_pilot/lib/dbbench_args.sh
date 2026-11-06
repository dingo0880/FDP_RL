# db_bench 공통 옵션 (PC와 FEMU가 똑같이 씀). source 해서 씁니다.
# 사용: dbbench_common_args <util>  -> 배열 DB_ARGS 를 채움
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
    --write_buffer_size="$wbuf"
    --max_write_buffer_number="$MAX_WB_NUMBER"
    --min_write_buffer_number_to_merge="$MIN_WB_MERGE"
    --level0_file_num_compaction_trigger="$L0_TRIGGER"
    --level_compaction_dynamic_level_bytes=false
    --compression_type="$COMPRESSION"
    --max_background_jobs="$BG_JOBS"
    --seed="$SEED"
    --statistics
    --stats_interval_seconds=60
    --histogram=false
  )
}
