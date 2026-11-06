# FDP 파일럿: 꽉 찬 SSD에서 FDP 이득이 무너지는가

몇 달짜리 본 실험을 정하기 전에, **FEMU에서도 Lan et al.처럼 사용률이 높아지면 FDP 이득이 줄어드는지** 확인하는 짧은 실험이에요.
줄어든다면 "왜 줄어드는가"(방향 A)를 연구할 여지가 있다는 뜻이에요.

## 한눈에

| 항목 | 값 |
|---|---|
| 정책 | **single** (모든 데이터 PID 0) · **lan** (WAL 0 / L0–L3 1 / L4 2 / L5 3 / MANIFEST 4) |
| 사용률 | 70%, 93% (삭제 대기 파일까지 포함한 최대 사용량 기준) |
| workload | load(`filluniquerandom`, 키 N개) → overwrite(같은 키를 랜덤으로 덮어쓰기, 데이터의 3배) |
| 반복 | 1번씩. 판정이 경계(비율 0.4~0.6)면 93% 두 run만 한 번 더 (`REP=2`) |
| 보는 것 | overwrite 구간의 WAF = media 쓰기 ÷ host 쓰기, RUH별 쓰기 비율 |
| 판정 | 이득 = 1 − WAF_lan / WAF_single. 70%에서 이득이 10% 미만이면 **판정 보류**. 아니면 93% 이득 ÷ 70% 이득이 0.5 아래면 "여지 있음" |
| 공간 여유 | 측정한 공간 증폭 × 1.02로 계산 (93% 목표 → 실제 최고 약 91%) |
| FEMU 초기화 | run마다 **호스트에서 FEMU를 껐다 켬** (`03_host_loop.sh`) |

run은 정책 2 × 사용률 2 = 4개예요. 판정 기준 숫자는 `config.env`의 `MIN_GAIN_LOW`, `COLLAPSE_RATIO`, `BORDER_BAND`에서 바꿀 수 있어요.

### 왜 호스트에서 돌리나

FEMU는 가짜 SSD가 달린 가상 컴퓨터예요. 가짜 SSD의 상태(어디에 뭐가 쓰였는지, GC 상태)는 FEMU 프로그램 메모리에 있어서, FEMU를 껐다 켜야 새 SSD가 돼요.
그런데 게스트(FEMU 안 리눅스) 안의 스크립트는 FEMU가 꺼지면 같이 꺼져요. 그래서 바깥(호스트)에서 도는 `03_host_loop.sh`가 run마다
FEMU 켜기 → 게스트에 ssh로 run 하나 실행 → 결과를 호스트로 복사 → FEMU 끄기를 반복해요.

## 누가 무엇을 하나

| 순서 | 담당 | 할 일 | 파일 |
|---|---|---|---|
| 1 | 인구 | PC에서 db_bench 빌드 | `./00_build.sh pc` |
| 2 | 인구 | 작은 크기로 스크립트 점검 | `SCALE=0.05 ./01_pc_calibrate.sh 0.70` |
| 3 | 인구 | 실제 크기로 보정: 공간 증폭, 레벨 비중, MANIFEST 비중, 시간 | `./01_pc_calibrate.sh` |
| 4 | 인구 | `config.env`의 `SPACE_AMP`를 3번 결과로 바꾸고 `python3 pilot.py calc`로 N 확인 | `config.env` |
| 5 | 지윤 | FEMU 게스트에서 TorFS 포함 빌드 | `./00_build.sh femu` |
| 6 | 지윤 | 게스트의 `config.env` ★ 항목 채우기(장치 이름, 용량, RU 크기, 카운터 방법) | 게스트 `config.env` |
| 7 | 지윤 | 카운터 읽기 확인: `python3 pilot.py counters`가 숫자 두 개를 출력하는지. 1 GB 쓰고 host 값이 1 GB 늘었는지도 | — |
| 8 | 지윤 | 호스트에 같은 폴더를 두고 `config.env`의 FEMU 자동 재시작 칸 채우기, 아래 "호스트 준비" 확인 | 호스트 `config.env` |
| 9 | 지윤 | 본 파일럿 4 run (호스트에서) | `./03_host_loop.sh` |
| 10 | 같이 | 결과 해석. 경계면 안내대로 `REP=2`로 93% 한 번 더 | `$HOST_RESULTS/summary.txt` |

1–4와 5–8은 동시에 해도 돼요. 9는 4가 끝난 뒤에 해야 공간 부족 없이 돌아가요. 게스트와 호스트의 `SPACE_AMP`는 같은 값이어야 해요.

### 호스트 준비 (8번)

- `FEMU_START_CMD`: FEMU를 **앞에서(foreground)** 띄우는 명령이에요. 평소 FEMU 띄우는 스크립트를 그대로 쓰면 돼요. 뒤로 보내는(`&`, daemonize) 방식이면 스크립트가 꺼짐을 못 알아채요.
- 게스트 디스크는 재시작 뒤에도 남아 있어야 해요. 결과가 거기에 쌓이기 때문에 QEMU `-snapshot` 모드는 쓰면 안 돼요.
- 호스트 → 게스트 ssh가 비밀번호 없이 돼야 해요 (`ssh-copy-id`). 게스트에서는 `sudo`도 비밀번호 없이 돼야 해요 (sudoers에 `NOPASSWD`).
- FDP 설정이 부팅 때마다 필요하면(예: 네임스페이스 만들기) `GUEST_PREP_CMD`에 넣으세요.
- 한 run만 먼저 시험: `./03_host_loop.sh single 0.70`. 이미 끝난 run은 건너뛰고, 실패하면 FEMU를 끄고 거기서 멈춰요.
- 손으로 돌리고 싶으면 예전처럼 게스트에서 `sudo -E ./02_femu_run.sh`를 써도 돼요. 이때는 run마다 FEMU를 다시 띄우라고 물어봐요.

> 셸에서 `pilot.py`를 직접 쓸 때는 먼저 `set -a; . ./config.env; set +a`를 해 주세요.

## 무엇을 Lan과 맞췄고 무엇이 다른가

| 항목 | Lan (원문·저장소) | 파일럿 | 이유 |
|---|---|---|---|
| RocksDB | 7.2.2 + 레벨별 hint 패치 | 같음 (Lan 저장소의 패치를 그대로 적용) | TorFS가 이 조합으로 동작하는 게 Lan 저장소로 확인됨 |
| TorFS | 커밋 0a6e399 | 같음 + `TORFS_FORCE_PID` 패치(single용) | single 정책을 같은 바이너리로 돌리려고 |
| 레벨 수 | 6 (L0–L5) | 6 | — |
| L1 : SST : memtable | 512 : 64 : 128 MB | 4 : 0.5 : 1 MB (같은 비율로 축소) | 장치가 작아서. 마지막 레벨 비중(Lan 약 64%, 파일럿 70–78%)과 RU당 SST 수(Lan 약 195, 파일럿 256)가 비슷해요 |
| L0 trigger, merge, memtable 수 | 2, 2, 6 | 같음 | — |
| dynamic level bytes | false | false | 레벨 번호가 같아야 매핑이 같아요 |
| 압축 | L2부터 LZ4 | 없음 | 쓰기량 단위가 압축률에 흔들리지 않게. Lan의 db_bench 실험도 압축을 껐어요 |
| 값 크기 | YCSB 40 KB | 1 KB | 작은 장치에서 SST 하나에 레코드가 너무 적어지지 않게 (40 KB면 SST 하나에 12개) |
| workload | YCSB-A (zipfian 0.99) | db_bench overwrite (균등 랜덤) | TorFS 연결이 db_bench가 가장 간단해서. 파일럿은 이득이 무너지는지만 보면 돼요 |
| 백그라운드 작업 | 64 | 4 | 작은 장치·FEMU 속도에 맞춤 |

## 미리 알아 둘 것

- **장치 카운터:** 기본값은 `nvme fdp stats`(FDP 통계 로그)에서 HBMW(host 쓰기)와 MBMW(media 쓰기)를 읽어요. 우리 FEMU가 이 로그를 지원하지 않으면 `COUNTER_METHOD=custom`으로 바꾸세요. 그리고 FEMU 통계(H0·H1 때 쓴 GC 계측)를 읽어 `host_bytes media_bytes`를 한 줄로 출력하는 명령을 `COUNTER_CMD`에 넣으세요.
- **RUH별 쓰기:** 기본값은 Lan처럼 `nvme fdp status`의 RUAMW(RU에 남은 쓰기량) 변화로 추정해요. 근사값이라 "PID가 제대로 나뉘어 도착하는지" 확인용으로만 보세요. single은 PID 0만, lan은 0–4가 다 나와야 정상이에요.
- **workload:** 먼저 균등 랜덤으로 돌려요. 이득이 무너지는 게 재현되지 않으면 zipfian(일부 키에 쓰기가 쏠림, Lan의 YCSB-A와 비슷)을 다음에 시도해요. 7.2.2 db_bench의 overwrite에는 키 분포 옵션이 없어서, 그때는 YCSB나 다른 벤치마크를 붙여야 해요.
- **공간 부족:** 93%는 공간 증폭이 크면 장치가 넘쳐요. 인구의 PC 보정값(`SPACE_AMP`)을 꼭 넣고, `pilot.py calc`에 경고가 없는지 확인하세요.
- **시험한 것:** `03_host_loop.sh`는 가짜 FEMU·ssh로 시험했어요. 4 run 반복, `REP=2` 평균, 끝난 run 건너뛰기, 실패 시 멈춤, 접속이 잠깐 끊겼을 때 다시 확인하기, 판정 4가지(무너짐 / 안 무너짐 / 경계 / 보류)를 확인했어요. 진짜 FEMU와 진짜 db_bench로는 아직 안 돌려 봤어요.
- **빌드:** 이 작업 공간에서는 빌드를 직접 돌려 보지 못했어요. 대신 Lan 패치와 TorFS 패치가 해당 버전에 깨끗하게 적용되는 것과, db_bench 7.2.2에 스크립트가 쓰는 옵션이 모두 있는 것은 확인했어요. GCC 13 이상에서 옛 RocksDB가 깨지는 경우가 있어 `-include cstdint`를 미리 넣어 두었어요.
- **이 결과의 한계:** run 1번, 균등 랜덤 workload라 숫자를 논문에 쓰면 안 돼요. "무너짐이 FEMU에서도 보이는가"만 판단해요.

## 결과 폴더

```
인구 PC: $WORK/results/
└── pc_calib_u0.70/      du.csv, levelstats.txt, summary.txt, time.txt

지윤 호스트: $HOST_RESULTS/   (게스트 $WORK/results/ 에서 run마다 복사해 옴)
├── single_u0.70/        counters.csv, ruh.csv, meta.txt, db_bench_*.log, done
├── lan_u0.70/
├── single_u0.93/
├── lan_u0.93/
├── single_u0.93_r2/     (경계일 때만)
├── host_logs/           FEMU 출력, run 출력
└── summary.txt          WAF 표와 판정
```

## 출처

- Lan et al., FDP: The Data Placement Promise of Modern NVMe SSDs — https://arxiv.org/html/2610.02676v2
- Lan 실험 저장소 (RocksDB 패치, OPTIONS 파일, 스크립트, MIT 라이선스) — https://github.com/sijielan/FDP_Benchmarking
- TorFS — https://github.com/SamsungDS/TorFS
