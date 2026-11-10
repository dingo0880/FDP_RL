#!/usr/bin/env bash
# =====================================================================
# 03_host_loop.sh — 지윤 담당. FEMU를 띄우는 "호스트"에서 실행.
#   run 하나마다:  FEMU 새로 띄우기 -> 게스트에 ssh로 02_femu_run.sh 한 run 실행
#                  -> 결과를 호스트로 복사 -> FEMU 끄기
#   FEMU의 FTL 상태는 메모리에만 있어서, 새로 띄우면 장치가 깨끗해져요.
#
#   ./03_host_loop.sh                        전부 (single·lan x 모든 사용률)
#   ./03_host_loop.sh lan 0.93               하나만
#   REP=2 ./03_host_loop.sh "single lan" 0.93   경계 판정일 때 93% 한 번 더
#
# 준비 (README 참고)
#   - 호스트의 config.env 에 FEMU_START_CMD, GUEST_SSH, GUEST_SSH_OPTS, GUEST_DIR 채우기
#   - 비밀번호 없이 ssh 접속 (ssh-copy-id), 게스트에서 비밀번호 없이 sudo
#   - FEMU 게스트 디스크가 재시작 뒤에도 남아 있어야 함 (-snapshot 모드 X)
#   - 게스트 쪽 config.env 는 장치 이름·카운터 방법 등이 채워져 있어야 함
# =====================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "$HERE/config.env"; set +a

POLICIES="${1:-single lan}"
UTILS="${2:-$TARGET_UTILS}"
REP="${REP:-1}"
SUFFIX=""; [[ "$REP" != "1" ]] && SUFFIX="_r$REP"

for v in FEMU_START_CMD GUEST_SSH GUEST_DIR; do
  [[ -n "${!v}" ]] || { echo "config.env 의 $v 를 채워 주세요."; exit 1; }
done
LOGDIR="$HOST_RESULTS/host_logs"; mkdir -p "$LOGDIR"

# shellcheck disable=SC2086
gssh() { ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=30 \
             -o StrictHostKeyChecking=accept-new $GUEST_SSH_OPTS "$GUEST_SSH" "$@"; }

# 게스트 안에서 결과 폴더 경로 (게스트 config.env 기준)
GUEST_ENV="cd '$GUEST_DIR' && set -a && . ./config.env && set +a"

if [[ "${FORCE:-0}" != "1" ]]; then
  echo "run마다 FEMU를 새로 띄우고, 게스트 장치의 데이터를 지워요. 계속하려면 yes 를 입력하세요."
  read -r ans; [[ "$ans" == "yes" ]] || exit 1
fi

FPID=""
# FEMU를 sudo로 띄우면 qemu는 root 프로세스라, 일반 사용자의 kill은 그룹 안의
# 내 프로세스에만 닿고 qemu에는 안 닿아요(그래도 kill은 성공으로 끝나요).
# 그래서 두 가지를 다 보내요. 호스트에서 sudo -n 이 되어야 root 쪽에 닿아요.
signal_femu() {   # $1 = 신호 이름 (TERM, KILL)
  kill "-$1" -- "-$FPID" 2>/dev/null || kill "-$1" "$FPID" 2>/dev/null || true
  sudo -n kill "-$1" -- "-$FPID" 2>/dev/null || true
}
stop_femu() {
  [[ -n "$FPID" ]] || return 0
  gssh "sudo -n poweroff" >/dev/null 2>&1 || true
  local t=0
  while kill -0 "$FPID" 2>/dev/null && (( t < SHUTDOWN_TIMEOUT_SEC )); do sleep 5; t=$((t+5)); done
  if kill -0 "$FPID" 2>/dev/null; then
    echo "[host] FEMU가 안 꺼져서 강제 종료해요."
    signal_femu TERM; sleep 10; signal_femu KILL
    t=0
    while kill -0 "$FPID" 2>/dev/null && (( t < 30 )); do sleep 2; t=$((t+2)); done
    if kill -0 "$FPID" 2>/dev/null; then
      # wait 로 기다리면 여기서 영원히 멈춰요. 알리고 넘어가요.
      echo "[host] FEMU(pid $FPID)를 못 껐어요. 손으로 꺼 주세요: sudo kill -KILL -- -$FPID"
      FPID=""; return 1
    fi
  fi
  wait "$FPID" 2>/dev/null || true
  FPID=""
}
trap 'echo "[host] 중단됨. FEMU를 꺼요."; stop_femu; exit 130' INT TERM

for POL in $POLICIES; do
  for U in $UTILS; do
    TAG="${POL}_u${U}${SUFFIX}"
    if [[ -f "$HOST_RESULTS/$TAG/done" ]]; then
      echo "[건너뜀] $TAG 는 이미 끝났어요 ($HOST_RESULTS/$TAG)"; continue
    fi
    echo "[host] ===== $TAG ====="

    # 1) FEMU 띄우기 (자기만의 프로세스 그룹으로 -> 나중에 통째로 끌 수 있게)
    setsid bash -c "$FEMU_START_CMD" > "$LOGDIR/femu_$TAG.log" 2>&1 < /dev/null &
    FPID=$!
    echo "[host] FEMU 시작 (pid $FPID), 부팅 기다리는 중..."
    t=0
    until gssh true 2>/dev/null; do
      kill -0 "$FPID" 2>/dev/null || { echo "[host] FEMU가 바로 꺼졌어요. $LOGDIR/femu_$TAG.log 확인"; exit 1; }
      (( t >= BOOT_TIMEOUT_SEC )) && { echo "[host] 부팅 시간 초과"; stop_femu; exit 1; }
      sleep 10; t=$((t+10))
    done
    echo "[host] 게스트 접속됨 (${t}초)"

    # 2) (선택) 게스트 준비 명령
    if [[ -n "$GUEST_PREP_CMD" ]]; then
      gssh "$GUEST_PREP_CMD" > "$LOGDIR/prep_$TAG.log" 2>&1 || { echo "[host] GUEST_PREP_CMD 실패"; stop_femu; exit 1; }
    fi

    # 3) run 하나를 게스트에서 백그라운드로 실행 (ssh가 끊겨도 계속 돌게 nohup)
    #    OVERWRITE_MULT 는 호스트에서 정한 값을 그대로 넘겨요. 안 넘기면 게스트가 자기 config.env 를 다시 읽어
    #    기본값(3)이 되어서, 호스트에서 OVERWRITE_MULT=1 ./03_host_loop.sh 로 준 값이 무시돼요.
    #    이전에 덜 끝난 같은 폴더가 있으면 지우고 새로 시작
    #    { … & } 로 nohup 만 백그라운드로 보내야 ssh가 바로 돌아와요. 감싸지 않으면
    #    "A && B && nohup … &" 전체가 백그라운드 서브셸이 되고, 그 서브셸이 ssh 출력을
    #    run이 끝날 때까지 쥐고 있어서 ssh가 안 돌아와요.
    gssh "$GUEST_ENV && rm -rf \"\$RESULTS/$TAG\" && \
          { nohup sudo -n -E env WORK=\"\$WORK\" RESULTS=\"\$RESULTS\" FORCE=1 FRESH_FEMU=1 NO_SUMMARY=1 REP=$REP \
              OVERWRITE_MULT=$OVERWRITE_MULT \
              ./02_femu_run.sh '$POL' '$U' > \"\$HOME/fdp_run_$TAG.log\" 2>&1 < /dev/null & \
            echo \$! > \"\$HOME/fdp_run_$TAG.pid\"; } && echo started"

    # 4) 끝날 때까지 기다리기 (PID 파일의 프로세스가 살아 있는 동안)
    #    ps -p 를 써요: sudo로 뜬 root 프로세스는 kill -0 이 권한 오류로 실패해서 "끝남"으로 잘못 보일 수 있어요.
    #    ssh 종료 코드 255 = 접속 문제라서 "끝남"으로 보지 않고 다시 확인해요.
    fails=0
    while :; do
      sleep "$POLL_SEC"
      kill -0 "$FPID" 2>/dev/null || { echo "[host] run 도중 FEMU가 꺼졌어요. $LOGDIR/femu_$TAG.log 확인"; FPID=""; exit 1; }
      rc=0; gssh "ps -p \"\$(cat \"\$HOME/fdp_run_$TAG.pid\")\" >/dev/null" || rc=$?
      if (( rc == 0 )); then fails=0; continue; fi
      if (( rc == 255 )); then
        fails=$((fails+1)); echo "[host] 게스트 접속 실패 ($fails번째), 다시 확인할게요."
        (( fails >= 10 )) && { echo "[host] 게스트에 계속 접속이 안 돼요. 멈춰요."; stop_femu; exit 1; }
        continue
      fi
      break   # ps 가 1을 돌려줌 = 프로세스 없음 = run 끝남
    done

    # 5) 결과 가져오기
    gssh "cat \"\$HOME/fdp_run_$TAG.log\"" > "$LOGDIR/run_$TAG.log" 2>/dev/null || true
    mkdir -p "$HOST_RESULTS"
    gssh "$GUEST_ENV && cd \"\$RESULTS\" && tar cf - '$TAG'" | tar xf - -C "$HOST_RESULTS"
    ok=0; [[ -f "$HOST_RESULTS/$TAG/done" ]] && ok=1

    # 6) FEMU 끄기
    stop_femu
    if (( ok )); then
      echo "[host] 완료: $TAG"
    else
      echo "[host] $TAG 가 끝까지 못 갔어요. $LOGDIR/run_$TAG.log 를 확인해 주세요. 여기서 멈춰요."
      exit 1
    fi
    sleep 5
  done
done

python3 "$HERE/pilot.py" summary "$HOST_RESULTS" | tee "$HOST_RESULTS/summary.txt"
