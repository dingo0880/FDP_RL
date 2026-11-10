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
| 보는 것 | overwrite 구간의 WAF = media 쓰기 ÷ host 쓰기, RUH별 쓰기 비율, 장치의 실제 사용률(유효 데이터 ÷ 용량) |
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
| 4 | 인구 | `python3 pilot.py pcfit <보정 폴더 두 개>`로 나온 `SPACE_SLOPE`·`SPACE_FIXED_GIB`를 `config.env`에 넣고 `python3 pilot.py calc`로 N 확인 | `config.env` |
| 5 | 지윤 | FEMU 게스트에서 TorFS 포함 빌드 | `./00_build.sh femu` |
| 6 | 지윤 | 게스트의 `config.env` ★ 항목 채우기(장치 이름, 용량, RU 크기, 카운터 방법) | 게스트 `config.env` |
| 7 | 지윤 | 카운터 읽기 확인: `python3 pilot.py counters`가 숫자 두 개를 출력하는지. 1 GB 쓰고 host 값이 1 GB 늘었는지도 | — |
| 8 | 지윤 | 호스트에 같은 폴더를 두고 `config.env`의 FEMU 자동 재시작 칸 채우기, 아래 "호스트 준비" 확인 | 호스트 `config.env` |
| 9 | 지윤 | 본 파일럿 4 run (호스트에서) | `./03_host_loop.sh` |
| 10 | 같이 | 결과 해석. 경계면 안내대로 `REP=2`로 93% 한 번 더 | `$HOST_RESULTS/summary.txt` |

1–4와 5–8은 동시에 해도 돼요. 9는 4가 끝난 뒤에 해야 공간 부족 없이 돌아가요. 게스트와 호스트의 `SPACE_SLOPE`·`SPACE_FIXED_GIB`는 같은 값이어야 해요.

### 호스트 준비 (8번)

- `FEMU_START_CMD`: FEMU를 **앞에서(foreground)** 띄우는 명령이에요. 평소 FEMU 띄우는 스크립트를 그대로 쓰면 돼요. 뒤로 보내는(`&`, daemonize) 방식이면 스크립트가 꺼짐을 못 알아채요.
- FEMU는 이 브랜치(`fdp-pilot`)에서 빌드한 걸 써야 해요. 사용량 로그(C1h)가 이 브랜치에만 있어요 (아래 "미리 알아 둘 것").
- FEMU를 `sudo`로 띄우면 호스트에서도 `sudo`가 비밀번호 없이 돼야 해요. qemu가 root 프로세스라 FEMU가 안 꺼질 때 강제 종료를 `sudo -n kill`로 보내요. 그래도 못 끄면 스크립트가 pid를 알려 주고 멈춰요.
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
| LSM 설정 기준 | OPTIONS 파일의 `usertable` CF (YCSB가 쓰는 CF) | 같음 | 같은 파일의 `default` CF(L1 512 MB, 레벨 6, trigger 2, memtable 6)는 YCSB가 안 써요 |
| 레벨 수 | 7 (L0–L6) | 7 | — |
| L1 : SST : memtable | 256 : 64 : 128 MiB | 2.5 : 0.5 : 1 MiB (L1은 1/102.4, SST·memtable은 1/128) | 장치가 작아서. RU당 SST 수(Lan 약 195, 파일럿 256)가 비슷해요. L1을 2 MiB가 아니라 2.5 MiB로 둔 이유는 아래 "레벨 목표 크기" |
| 레벨 목표 크기 (multiplier 10) | L1 256 MiB … L5 2.44 TiB | L1 2.5, L2 25, L3 250, L4 2,500, L5 25,000 MiB (24.41 GiB), L6 250,000 MiB | L1을 키우면 L1 다음 레벨도 모두 25% 커져요. 2 MiB(1/128)면 L5 목표가 19.53 GiB라 93%의 논리 데이터(약 19.1 GiB)가 L5 목표의 98%였어요. 마지막 레벨에는 거의 모든 키가 들어가서, 넘치면 L6로 내려가며 같은 키가 겹쳐 쌓여요 |
| L0 trigger, merge, memtable 수 | 4, 2, 24 | 같음 | — |
| L0 slowdown / stop | 20 / 36 | 같음 (CLI로 직접 넘김) | — |
| compaction 밀림 한도 (soft / hard) | 64 / 256 GiB | 0.5 / 2 GiB (1/128) | 한도를 그대로 두면 밀린 양이 작은 장치를 채워요 |
| LOG 크기 제한 | (없음) | 미적용 | RocksDB 7.2.2 DBOptions에는 `max_log_file_size`·`keep_log_file_num`이 있지만 db_bench 7.2.2 CLI에는 플래그가 없어요. LOG가 커요 (아래) |
| 밀렸을 때 쓰기 속도 (`delayed_write_rate`) | 16 MiB/s | 16 MiB/s (같음) | db_bench 기본은 8 MiB/s라 직접 넣어요 |
| dynamic level bytes | false | false | 레벨 번호가 같아야 매핑이 같아요 |
| 압축 | L2부터 LZ4 | 없음 | 쓰기량 단위가 압축률에 흔들리지 않게. Lan의 db_bench 실험도 압축을 껐어요 |
| 값 크기 | YCSB 40 KB | 1 KB | 작은 장치에서 SST 하나에 레코드가 너무 적어지지 않게 (40 KB면 SST 하나에 12개) |
| workload | YCSB-A (zipfian 0.99) | db_bench overwrite (균등 랜덤) | TorFS 연결이 db_bench가 가장 간단해서. 파일럿은 이득이 무너지는지만 보면 돼요 |
| 백그라운드 작업 | 64 | 4 | 작은 장치·FEMU 속도에 맞춤 |

## 장치(FEMU) 설정과 근거

Lan 논문은 장치의 OP·물리 용량·RU 개수·격리 방식(II/PI)을 밝히지 않아요(RUH 8개, RU 약 13.08 GB만 나와요). 그래서 OP와 격리 방식은 **실제 FDP SSD에 맞춰 보정한 WARP(FAST'26)의 기본값**을 따르고, 나머지는 FEMU 제약 안에서 정했어요.

| 항목 | 값 | 근거 |
|---|---|---|
| 격리 방식 | II, 모든 RUH (`fdp.isolation_mode=2`) | WARP §2: 상용 FDP SSD는 처음 설계에서 II를 택했어요. 원본 FEMU는 마지막 RUH만 II가 돼서 이 브랜치에 모드 2를 넣었어요 (위 "II는 …" 참고) |
| RUH 수 | **6개 권장** (PID 0–4 데이터 + RUH 5 GC 전용). 8개도 가능 | Lan 장치는 8개, 그중 5개 사용. FEMU는 **안 쓰는 RUH에도 RU를 하나씩 열어 둬요** (`ftl-fdp.c` 초기화). 8개면 RUH 5·6이 빈 RU 2개를 끝까지 묶어 둬서, 시험(아래)에서 media가 6개일 때보다 18% 많았어요. 이건 FEMU 구현 탓이고 실제 장치도 그런지는 알 수 없어서, OP 효과에 섞이지 않게 6개를 권해요. 쓰는 RUH 구성(데이터 5 + GC 1)은 Lan과 같아요 |
| RU 크기 | 128 MiB = 채널 8 × LUN 8 × 블록당 512페이지 × 4 KiB | bbssd는 RU가 superblock 하나예요. WARP 공개 스크립트의 128 MiB RU 배치와 같아요 |
| 사용자 용량 | 24 GiB (`devsz_mb=24576`, RU 192개) | Lan 장치(3.84 TB ÷ 13.08 GB ≈ 294개)와 RU 개수 규모가 비슷하고, 시간·메모리 안에 들어와요 |
| OP | **10% → 전체 RU 211개 (실제 9.9%)**, `blks_per_pl=211`, `fdp.nru=211` | WARP §5 기본값 "RU=256MB, OP=10%, lazy GC 5%, RUH 8개"(실제 장치 WAF에 맞춰 보정). 계산식은 WARP 공개 스크립트와 같아요: `RU 개수 = 사용자 용량 × 1.1 ÷ RU 크기` = 24 × 1.1 × 1024 ÷ 128 = 211.2 → 211. FEMU의 `op_pcent`도 같은 정의(사용자 용량 × (1 + OP))예요. `op_pcent=10`을 쓰면 사용자 용량이 23.98 GiB가 돼서, RU 개수로 맞췄어요 |
| GC | `gc_thres_pcent=75`, `gc_thres_pcent_high=95` (원본 기본값) | 지윤 결정. WARP의 보정에는 lazy GC 5%, 블록 재매핑, 백그라운드 약 90%·포그라운드 약 99%가 같이 들어가는데(WARP §4.3), 최신 원본 FEMU에는 lazy GC와 재매핑이 없어요. 그래서 OP 숫자는 WARP와 같아도 **WAF 절댓값은 WARP와 다를 수 있어요.** 파일럿은 같은 조건 안의 비교로만 봐요 |

**FEMU가 받아 주는 하한.** 전체 RU에서 RUH마다 열린 RU 1개와 강제 GC용 빈 RU(전체의 5%, 버림)를 빼고도 사용자 RU 192개가 남아야 FEMU가 떠요 (`bb_fdp_reserve_units`, 시작할 때 검사).
- RUH 8개: RU 210개(OP 9.4%)부터. 209개는 시작 오류예요.
- RUH 6개: RU 208개(OP 8.3%)부터. 207개는 시작 오류예요.
- 둘 다 FEMU를 직접 띄워서 확인했어요.
- 그래서 **OP 7%는 이 설정으로 만들 수 없어요.** 하려면 GC 강제 기준(95%)을 바꿔야 해서 GC 동작이 같이 바뀌어요. 본 실험에서 OP를 바꿔 볼 때는 10 / 17 / 28%처럼 하한 위에서 잡아요(WARP는 OP 1~28%를 다뤘어요, §4.4).

**RU 211개로 시험한 것 (qtest, RU 크기만 작게 줄이고 RU 개수는 같게).** 모두 II, PID 0–4로 namespace를 100% 채운 뒤 4배 덮어쓰기:
- RUH 8개·6개 모두 쓰기 15,360번 중 실패 0. 모든 페이지가 마지막에 쓴 버전으로 읽혔고, 매핑 손실·RU 목록 오류 0. 빈 RU는 최소 11개(강제 GC 기준 10개)까지 내려갔어요. GC가 막히지 않아요.
- RUH 8개는 RUH 5·6이 쓰기 0·유효 0인 RU를 하나씩 끝까지 붙잡고 있었어요.
- 100%까지 채우고 RU가 아주 작은 극단 조건이라 숫자 자체는 파일럿 결과를 예측하지 않아요. 방향만 봐요.

**FEMU를 띄울 메모리.** 원본 FEMU는 SSD 데이터를 전부 RAM에 올리고 `mlock`해요(`backend/dram.c`). RU 211개 × 128 MiB ≈ 26.4 GiB에 게스트 메모리가 더 필요해요. 그만큼 RAM이 없는 호스트면 데이터를 파일에 올리는 기능(master의 `FEMU_MBE_FILE`)을 이 브랜치로 가져와야 해요.

## 미리 알아 둘 것

- **장치 카운터:** 기본값은 `nvme fdp stats`(FDP 통계 로그, 22h)에서 HBMW(host 쓰기)와 MBMW(media 쓰기)를 읽어요. 원본 FEMU에 있는 표준 로그예요. 다른 장치에서 이 로그가 없으면 `COUNTER_METHOD=custom`으로 바꾸고, `host_bytes media_bytes`를 한 줄로 출력하는 명령을 `COUNTER_CMD`에 넣으세요.
- **RUH별 쓰기와 실제 사용률 (`RUH_METHOD=femu`, 기본):** 이 브랜치의 FEMU에 사용량 로그(vendor log C1h, `hw/femu/nvme.h`의 `FemuFdpUsageLog`)를 넣었어요. `nvme get-log --log-id=0xc1`로 읽어요.
  - RUH마다 host 쓰기량(HBMW), media 쓰기량(MBMW, 그 RUH가 가진 RU를 GC할 때 옮긴 양 포함), 그 RUH가 가진 RU의 유효 페이지를 정확히 줘요.
  - 장치 전체의 유효 페이지와 용량도 줘서, 실제 사용률을 바로 계산할 수 있어요.
  - 필요한 이유 두 가지:
    - 최신 원본 FEMU는 RUH Usage 로그(21h)를 표준대로 8바이트로 줄였어요(커밋 1bc8508a6). 그래서 RUH별 쓰기량을 볼 길이 없어요.
    - TorFS는 파일을 지울 때 DEALLOCATE를 백그라운드 스레드가 나중에 보내요. 그래서 장치가 PC 보정값보다 더 찰 수 있어 실제 사용률을 장치에서 직접 재요.
  - 이 로그는 FEMU qtest `fdp-usage-log`로 확인했어요: query-femu·FDP 통계 로그와 값이 같고, 유효 페이지가 FTL 매핑과 같아요.
  - single은 PID 0만, lan은 0–4가 다 나와야 정상이에요.
  - **II에서 RUH별 값을 읽는 법 (주의):** GC로 옮긴 데이터는 마지막 RUH(GC 전용)의 RU에 모여요.
    - 유효 페이지: 옮겨진 몫은 마지막 RUH에 잡혀요.
    - media 쓰기량: GC는 RU를 가진 RUH에 매겨져요. 그래서 데이터가 원래 RUH의 RU에서 **처음 옮겨질 때만** 원래 RUH에 잡히고, 마지막 RUH의 RU에 들어간 뒤 다시 GC되면 **마지막 RUH에** 잡혀요.
    - 그래서 RUH별 media는 "데이터 종류(PID)별 GC 비용"이 아니에요. 시험(RU 211개, 모두 II, 100% 채운 뒤 4배 덮어쓰기)에서 host 쓰기가 0인 GC RUH가 media의 81%를 차지했고, 유효 데이터의 93%가 GC RUH에 모여 있었어요.
    - 파일럿 판정(전체 WAF)에는 영향이 없어요. 갈래 A에서 데이터 종류별로 GC 비용을 나누려면, FEMU가 페이지마다 처음 쓴 RUH를 기억하게 고쳐야 해요.
- **RUAMW 방식 (`RUH_METHOD=fdpstatus`):** 실제 FDP SSD처럼 이 로그가 없을 때 쓰는 근사예요. `nvme fdp status`의 RUAMW 변화로 추정해요.
  - RUAMW는 LBA 단위예요. LBA 크기는 run마다 `nvme id-ns`로 읽어 run 폴더의 `lba_bytes`에 남기고, summary가 그 값을 써요.
  - FEMU 기본은 512 B이고 실제 FDP SSD는 보통 4 KiB예요. 못 읽으면 `config.env`의 `LBA_BYTES`를 써요.
  - 샘플 사이에 RU를 두 개 넘게 쓰면 덜 세요.
- **II는 `fdp.isolation_mode=2`로 띄워야 해요.**
  - 원본 FEMU는 `fdp.isolation_mode=1`이어도 마지막 RUH 하나만 II이고 나머지는 전부 PI예요 (`hw/femu/femu.c`, RUH 종류를 정하는 부분). FDP 설정 로그(20h, `nvme fdp configs`가 읽는 로그)로 확인했어요: 모드 0은 RUH 0–3 모두 PI, 모드 1은 RUH 0–2 PI·RUH 3만 II.
  - 그래서 이 브랜치에 `fdp.isolation_mode=2`(모든 RUH II)를 넣었어요. GC가 모든 RUH의 유효 데이터를 마지막 RUH의 RU로 옮겨서, 서로 다른 RUH의 데이터가 섞여요. FTL은 원래 여러 II RUH를 이렇게 처리하게 짜여 있었고, RUH 종류를 정하는 부분과 RU 예약 계산만 바꿨어요.
  - qtest `fdp-all-ii`로 확인했어요: 모든 RUH가 II로 보이고, GC가 여러 번 돈 뒤에도 데이터가 다 맞게 읽히고, 매핑과 RU 목록이 정상이고, host가 안 쓴 마지막 RUH에 GC 데이터가 모여요.
  - 파일럿은 II로만 돌려요. `FEMU_START_CMD`에 `fdp.isolation_mode=2`를 넣어요. PI 비교는 갈래 A에서 해요. RUH 수와 OP는 아래 "장치(FEMU) 설정과 근거"를 보세요.
  - `02_femu_run.sh`가 run마다 `nvme fdp configs`로 RUH 종류를 읽어 run 폴더의 `ruh_types`에 남기고, PID 0–4가 `EXPECT_RUHT`(II)가 아니면 멈춰요.
- **workload:** 먼저 균등 랜덤으로 돌려요. 이득이 무너지는 게 재현되지 않으면 zipfian(일부 키에 쓰기가 쏠림, Lan의 YCSB-A와 비슷)을 다음에 시도해요. 7.2.2 db_bench의 overwrite에는 키 분포 옵션이 없어서, 그때는 YCSB나 다른 벤치마크를 붙여야 해요.
- **실효 옵션 확인:** 스크립트는 옵션 파일 없이 CLI로만 넘겨요. 그래서 run마다 DB를 연 직후 RocksDB LOG의 `Options.*` 줄을 `config.env` 기대값과 대조해요 (`pilot.py optcheck`, 결과는 run 폴더의 `options_check_load.txt`·`options_check_overwrite.txt`, 근거는 `rocksdb_LOG_<단계>_head.txt`). 불일치·누락이면 run을 멈춰요 (`OPTCHECK_STRICT=0`이면 기록만). PC는 `PC_DB_DIR/LOG`, FEMU는 `TORFS_DB_DIR/LOG`(TorFS가 LOG를 로컬 파일시스템으로 넘겨요: TorFS 0a6e399 `TorFS::NewLogger`)를 봐요.
- **단계 경계 (PC·FEMU 같음):** db_bench 는 load 한 번, overwrite 한 번만 열어요 (단계마다 다시 열면 WAL 복구·flush 로 상태가 바뀌어서). 프로세스 안의 경계는 출력에 찍은 시각으로 나눠요 (`lib/runlib.sh`).
  - `<단계>_open` 프로세스 시작 → DB 열림 (LOG `DB pointer` 줄 시각, 마이크로초)
  - `<단계>` 실제 실행 → 결과 줄(`overwrite : … micros/op`) 시각. db_bench 가 이 줄 뒤에 `fflush(stdout)` 해요
  - `<단계>_wait` waitforcompaction(5초 쉬고 10초마다 확인, 마지막 `finished` 줄) + levelstats·stats → 프로세스 끝
  - `<단계>_logsave` LOG 앞부분·OPTIONS·LOG 전체 gzip
  - 시각은 `phase_events.txt`, 줄마다 받은 시각은 `db_bench_<단계>.stdout.ts`·`.stderr.ts`, 단계별 시간은 `time.txt`.
  - `waitforcompaction` 줄은 db_bench 가 fflush 를 안 해서, stdout 을 줄 버퍼로 바꾸는 `liblinebuf.so`(`lib/linebuf.c`, 처음 실행 때 gcc 로 빌드)를 db_bench 에 LD_PRELOAD 로 올려요. `stdbuf` 는 안 써요: 이 PC 의 stdbuf(uutils coreutils 0.8.0)는 LD_PRELOAD 를 덮어써서 libnofsync.so 가 빠졌어요 (fsync 200번 0 ms → 1291 ms). 실제로 올라온 라이브러리는 `cmd_<단계>.txt` 에 `/proc/<pid>/maps` 로 남겨요.
  - 샘플러(PC du 5초, FEMU 카운터 `SAMPLE_SEC`)는 1초마다 단계를 보고, 바뀌면 바뀌기 전·후 이름으로 한 번씩 찍어요. 그래서 각 단계의 첫·마지막 샘플이 경계에서 1~2초 안이에요.
  - **주 WAF·뒤 1/3 WAF·뒤 1/3 사용률·RUH 비율은 `overwrite`(실제 실행) 구간만**으로 계산해요. 대기·LOG 저장 중 쓰기는 따로 보여 줘요 (PC: LOG 의 `table_file_creation` 합, FEMU: 카운터 차이). 공간·사용률 최대는 load·overwrite·대기·LOG 저장 전체에서 계속 모아요.
- **NOFSYNC (PC 예비 보정):** PC 보정은 fsync 를 건너뛰어요 (`LD_PRELOAD=libnofsync.so`, WSL 에서 fsync 한 번 9~17 ms 라서). 그래서 PC 의 공간 식·시간은 예비값이에요. FEMU 의 검증된 공간 상한이나 성능 측정값으로 쓰지 마세요. `pcsummary`·`pctrack`·`pcfit` 출력에도 이 주의가 나와요.
- **run 기록:** `run_params.txt`에 SCALE·OVERWRITE_MULT(밖에서 받은 값 포함)·SEED·THREADS·`--num`·스레드당 `--writes`·전체 overwrite 연산 수와 N 대비 배수·NOFSYNC/LD_PRELOAD·(FEMU) 정책과 `TORFS_FORCE_PID`를 남겨요. 실제 명령은 `cmd_<단계>.txt`, db_bench 출력은 `db_bench_<단계>.stdout`·`.stderr`로 따로 남겨요. 키 공간은 늘 `--num=N`이고 덮어쓰기 양은 `--writes`(스레드당) x 스레드 수로만 바꿔요.
- **공간 (PC):** DB 폴더(`PC_DB_DIR`)는 실험용 이미지(`/dev/loop0` ext4, 50 GiB 고정 파일 `pcdisk.img`), 결과 폴더(`RESULTS`)는 WSL 루트(`/dev/sdd` ext4, 가상 디스크라 실제 한계는 C: 여유이고 커지면 안 줄어요)에 있어요.
  - LOG 원본은 DB 폴더에 쌓이고 run 중에는 안 줄어요. 끝날 때 gzip 이 결과 폴더로 압축본을 만들지만 원본은 지우지 않아서, gzip 동안과 그 뒤에도 원본(DB 폴더)·압축본(결과 폴더)이 같이 있어요. 원본은 다음 단계(overwrite) 시작 직전이나 다음 사용률 run 시작 때(`PC_DB_DIR` 를 지움) 없어져요.
  - 측정: SST 를 1 GiB 쓸 때 LOG 원본 약 4.5~5.1 MB, gzip 은 원본의 약 1/16.
- **LOG 크기:** L1 2 MiB 70% load에서 2시간에 1.37 GB였어요. 대부분 SST마다 남는 `table_file_creation` 기록이에요. FEMU 게스트의 로컬 디스크 여유를 확인하세요. 전체 LOG는 run이 끝날 때 gzip으로 run 폴더에 남겨요 (`SAVE_FULL_LOG=0`이면 안 남김).
- **진행 추적:** `TRACK_STATS=1`(기본)이면 db_bench에 `--stats_per_interval=1 --stats_dump_period_sec=60`을 더해, 60초마다 레벨별 크기·compaction·stall 통계가 stderr와 LOG에 찍혀요. `pilot.py pctrack <run 폴더>`가 로그만 읽어서 1배·2배·3배 근처 샘플(전체 스레드 누적 완료 연산 수가 N·2N·3N을 처음 넘은 60초 샘플, 정확한 경계 아님), L5·L6 크기, L5→L6 compaction, 공간 최대와 뒤 1/3 평균, stall을 정리해요. pending compaction 바이트는 60초 통계에 없어서 연속값은 없고, LOG의 stall 경고(soft 한도 이상일 때)로만 보여요.
- **공간 부족:** 93%는 공간이 예상보다 크면 장치가 넘쳐요. 인구의 PC 보정값(`SPACE_SLOPE`·`SPACE_FIXED_GIB`)을 꼭 넣고, `pilot.py calc`에 경고가 없는지 확인하세요.
  - 공간 식이 곱하기(공간 증폭) 하나가 아니라 "기울기 x 논리 + 고정량"인 이유: 레벨 크기를 고정해서(dynamic level bytes 끔) L1~L4가 데이터 양과 상관없이 거의 일정해요. 그래서 공간 증폭은 데이터가 작을수록 커져요 (L1 4 MB 보정: 70% 1.335, 93% 1.261 → 기울기 1.035, 고정량 4.30 GiB로 두 점이 다 맞음).
  - 지금 `config.env`의 `SPACE_SLOPE=1.034`, `SPACE_FIXED_GIB=2.6875`는 임시값이에요 (L1 2.5 MiB·레벨 7 실측 아님). 같은 새 설정으로 70%·93%를 보정한 뒤 `pcfit`으로 다시 맞춰야 해요.
  - `SPACE_MARGIN=0.02` 때문에 모델상 실제 최고 사용률은 목표 / 1.02예요: 목표 93% → 약 91.2%, 70% → 약 68.6%.
  - `calc`는 논리 데이터를 마지막 레벨의 목표 크기와 비교해서 보여 줘요. 마지막 레벨에는 거의 모든 키가 들어가서, 이게 100%를 넘으면 한 레벨 아래로 내려가기 시작하고 같은 키가 두 레벨에 겹쳐 쌓여 공간이 식보다 커져요.
- **시험한 것:**
  - `03_host_loop.sh`는 가짜 FEMU·ssh로 시험했어요. 4 run 반복, `REP=2` 평균, 끝난 run 건너뛰기, 실패 시 멈춤, 접속이 잠깐 끊겼을 때 다시 확인하기, 판정 4가지(무너짐 / 안 무너짐 / 경계 / 보류)를 확인했어요.
  - 가짜 ssh 시험에서는 원격 실행 줄이 run 끝까지 안 돌아오는 문제가 안 보였어요. 출력 연결을 끝까지 기다리는 방식으로 다시 시험해서 `{ nohup … & }`로 고쳤어요.
  - 진짜 FEMU와 진짜 db_bench로는 아직 안 돌려 봤어요.
- **빌드:** 이 작업 공간에서는 빌드를 직접 돌려 보지 못했어요. 대신 Lan 패치와 TorFS 패치가 해당 버전에 깨끗하게 적용되는 것과, db_bench 7.2.2에 스크립트가 쓰는 옵션이 모두 있는 것은 확인했어요. GCC 13 이상에서 옛 RocksDB가 깨지는 경우가 있어 `-include cstdint`를 미리 넣어 두었어요.
- **이 결과의 한계:** run 1번, 균등 랜덤 workload라 숫자를 논문에 쓰면 안 돼요. "무너짐이 FEMU에서도 보이는가"만 판단해요.

## 결과 폴더

```
인구 PC: $WORK/results/
└── pc_calib_u0.70/      du.csv, levelstats.txt, summary.txt, time.txt

지윤 호스트: $HOST_RESULTS/   (게스트 $WORK/results/ 에서 run마다 복사해 옴)
├── single_u0.70/        counters.csv, usage.csv(실제 사용률), ruh_usage.csv(RUH별 쓰기·유효 데이터), lba_bytes, ruh_types, meta.txt, db_bench_*.log, done
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
- Song et al., Characterizing and Emulating FDP SSDs with WARP (FAST'26) — https://www.usenix.org/system/files/fast26-song.pdf
- WARP 공개 스크립트(FEMU 설정, OP 계산식) — https://github.com/MoatLab/WARP-FAST26-AE
- TorFS — https://github.com/SamsungDS/TorFS
