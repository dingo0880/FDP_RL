#!/usr/bin/env python3
"""FDP 파일럿 보조 도구.

하위 명령
  calc        config.env 값으로 키 개수·쓰기량·레벨 비중을 계산 (실행 전 확인용)
  get         calc 결과 중 한 값만 출력 (실행 스크립트가 씀)
  counters    장치 카운터를 읽어 "host_bytes media_bytes" 한 줄 출력
  usage       FEMU 사용량 로그(C1h)를 읽어 첫 줄 "valid_bytes capacity_bytes",
              다음 줄부터 RUH마다 "ruh hbmw mbmw live_bytes" 출력 (RUH_METHOD=femu)
  ruh         RUH(PID)별 상태를 읽어 "pid value" 줄들 출력 (RUH_METHOD=fdpstatus·custom)
  lbasize     장치의 LBA 크기(B)를 'nvme id-ns'로 읽어 출력 (RUAMW 단위, run마다 기록)
  ruhtypes    FDP 설정 로그(20h, 'nvme fdp configs')에서 RUH마다 "ruh II|PI" 출력
  pcsummary   인구의 PC 보정 결과 요약 (공간 증폭, 레벨 비중, MANIFEST 비중)
  summary     FEMU run 결과를 모아 WAF 표와 판정 출력

설정은 환경변수로 받습니다. 셸에서 `set -a; . ./config.env; set +a` 후 실행하세요.
표준 라이브러리만 씁니다.
"""
import argparse
import csv
import glob
import json
import math
import os
import re
import struct
import subprocess
import sys

GiB = 1024 ** 3
MiB = 1024 ** 2

# Lan et al. YCSB-A 참고값 (sijielan/FDP_Benchmarking 의 workloada, OPTIONS-000009)
LAN_REF = {
    "logical_bytes": 40_000_000 * 10 * 4096,   # 레코드 4천만 개 x 필드 10개 x 4 KB
    "level_base": 512 * MiB,
    "target_file": 64 * MiB,
    "num_levels": 6,
    "ru_bytes": 13.08e9,                        # PM9D3a 3.84 TB 의 RU 크기
}


def env(name, cast=str, default=None):
    v = os.environ.get(name)
    if v is None or v == "":
        if default is None:
            sys.exit(f"[pilot] 환경변수 {name} 가 없습니다. config.env 를 먼저 읽어 주세요.")
        return default
    return cast(v)


def level_layout(logical, base, mult, num_levels):
    """동적 레벨 크기를 끈 상태(Lan 설정)에서 L1부터 차례로 채운다고 보고 레벨별 크기를 근사."""
    sizes = {}
    remain = logical
    cap = base
    for lvl in range(1, num_levels):
        last = lvl == num_levels - 1
        take = remain if last else min(remain, cap)
        sizes[lvl] = take
        remain -= take
        cap *= mult
        if remain <= 0:
            break
    return sizes


def last_nonempty_share(sizes, logical):
    lvl = max(k for k, v in sizes.items() if v > 0)
    return lvl, sizes[lvl] / logical


def plan(util):
    cap = env("DEV_CAPACITY_GIB", float) * GiB
    samp_measured = env("SPACE_AMP", float)
    margin = env("SPACE_MARGIN", float, 0.0)
    samp = samp_measured * (1 + margin)
    kv = env("KEY_SIZE", int) + env("VALUE_SIZE", int)
    base = env("LEVEL_BASE_MB", float) * MiB
    mult = env("LEVEL_MULT", float)
    nl = env("NUM_LEVELS", int)
    threads = env("THREADS", int)
    omult = env("OVERWRITE_MULT", float)
    ru = env("RU_MIB", float) * MiB

    logical = util * cap / samp
    n = int(logical // kv)
    logical = n * kv
    ow_total = omult * logical
    w_per_thread = int(math.ceil(ow_total / kv / threads))
    target_file = int(base / 8)
    write_buffer = int(base / 4)
    sizes = level_layout(logical, base, mult, nl)
    lvl, share = last_nonempty_share(sizes, logical)
    return {
        "util": util,
        "N": n,
        "logical_gib": logical / GiB,
        "expected_peak_gib": logical * samp / GiB,
        "space_amp_used": samp,
        "peak_util_if_measured": logical * samp_measured / cap,
        "overwrite_writes_per_thread": w_per_thread,
        "overwrite_total_gib": w_per_thread * threads * kv / GiB,
        "level_base_bytes": int(base),
        "target_file_bytes": target_file,
        "write_buffer_bytes": write_buffer,
        "last_level": lvl,
        "last_level_share": share,
        "files_per_ru": ru / target_file,
        "levels_gib": {k: v / GiB for k, v in sizes.items()},
    }


def cmd_calc(a):
    utils = [float(x) for x in env("TARGET_UTILS").split()]
    lan_sizes = level_layout(LAN_REF["logical_bytes"], LAN_REF["level_base"], 10, LAN_REF["num_levels"])
    lan_lvl, lan_share = last_nonempty_share(lan_sizes, LAN_REF["logical_bytes"])
    print("== 참고: Lan YCSB-A (압축 무시한 근사) ==")
    print(f"  마지막 레벨 L{lan_lvl} 비중 약 {lan_share*100:.0f}%,"
          f" RU 하나당 SST 약 {LAN_REF['ru_bytes']/LAN_REF['target_file']:.0f}개")
    print()
    for u in utils:
        p = plan(u)
        print(f"== 목표 장치 사용률 {u*100:.0f}% ==")
        print(f"  load 키 개수 N            : {p['N']:,}")
        print(f"  논리 데이터               : {p['logical_gib']:.2f} GiB")
        print(f"  계산에 쓴 공간 증폭       : {p['space_amp_used']:.3f}"
              f" (측정 {env('SPACE_AMP')} x 여유 {1+env('SPACE_MARGIN', float, 0.0):.2f})")
        print(f"  예상 최대 사용량(여유 포함): {p['expected_peak_gib']:.2f} GiB"
              f" (사용자 용량 {env('DEV_CAPACITY_GIB')} GiB)")
        print(f"  측정값이 맞으면 최고 사용률: {p['peak_util_if_measured']*100:.1f}%")
        print(f"  overwrite 스레드당 쓰기 수 : {p['overwrite_writes_per_thread']:,}"
              f" (합계 {p['overwrite_total_gib']:.1f} GiB)")
        print(f"  L1 기준 / SST / memtable  : {p['level_base_bytes']/MiB:.2f} / "
              f"{p['target_file_bytes']/MiB:.2f} / {p['write_buffer_bytes']/MiB:.2f} MiB")
        lv = ", ".join(f"L{k} {v:.2f}" for k, v in p["levels_gib"].items())
        print(f"  레벨별 근사 크기(GiB)     : {lv}")
        print(f"  마지막 레벨 L{p['last_level']} 비중     : {p['last_level_share']*100:.0f}%"
              f"  (Lan 약 {lan_share*100:.0f}%)")
        print(f"  RU 하나당 SST 수          : {p['files_per_ru']:.0f}"
              f"  (Lan 약 {LAN_REF['ru_bytes']/LAN_REF['target_file']:.0f})")
        if p["expected_peak_gib"] > 0.97 * env("DEV_CAPACITY_GIB", float):
            print("  [경고] 예상 최대 사용량이 용량의 97%를 넘습니다. 공간 부족으로 멈출 수 있어요.")
        print()


def cmd_get(a):
    p = plan(float(a.util))
    v = p[a.field]
    print(v if not isinstance(v, float) else f"{v:.6f}")


# ---------------- 장치 카운터 ----------------

def _num(v):
    if isinstance(v, (int, float)):
        return int(v)
    if isinstance(v, str):
        s = v.strip().replace(",", "")
        return int(s, 16) if s.lower().startswith("0x") else int(float(s))
    if isinstance(v, list):          # 128비트 값을 [low, high] 로 주는 경우
        tot = 0
        for i, x in enumerate(v):
            tot += _num(x) << (64 * i)
        return tot
    raise ValueError(v)


def _find_key(obj, pattern):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if re.fullmatch(pattern, str(k), re.I):
                return v
            r = _find_key(v, pattern)
            if r is not None:
                return r
    elif isinstance(obj, list):
        for x in obj:
            r = _find_key(x, pattern)
            if r is not None:
                return r
    return None


def read_fdpstats(dev, endgrp):
    base = ["nvme", "fdp", "stats", dev, "-e", str(endgrp)]
    try:
        out = subprocess.run(base + ["-o", "json"], capture_output=True, text=True, check=True).stdout
        j = json.loads(out)
        h, m = _find_key(j, r"hbmw"), _find_key(j, r"mbmw")
        if h is not None and m is not None:
            return _num(h), _num(m)
    except Exception:
        pass
    out = subprocess.run(base, capture_output=True, text=True, check=True).stdout
    h = re.search(r"HBMW[^\d]*([\d,]+)", out, re.I)
    m = re.search(r"MBMW[^\d]*([\d,]+)", out, re.I)
    if not (h and m):
        sys.exit("[pilot] 'nvme fdp stats' 출력에서 HBMW/MBMW를 못 찾았어요. COUNTER_METHOD=custom 을 쓰세요.\n" + out)
    return _num(h.group(1)), _num(m.group(1))


def cmd_counters(a):
    method = env("COUNTER_METHOD")
    if method == "fdpstats":
        h, m = read_fdpstats(env("NVME_DEV"), env("FDP_ENDGRP", int))
    elif method == "custom":
        out = subprocess.run(env("COUNTER_CMD"), shell=True, capture_output=True, text=True, check=True).stdout
        h, m = (_num(x) for x in out.split()[:2])
    else:
        sys.exit(f"[pilot] 알 수 없는 COUNTER_METHOD={method}")
    print(h, m)


# FEMU 사용량 로그(vendor log C1h, 이 브랜치의 hw/femu/nvme.h FemuFdpUsageLog)
#   머리 64 B: version u16, nruh u16, page_bytes u32, valid_pages u64, capacity_bytes u64
#   RUH마다 32 B: hbmw u64, mbmw u64, live_pages u64
#   mbmw에는 그 RUH의 host 쓰기와, 그 RUH가 가진 RU를 GC할 때 옮긴 양이 같이 잡혀요.
#   live_pages는 그 RUH가 가진 RU에 지금 있는 유효 페이지예요.
#   II에서는 GC로 옮긴 데이터가 마지막 RUH의 RU에 모여요. 그래서 데이터가 원래 RUH에서
#   처음 옮겨질 때만 원래 RUH의 mbmw에 잡히고, 그 뒤 다시 옮겨지면 마지막 RUH에 잡혀요.
#   즉 RUH별 mbmw는 데이터 종류(PID)별 GC 비용이 아니에요 (README "II에서 RUH별 값을 읽는 법").
FEMU_USAGE_HDR = struct.Struct("<HHIQQ40x")
FEMU_USAGE_DESC = struct.Struct("<QQQ8x")


def parse_femu_usage(blob):
    if len(blob) < FEMU_USAGE_HDR.size:
        raise ValueError(f"로그가 {len(blob)} B뿐이에요")
    ver, nruh, page_bytes, valid, cap = FEMU_USAGE_HDR.unpack_from(blob, 0)
    if ver != 1:
        raise ValueError(f"모르는 로그 version {ver}")
    ruhs = []
    for i in range(nruh):
        off = FEMU_USAGE_HDR.size + i * FEMU_USAGE_DESC.size
        if off + FEMU_USAGE_DESC.size > len(blob):
            raise ValueError(f"RUH {nruh}개인데 로그가 {len(blob)} B에서 끝나요")
        h, m, live = FEMU_USAGE_DESC.unpack_from(blob, off)
        ruhs.append((i, h, m, live * page_bytes))
    return {"valid_bytes": valid * page_bytes, "capacity_bytes": cap, "ruhs": ruhs}


def read_femu_usage():
    lid = int(str(env("FEMU_USAGE_LID", str, "0xc1")), 0)
    # 4 KiB를 달라고 해도 장치는 로그 크기만큼만 채우고, 나머지는 0이에요 (RUH 126개까지)
    out = subprocess.run(["nvme", "get-log", env("NVME_DEV"), f"--log-id={lid}",
                          "--log-len=4096", "--raw-binary"],
                         capture_output=True, check=True).stdout
    return parse_femu_usage(out)


def cmd_usage(a):
    u = read_femu_usage()
    print(u["valid_bytes"], u["capacity_bytes"])
    for ruh, h, m, live in u["ruhs"]:
        print(ruh, h, m, live)


def read_lba_bytes(dev):
    """지금 포맷의 LBA 크기(B). 'nvme id-ns'의 FLBAS가 가리키는 LBA 포맷의 LBADS(2의 지수)로 계산."""
    out = subprocess.run(["nvme", "id-ns", dev, "-o", "json"],
                         capture_output=True, text=True, check=True).stdout
    j = json.loads(out)
    flbas = _num(j["flbas"])
    idx = (flbas & 0xF) | (((flbas >> 5) & 0x3) << 4)   # 포맷이 16개 넘으면 위 2비트가 bit 6:5
    return 1 << _num(j["lbafs"][idx]["ds"])


def cmd_lbasize(a):
    try:
        print(read_lba_bytes(env("NVME_DEV")))
    except Exception as e:
        # 못 읽으면 config 값을 쓰되, 그 사실을 남겨요
        print(f"[pilot] LBA 크기를 nvme id-ns로 못 읽어 LBA_BYTES={env('LBA_BYTES', int, 512)}를 써요 ({e})",
              file=sys.stderr)
        print(env("LBA_BYTES", int, 512))


RUHT_NAMES = {1: "II", 2: "PI"}


def parse_fdp_configs(blob):
    """FDP 설정 로그(20h)의 첫 설정에서 RUH 종류 목록 (1 = II, 2 = PI).
    머리 16 B 뒤에 설정 기술자: 크기 u16, FDPA u8, VSS u8(벤더 영역 바이트), NRG u32, NRUH u16 …
    기술자 앞 64 B와 벤더 영역 뒤에 RUH마다 4 B(첫 바이트가 RUHT)가 와요."""
    if len(blob) < 16 + 64:
        raise ValueError(f"로그가 {len(blob)} B뿐이에요")
    _size, _fdpa, vss, _nrg, nruh = struct.unpack_from("<HBBIH", blob, 16)
    base = 16 + 64 + vss
    if base + 4 * nruh > len(blob):
        raise ValueError(f"RUH {nruh}개인데 로그가 {len(blob)} B에서 끝나요")
    return [blob[base + 4 * i] for i in range(nruh)]


def read_ruh_types():
    out = subprocess.run(["nvme", "fdp", "configs", env("NVME_DEV"),
                          "-e", str(env("FDP_ENDGRP", int)), "-b"],
                         capture_output=True, check=True).stdout
    return parse_fdp_configs(out)


def cmd_ruhtypes(a):
    for i, t in enumerate(read_ruh_types()):
        print(i, RUHT_NAMES.get(t, f"?{t}"))


def cmd_ruh(a):
    method = env("RUH_METHOD")
    if method in ("none", "femu"):
        return
    if method == "custom":
        sys.stdout.write(subprocess.run(env("RUH_CMD"), shell=True, capture_output=True,
                                        text=True, check=True).stdout)
        return
    out = subprocess.run(["nvme", "fdp", "status", env("NVME_DEV"), "-o", "json"],
                         capture_output=True, text=True, check=True).stdout
    j = json.loads(out)
    rows = []

    def walk(o):
        if isinstance(o, dict):
            keys = {k.lower(): v for k, v in o.items()}
            if "pid" in keys and "ruamw" in keys:
                rows.append((_num(keys["pid"]), _num(keys["ruamw"])))
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for x in o:
                walk(x)
    walk(j)
    for pid, ruamw in rows:
        print(pid, ruamw)


# ---------------- PC 보정 요약 (인구) ----------------

def parse_levelstats(path):
    sizes = {}
    started = False
    for line in open(path, errors="replace"):
        if re.search(r"Level\s+Files\s+Size", line):
            started, sizes = True, {}
            continue
        if started:
            m = re.match(r"\s*(\d+)\s+(\d+)\s+(\d+)\s*$", line)
            if m:
                sizes[int(m.group(1))] = int(m.group(3)) * MiB
            elif sizes and not line.strip().startswith("-"):
                started = False
    return sizes


def parse_cumulative(path):
    """db_bench 통계 출력에서 마지막 누적 compaction 쓰기량과 WAL 쓰기량(GB)을 찾음."""
    comp = wal = None
    for line in open(path, errors="replace"):
        m = re.search(r"Cumulative compaction:\s*([\d.]+)\s*GB write", line)
        if m:
            comp = float(m.group(1)) * 1e9
        m = re.search(r"Cumulative WAL:.*written:\s*([\d.]+)\s*GB", line)
        if m:
            wal = float(m.group(1)) * 1e9
    return comp, wal


def cmd_pcsummary(a):
    rows = list(csv.DictReader(open(os.path.join(a.dir, "du.csv"))))
    logical = float(open(os.path.join(a.dir, "logical_bytes")).read())
    peak = max(int(r["total_bytes"]) for r in rows)
    manifest = max(int(r["manifest_bytes"]) for r in rows)
    lv = parse_levelstats(os.path.join(a.dir, "levelstats.txt"))
    comp, wal = parse_cumulative(os.path.join(a.dir, "db_bench_overwrite.log"))
    print(f"== PC 보정 결과: {a.dir} ==")
    print(f"  논리 데이터      : {logical/GiB:.2f} GiB")
    print(f"  최대 사용량      : {peak/GiB:.2f} GiB")
    print(f"  공간 증폭        : {peak/logical:.3f}   <- config.env 의 SPACE_AMP 에 넣을 값 후보")
    if lv:
        tot = sum(lv.values())
        print("  레벨별 비중      : " + ", ".join(f"L{k} {v/tot*100:.0f}%" for k, v in sorted(lv.items())))
    if comp:
        allw = comp + (wal or 0)
        print(f"  host 쓰기(근사)  : {allw/GiB:.1f} GiB (compaction+flush {comp/GiB:.1f}, WAL {(wal or 0)/GiB:.1f})")
        print(f"  MANIFEST 비중    : {manifest/allw*100:.3f}% (최대 파일 크기 기준 근사)")
    else:
        print("  [참고] 누적 compaction 줄을 못 찾아 MANIFEST 비중은 계산하지 않았어요.")


# ---------------- FEMU 결과 요약 ----------------

def phase_delta(rows, phase, tail_frac=None):
    rs = [r for r in rows if r["phase"] == phase]
    if len(rs) < 2:
        return None
    if tail_frac:
        rs = rs[int(len(rs) * (1 - tail_frac)):] if len(rs) >= 4 else rs
    h = int(rs[-1]["host_bytes"]) - int(rs[0]["host_bytes"])
    m = int(rs[-1]["media_bytes"]) - int(rs[0]["media_bytes"])
    return h, m


def femu_ruh_shares(path):
    """ruh_usage.csv(RUH_METHOD=femu)의 overwrite 구간 처음·끝 차이로 RUH별 (host 비율, media 비율)."""
    if not os.path.exists(path):
        return None
    first, last = {}, {}
    for r in csv.DictReader(open(path)):
        if r["phase"] != "overwrite":
            continue
        k, v = int(r["ruh"]), (int(r["hbmw"]), int(r["mbmw"]))
        first.setdefault(k, v)
        last[k] = v
    dh = {k: last[k][0] - first[k][0] for k in last}
    dm = {k: last[k][1] - first[k][1] for k in last}
    th, tm = sum(dh.values()), sum(dm.values())
    if th <= 0:
        return None
    return {k: (dh[k] / th, dm[k] / tm if tm else 0.0)
            for k in sorted(dh) if dh[k] > 0 or dm[k] > 0}


def util_stats(path):
    """usage.csv(RUH_METHOD=femu)에서 실제 사용률 = 유효 데이터 / 용량: (run 전체 최고, overwrite 뒤 1/3 평균)."""
    if not os.path.exists(path):
        return None
    u = [(r["phase"], int(r["valid_bytes"]) / int(r["capacity_bytes"]))
         for r in csv.DictReader(open(path)) if int(r["capacity_bytes"]) > 0]
    if not u:
        return None
    ow = [x for p, x in u if p == "overwrite"]
    tail = ow[int(len(ow) * 2 / 3):] if len(ow) >= 3 else ow
    return max(x for _, x in u), (sum(tail) / len(tail) if tail else None)


def ruh_shares(path, ru_blocks):
    """ruh.csv(RUH_METHOD=fdpstatus)의 RUAMW 변화로 추정한 RUH별 쓰기 비율 (근사).
    샘플 사이에 RU를 두 개 넘게 쓰면 덜 세요."""
    if not os.path.exists(path):
        return None
    last, acc = {}, {}
    for r in csv.DictReader(open(path)):
        if r["phase"] != "overwrite":
            continue
        pid, v = int(r["pid"]), int(r["value"])
        if pid in last:
            d = last[pid] - v if v <= last[pid] else last[pid] + (ru_blocks - v)
            acc[pid] = acc.get(pid, 0) + max(d, 0)
        last[pid] = v
    tot = sum(acc.values())
    return {p: acc[p] / tot for p in sorted(acc)} if tot else None


RUN_RE = re.compile(r"^(single|lan)_u([\d.]+)(?:_r(\d+))?$")


def run_lba_bytes(d):
    """run 폴더에 남긴 장치 LBA 크기. 없으면 config 의 LBA_BYTES."""
    p = os.path.join(d, "lba_bytes")
    if os.path.exists(p):
        try:
            return int(open(p).read().split()[0])
        except (ValueError, IndexError):
            pass
    return env("LBA_BYTES", int, 512)


def cmd_summary(a):
    ru_bytes = env("RU_MIB", float) * MiB
    min_gain = env("MIN_GAIN_LOW", float, 0.10)
    ratio_cut = env("COLLAPSE_RATIO", float, 0.5)
    band = env("BORDER_BAND", float, 0.1)
    res = []
    for d in sorted(glob.glob(os.path.join(a.results, "*_u*"))):
        cpath = os.path.join(d, "counters.csv")
        name = os.path.basename(d)
        m = RUN_RE.match(name)
        if not m or not os.path.exists(cpath):
            continue
        rows = list(csv.DictReader(open(cpath)))
        policy, util, rep = m.group(1), float(m.group(2)), int(m.group(3) or 1)
        full = phase_delta(rows, "overwrite")
        tail = phase_delta(rows, "overwrite", tail_frac=1 / 3)
        if not full or full[0] <= 0 or not tail or tail[0] <= 0:
            print(f"[건너뜀] {name}: overwrite 구간 카운터가 부족해요")
            continue
        femu = femu_ruh_shares(os.path.join(d, "ruh_usage.csv"))
        res.append({
            "run": name, "policy": policy, "util": util, "rep": rep,
            "host_gib": full[0] / GiB, "media_gib": full[1] / GiB,
            "waf": full[1] / full[0],
            "waf_tail": tail[1] / tail[0],
            # RUAMW 는 LBA 단위라, run마다 장치에서 읽어 둔 LBA 크기로 RU 크기를 LBA 수로 바꿔요
            "ruh": ({p: s[0] for p, s in femu.items()} if femu
                    else ruh_shares(os.path.join(d, "ruh.csv"), int(ru_bytes / run_lba_bytes(d)))),
            "ruh_exact": femu is not None,
            "ruh_media": {p: s[1] for p, s in femu.items()} if femu else None,
            "used": util_stats(os.path.join(d, "usage.csv")),
        })
    if not res:
        sys.exit("[pilot] 요약할 run이 없어요.")

    def pct(x):
        return "-" if x is None else f"{x*100:.1f}%"

    print(f"{'run':<22}{'host GiB':>10}{'media GiB':>11}{'WAF':>7}{'WAF(뒤 1/3)':>13}"
          f"{'사용률 최고':>12}{'뒤 1/3':>8}  RUH별 host 쓰기 비율")
    for r in res:
        ruh = "-" if not r["ruh"] else " ".join(f"{p}:{s*100:.0f}%" for p, s in r["ruh"].items())
        if r["ruh"] and not r["ruh_exact"]:
            ruh += " (RUAMW 근사)"
        peak, used_tail = r["used"] if r["used"] else (None, None)
        print(f"{r['run']:<22}{r['host_gib']:>10.1f}{r['media_gib']:>11.1f}{r['waf']:>7.3f}{r['waf_tail']:>13.3f}"
              f"{pct(peak):>12}{pct(used_tail):>8}  {ruh}")
    if any(r["ruh_media"] for r in res):
        print()
        print("RUH별 media 비율 (그 RUH의 host 쓰기 + 그 RUH가 가진 RU를 GC로 옮긴 양, overwrite 구간)")
        print("  II에서는 다시 옮겨지는 GC 데이터가 마지막 RUH에 잡혀요. 데이터 종류별 GC 비용이 아니에요.")
        for r in res:
            if r["ruh_media"]:
                print(f"  {r['run']:<20}" + " ".join(f"{p}:{s*100:.0f}%" for p, s in r["ruh_media"].items()))
    if not any(r["used"] for r in res):
        print("[참고] 실제 사용률 기록이 없어요 (usage.csv 없음). RUH_METHOD=femu 로 돌리면 남아요.")
    print()

    # 같은 (정책, 사용률)의 반복은 WAF(뒤 1/3)를 평균
    groups = {}
    for r in res:
        groups.setdefault((r["policy"], r["util"]), []).append(r["waf_tail"])
    waf = {k: sum(v) / len(v) for k, v in groups.items()}
    nrep = {k: len(v) for k, v in groups.items()}
    utils = sorted({u for _, u in groups})
    gains = {}
    for u in utils:
        if ("single", u) in waf and ("lan", u) in waf:
            gains[u] = 1 - waf[("lan", u)] / waf[("single", u)]
            n = min(nrep[("single", u)], nrep[("lan", u)])
            print(f"사용률 {u:.2f}: Lan Static이 Single PID보다 Media를 {gains[u]*100:.1f}% 적게 씀"
                  f" (뒤 1/3 기준, 반복 {n}번 평균), Lan Static에 남은 최대 여지"
                  f" 1-1/WAF = {(1-1/waf[('lan', u)])*100:.1f}%")
    # 목표 사용률은 PC 공간 증폭으로 계산한 값이라, 장치에서 실제로 얼마나 찼는지 같이 봐요
    peaks = {}
    for r in res:
        if r["used"]:
            peaks.setdefault(r["util"], []).append((r["run"], r["used"][0]))
    for u in sorted(peaks):
        print(f"  목표 {u*100:.0f}%의 실제 최고 사용률: "
              + ", ".join(f"{name} {x*100:.1f}%" for name, x in peaks[u]))
    if len(gains) < 2:
        print("판정: 사용률 두 개의 single·lan 결과가 다 있어야 판정해요.")
        return
    lo, hi = min(gains), max(gains)
    print()
    if gains[lo] < min_gain:
        print(f"판정 보류: {lo*100:.0f}%에서 이득이 {gains[lo]*100:.1f}%로 최소 기준 {min_gain*100:.0f}%보다 작아요.")
        print("  -> 비율을 볼 수 없어요. FEMU에서 FDP 이득 자체가 작게 나오는 이유(PID가 실제로 나뉘어 도착하는지,")
        print("     OP·RU 크기, 카운터)를 먼저 확인해 주세요.")
    else:
        ratio = gains[hi] / gains[lo]
        print(f"이득 비율 = {hi*100:.0f}% 이득 / {lo*100:.0f}% 이득 = {ratio:.2f}"
              f"  (기준 {ratio_cut:.2f}, 경계 {ratio_cut-band:.2f}~{ratio_cut+band:.2f})")
        hi_reps = min(nrep.get(("single", hi), 0), nrep.get(("lan", hi), 0))
        if abs(ratio - ratio_cut) <= band:
            if hi_reps < 2:
                print(f"판정: 경계예요. {hi*100:.0f}% 두 run을 한 번 더 돌려 주세요:")
                print(f"  REP=2 ./03_host_loop.sh \"single lan\" {hi}")
            else:
                print("판정: 반복해도 여전히 경계예요. 무너짐이 있다고도 없다고도 말하기 어려워요 -> 같이 보고 정하기.")
        elif ratio < ratio_cut:
            print("판정: 높은 사용률에서 FDP 이득이 절반 아래로 줄었어요 -> Lan처럼 무너짐이 FEMU에서도 보임. A 방향의 여지 있음.")
        else:
            print("판정: 높은 사용률에서도 FDP 이득이 크게 줄지 않았어요.")
            print("  -> 공간 증폭·사용률이 의도대로 됐는지 확인하고, 그래도 같으면 zipfian workload로 한 번 더 시도.")
    print("주의: 방향만 보는 결과예요. 숫자를 논문에 그대로 쓰지 마세요.")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    sp.add_parser("calc")
    g = sp.add_parser("get")
    g.add_argument("util")
    g.add_argument("field")
    sp.add_parser("counters")
    sp.add_parser("usage")
    sp.add_parser("ruh")
    sp.add_parser("lbasize")
    sp.add_parser("ruhtypes")
    p = sp.add_parser("pcsummary")
    p.add_argument("dir")
    s = sp.add_parser("summary")
    s.add_argument("results")
    a = ap.parse_args()
    {"calc": cmd_calc, "get": cmd_get, "counters": cmd_counters, "usage": cmd_usage,
     "ruh": cmd_ruh, "lbasize": cmd_lbasize, "ruhtypes": cmd_ruhtypes,
     "pcsummary": cmd_pcsummary,
     "summary": cmd_summary}[a.cmd](a)


if __name__ == "__main__":
    main()
