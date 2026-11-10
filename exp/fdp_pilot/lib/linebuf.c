/* liblinebuf.so: db_bench 의 stdout 을 줄 단위 버퍼로 바꿔요 (LD_PRELOAD 로 올림).
 *   db_bench 7.2.2 는 결과 줄(Report) 뒤에는 fflush(stdout) 를 하지만,
 *   "waitforcompaction(...): started / active / finished" 줄은 fflush 없이 stdout 으로 내보내요.
 *   파일·파이프로 받으면 이 줄이 버퍼에 쌓였다가 늦게 나와서, 시각으로 잡는 대기 끝 경계가 틀어져요.
 * stdbuf 를 쓰지 않는 이유: 이 PC 의 stdbuf(uutils coreutils 0.8.0)는 LD_PRELOAD 를 자기 라이브러리로
 *   덮어써서, 같이 올린 libnofsync.so 가 빠져요 (fsync 200번: nofsync 0 ms, stdbuf+nofsync 1291 ms 로 확인).
 * 빌드: gcc -O2 -shared -fPIC -o liblinebuf.so linebuf.c   (lib/runlib.sh 가 없으면 만들어요) */
#include <stdio.h>
__attribute__((constructor)) static void linebuf_init(void) { setvbuf(stdout, NULL, _IOLBF, 0); }
