#!/usr/bin/env python3
"""93% 3배 run 에서 '덮어쓰기 k배 지점'의 공간 값을 뽑아요 (DB·로그는 읽기만).

  python3 point_at.py <93% 결과 폴더> <배수> [<만들 폴더>]

- 진행: stderr.ts 의 스레드별 60초 진행 줄(누적 ops)을 시간으로 선형 보간해서 4 스레드 합이
  배수 x N 이 되는 시각을 구해요 (근사값: 진행 줄이 60초 간격이라 몇십 초 오차가 있어요).
- 공간: du.csv(LOG 제외) 에서 그 시각까지의 최고값. pc_point 와 같게 load 단계까지 포함해요.
- <만들 폴더>를 주면 pcfit 이 읽을 수 있게 logical_bytes, du.csv(그 시각까지), run_params.txt 를 만들어요.
"""
import csv, os, re, sys

GiB = 1024 ** 3
src, mult = sys.argv[1], float(sys.argv[2])
out = sys.argv[3] if len(sys.argv) > 3 else None

N = int(open(os.path.join(src, "logical_bytes")).read()) // 1040
ev = {}
for line in open(os.path.join(src, "phase_events.txt")):
    p = line.split()
    if len(p) >= 2:
        ev.setdefault(p[1], float(p[0]))
x0 = ev["overwrite_exec_start"]

PROG = re.compile(r"^([\d.]+)\t.*thread (\d+): \(\d+,(\d+)\) ops")
series = {}
for line in open(os.path.join(src, "db_bench_overwrite.stderr.ts"), errors="replace"):
    m = PROG.match(line)
    if m:
        series.setdefault(int(m.group(2)), [(x0, 0)]).append((float(m.group(1)), int(m.group(3))))


def cum(s, t):
    if t <= s[0][0]:
        return 0.0
    for (t0, c0), (t1, c1) in zip(s, s[1:]):
        if t0 <= t <= t1:
            return c0 + (c1 - c0) * (t - t0) / max(1e-9, t1 - t0)
    return float(s[-1][1])


def total(t):
    return sum(cum(s, t) for s in series.values())


t_end = min(s[-1][0] for s in series.values())          # 모든 스레드의 마지막 진행 줄 중 가장 이른 것
done_x = total(t_end) / N


def t_at(x):
    target = x * N
    if total(t_end) < target:
        return None
    lo, hi = x0, t_end
    for _ in range(60):
        mid = (lo + hi) / 2
        if total(mid) >= target:
            hi = mid
        else:
            lo = mid
    return hi


rows = list(csv.DictReader(open(os.path.join(src, "du.csv"))))
logical = N * 1040
print(f"원본: {src}")
print(f"N={N}, 논리 데이터 {logical/GiB:.2f} GiB, 스레드 {len(series)}개, 진행 줄 기준 마지막 {done_x:.2f}배")
print(f"  배수   overwrite 시작 후   그때까지 최고(LOG 제외)   그 시각 사용량")
x = 0.25
while x <= done_x + 1e-9:
    t = t_at(x)
    seg = [r for r in rows if float(r["ts"]) <= t]
    pk = max(int(r["total_bytes"]) for r in seg)
    now = int(seg[-1]["total_bytes"])
    print(f"  {x:4.2f}배  {(t-x0)/3600:6.1f} 시간        {pk/GiB:7.2f} GiB ({pk/GiB/24*100:5.1f}%)   {now/GiB:7.2f} GiB")
    x += 0.25

t1 = t_at(mult)
if t1 is None:
    sys.exit(f"[point_at] 아직 {mult}배에 못 미쳐요 (지금 {done_x:.2f}배)")
seg = [r for r in rows if float(r["ts"]) <= t1]
pk = max(int(r["total_bytes"]) for r in seg)
print(f"{mult}배 지점: overwrite 시작 후 {(t1-x0)/3600:.2f} 시간 (epoch {t1:.0f}), 그때까지 최고 {pk/GiB:.3f} GiB"
      f" (공간 증폭 {pk/logical:.3f}, 24 GiB 의 {pk/GiB/24*100:.1f}%)")

if out:
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "du.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=rows[0].keys())
        w.writeheader()
        w.writerows(seg)
    open(os.path.join(out, "logical_bytes"), "w").write(str(logical) + "\n")
    rp = open(os.path.join(src, "run_params.txt"), encoding="utf-8").read()
    open(os.path.join(out, "run_params.txt"), "w", encoding="utf-8").write(
        rp + f"\n# point_at.py 로 만든 파생 폴더: {src} 의 3배 run 에서 {mult}배 지점까지(epoch {t1:.0f})의 du.csv 만 잘라 둠.\n"
             f"# (3배 run 진행 줄 기준 {done_x:.2f}배까지 기록됨.) 이 점은 '{mult}배까지 덮어쓴 동안의 최고 사용량'이에요"
             f" (1배로 끝까지 돌린 run 과 달리 끝의 waitforcompaction 구간은 없음, 진행 보간이라 근사).\n")
    print(f"파생 폴더 만듦: {out}")
