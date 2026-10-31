#!/usr/bin/env python3
"""장애 재현 시뮬레이터 — 진단 연습용.

⚠️ 이것은 코디세이가 배포하는 agent-app-leak.zip 의 **대역이 아니라 연습 도구**다.
   제출 리포트에 들어갈 증거는 반드시 **실제 제공 바이너리**를 돌려서 얻어야 한다.
   이 파일은 다음 두 가지를 위해 만들었다.
     1) monitor.sh / diagnose.sh 가 세 가지 장애를 제대로 잡아내는지 검증
     2) 실제 바이너리를 받기 전에 '진단하는 법'을 손으로 연습

   과제 PDF 6~8쪽에 적힌 로그 문구와 환경변수 계약을 그대로 따른다.

FAULT_MODE 로 재현할 장애를 고른다:
    leak      메모리를 계속 쌓다가 MEMORY_LIMIT 초과 시 MemoryGuard 가 자진 종료
    cpu       CPU 를 과점유하다가 CPU_MAX_OCCUPY 초과 시 Watchdog 이 SIGTERM
    deadlock  두 스레드가 서로의 락을 기다려 영원히 멈춤 (PID 는 살아 있음)
    normal    워커 스레드들이 번갈아 돌며 정상 동작 (보너스: 스케줄링 추론용)
"""

import os
import socket
import sys
import threading
import time

REQUIRED_ENVS = ("AGENT_HOME", "AGENT_PORT", "AGENT_UPLOAD_DIR",
                 "AGENT_KEY_PATH", "AGENT_LOG_DIR")
EXPECTED_KEY = "agent_api_key_test"


def ts() -> str:
    """밀리초까지 찍는다 — 스케줄링 추론에는 초 단위로는 부족하다."""
    now = time.time()
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now)) + f".{int(now % 1 * 1000):03d}"


def log(message: str) -> None:
    line = f"[{ts()}] {message}"
    print(line, flush=True)
    log_dir = os.environ.get("AGENT_LOG_DIR")
    if log_dir and os.path.isdir(log_dir):
        try:
            with open(os.path.join(log_dir, "app.log"), "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except OSError:
            pass


def env_int(name: str, low: int, high: int):
    """정수 환경변수를 읽고 범위를 검사한다. 과제 3쪽의 부트 조건."""
    raw = os.environ.get(name)
    if raw is None:
        return None, f"{name} is not set"
    try:
        value = int(raw)
    except ValueError:
        return None, f"{name} is not an integer: {raw!r}"
    if not low <= value <= high:
        return None, f"{name} out of range ({low}~{high}): {value}"
    return value, None


def env_bool(name: str, default: bool = True) -> bool:
    raw = (os.environ.get(name) or "").strip().lower()
    if raw in ("true", "1", "yes"):
        return True
    if raw in ("false", "0", "no"):
        return False
    return default


def boot_sequence():
    """부트 시퀀스. 조건이 하나라도 어긋나면 종료한다."""
    log("[BOOT] Starting agent-leak-app (simulator)")

    if os.getuid() == 0:
        log("[FATAL] [Boot] Refusing to run as root.")
        return None

    missing = [n for n in REQUIRED_ENVS if not os.environ.get(n)]
    if missing:
        log(f"[FATAL] [Boot] Missing env: {', '.join(missing)}")
        return None

    mem_limit, err = env_int("MEMORY_LIMIT", 50, 512)
    if err:
        log(f"[FATAL] [Boot] {err}")
        return None
    cpu_max, err = env_int("CPU_MAX_OCCUPY", 10, 100)
    if err:
        log(f"[FATAL] [Boot] {err}")
        return None

    key_dir = os.environ["AGENT_KEY_PATH"]
    key_file = key_dir if os.path.isfile(key_dir) else os.path.join(key_dir, "secret.key")
    try:
        with open(key_file, encoding="utf-8") as f:
            if f.read().strip() != EXPECTED_KEY:
                log("[FATAL] [Boot] secret.key content mismatch")
                return None
    except OSError as exc:
        log(f"[FATAL] [Boot] Cannot read key: {exc}")
        return None

    if not os.path.isdir(os.environ["AGENT_UPLOAD_DIR"]):
        log("[FATAL] [Boot] AGENT_UPLOAD_DIR does not exist")
        return None

    log_dir = os.environ["AGENT_LOG_DIR"]
    if not (os.path.isdir(log_dir) and os.access(log_dir, os.W_OK)):
        log("[FATAL] [Boot] AGENT_LOG_DIR not writable")
        return None

    port = int(os.environ["AGENT_PORT"])
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        server.bind(("0.0.0.0", port))
        server.listen(8)
    except OSError as exc:
        log(f"[FATAL] [Boot] Cannot bind 0.0.0.0:{port}: {exc}")
        return None

    log(f"[BOOT] All checks passed. MEMORY_LIMIT={mem_limit}MB "
        f"CPU_MAX_OCCUPY={cpu_max}% MULTI_THREAD_ENABLE={env_bool('MULTI_THREAD_ENABLE')}")
    log("[BOOT] Agent READY")
    return {"mem_limit": mem_limit, "cpu_max": cpu_max, "server": server,
            "port": port, "pid": os.getpid()}


# ─────────────────────────── 장애 ① 메모리 누수 ───────────────────────────
def run_leak(cfg) -> int:
    """힙에 데이터를 쌓기만 하고 해제하지 않는다 → 전형적인 메모리 누수.

    MemoryGuard: 사용량이 MEMORY_LIMIT 에 닿으면 시스템 전체가 불안정해지기 전에
    자기 자신을 종료한다. 리눅스 커널의 OOM Killer 가 '아무 프로세스나' 고르는
    것보다, 문제를 아는 앱이 스스로 죽는 편이 피해가 적기 때문이다.
    """
    leaked = []          # ← 여기가 누수 지점. 참조를 계속 들고 있어 GC 가 못 치운다
    chunk_mb = 4
    log("[INFO] [Worker] Allocation loop started")

    while True:
        leaked.append(bytearray(chunk_mb * 1024 * 1024))
        used_mb = rss_mb()
        log(f"[INFO] [MemoryGuard] rss={used_mb}MB / limit={cfg['mem_limit']}MB")

        if used_mb >= cfg["mem_limit"]:
            log(f"[CRITICAL] [MemoryGuard] Memory limit exceeded "
                f"({used_mb}MB >= {cfg['mem_limit']}MB) / (Recommend Over {cfg['mem_limit'] * 2}MB)")
            log(f"[CRITICAL] [MemoryGuard] Self-terminating process {cfg['pid']} "
                f"to prevent system instability.")
            log(">>> [SYSTEM] SELF-TERMINATED (Memory Limit Exceeded) <<<")
            return 137
        time.sleep(0.4)


def rss_mb() -> int:
    """실제 물리 메모리 사용량(RSS)을 MB 로. /proc/self/statm 2번째 값 = 페이지 수."""
    try:
        with open("/proc/self/statm", encoding="utf-8") as f:
            pages = int(f.read().split()[1])
        return pages * os.sysconf("SC_PAGE_SIZE") // (1024 * 1024)
    except (OSError, IndexError, ValueError):
        return 0


# ─────────────────────────── 장애 ② CPU 과점유 ───────────────────────────
def run_cpu(cfg) -> int:
    """바쁜 대기(busy-wait)로 CPU 를 태운다.

    Watchdog: 한 프로세스가 CPU 를 과점유하면 같은 서버의 다른 프로세스가
    차례를 못 받아 전체가 느려진다. 임계치를 넘으면 SIGTERM 으로 정리한다.

    ⚠️ 측정이 작업을 방해하면 안 된다 — 처음에 이걸 틀렸다.
       측정 함수 안에서 time.sleep(1) 을 했더니, 그 1초 동안 CPU 를 안 쓰게 되어
       사용률이 절반 이하로 떨어졌고 Watchdog 이 영영 안 터졌다.
       그래서 **잠들지 않고** 누적 틱의 증가분만 보도록 바꿨다.
       (관찰 행위가 관찰 대상을 바꾸면 안 된다)
    """
    log("[INFO] [Worker] CPU-bound loop started")
    hz = os.sysconf("SC_CLK_TCK")
    started = time.time()
    last_t, last_c = started, cpu_ticks()

    # 부하를 서서히 올린다(0% → 100%, 약 40초에 걸쳐).
    #
    # 처음엔 곧바로 100% 를 태웠는데, 그러면 임계값을 20 으로 하든 90 으로 하든
    # 첫 점검에서 바로 걸려서 **Before/After 비교가 무의미**했다.
    # 실제 서비스의 CPU 급상승도 보통 트래픽이 늘면서 점진적으로 일어나므로,
    # 램프업을 넣는 쪽이 현실적이고 임계값의 의미도 드러난다.
    RAMP_SECONDS = 40

    while True:
        elapsed_total = time.time() - started
        duty = min(1.0, 0.05 + elapsed_total / RAMP_SECONDS)   # 목표 점유율

        # duty 만큼만 일하고 나머지는 쉰다 → 평균 CPU 사용률이 duty 에 수렴한다
        slice_start = time.time()
        while time.time() - slice_start < 0.2 * duty:
            _ = sum(i * i for i in range(20_000))
        idle = 0.2 * (1 - duty)
        if idle > 0:
            time.sleep(idle)

        now, cur_c = time.time(), cpu_ticks()
        elapsed = now - last_t
        if elapsed >= 2:
            usage = round((cur_c - last_c) / hz / elapsed * 100, 1)
            log(f"[INFO] [Watchdog] cpu={usage}% / max={cfg['cpu_max']}%")
            if usage >= cfg["cpu_max"]:
                log(f"[CRITICAL] [Watchdog] CPU occupancy exceeded "
                    f"({usage}% >= {cfg['cpu_max']}%)")
                log(">>> [SYSTEM] WATCHDOG: INITIATING EMERGENCY ABORT (SIGTERM) <<<")
                return 143
            last_t, last_c = now, cur_c


def cpu_ticks() -> int:
    """이 프로세스가 지금까지 쓴 CPU 시간(클럭 틱). utime + stime.

    /proc/self/stat 의 14·15번째 필드다. 2번째 필드(실행 파일명)에 공백이
    들어갈 수 있어서, 닫는 괄호 뒤부터 세는 것이 안전하다.
    """
    try:
        with open("/proc/self/stat", encoding="utf-8") as f:
            rest = f.read().rsplit(") ", 1)[1].split()
        return int(rest[11]) + int(rest[12])   # utime, stime
    except (OSError, IndexError, ValueError):
        return 0


# ─────────────────────────── 장애 ③ 교착상태 ───────────────────────────
def run_deadlock(cfg) -> int:
    """고전적인 교착상태를 만든다.

    Thread-A: lock1 잡고 → lock2 기다림
    Thread-B: lock2 잡고 → lock1 기다림
    서로 상대가 가진 것을 기다리므로 영원히 풀리지 않는다.

    교착상태 4대 조건이 모두 성립한다:
      상호 배제   한 락은 한 스레드만 가질 수 있다
      점유 대기   이미 하나를 쥔 채로 다른 하나를 기다린다
      비선점     남이 쥔 락을 강제로 뺏을 수 없다
      순환 대기   A→B→A 로 대기가 고리를 이룬다
    """
    if not env_bool("MULTI_THREAD_ENABLE", True):
        log("[INFO] [Scheduler] MULTI_THREAD_ENABLE=false → 단일 스레드 모드")
        log("[INFO] [Worker] Sequential processing (no lock contention)")
        for i in range(1, 11):
            log(f"[INFO] [Thread-Main] Task {i}/10 completed")
            time.sleep(1)
        log("[INFO] [Worker] All tasks completed normally. Exiting.")
        return 0

    lock1 = threading.Lock()
    lock2 = threading.Lock()

    def worker(name, first, second, first_name, second_name):
        log(f"[INFO] [{name}] Acquiring {first_name}...")
        first.acquire()
        log(f"[INFO] [{name}] Acquired {first_name}. Working...")
        time.sleep(1)       # 상대가 자기 락을 잡을 시간을 준다
        log(f"[WARN] [{name}] WAITING for {second_name}... BLOCKED")
        second.acquire()    # ← 여기서 영원히 멈춘다
        log(f"[INFO] [{name}] Acquired {second_name}")  # 절대 도달하지 않음
        second.release()
        first.release()

    log("[INFO] [Scheduler] MULTI_THREAD_ENABLE=true → 멀티 스레드 모드")
    a = threading.Thread(target=worker, args=("Thread-A", lock1, lock2, "lock1", "lock2"))
    b = threading.Thread(target=worker, args=("Thread-B", lock2, lock1, "lock2", "lock1"))
    a.start(); b.start()
    a.join(); b.join()      # 영원히 돌아오지 않는다
    return 0


# ─────────────────────────── 정상 동작 (보너스용) ───────────────────────────
def run_normal(cfg) -> int:
    """워커 스레드 3개가 조금씩 번갈아 진행한다.

    보너스 과제(스케줄링 알고리즘 추론)의 관찰 대상이다.
    한 작업이 끝나기 전에 다른 작업이 끼어드는 로그가 남는다.
    """
    log("[INFO] [Scheduler] Starting 3 worker threads")

    def worker(name):
        for progress in range(10, 101, 10):
            log(f"[{name}] Calculating... ({progress}%)")
            time.sleep(0.05)
        log(f"[{name}] Task completed.")

    threads = [threading.Thread(target=worker, args=(f"Thread-{c}",)) for c in "ABC"]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    log("[INFO] [Scheduler] All workers finished.")
    return 0


MODES = {"leak": run_leak, "cpu": run_cpu, "deadlock": run_deadlock, "normal": run_normal}


def main() -> int:
    mode = (os.environ.get("FAULT_MODE") or "normal").strip().lower()
    if mode not in MODES:
        print(f"FAULT_MODE must be one of: {', '.join(MODES)}", file=sys.stderr)
        return 2
    cfg = boot_sequence()
    if cfg is None:
        return 1
    log(f"[INFO] [Main] FAULT_MODE={mode} pid={cfg['pid']}")
    try:
        return MODES[mode](cfg)
    except KeyboardInterrupt:
        log("[INFO] [Main] Interrupted by user.")
        return 0
    finally:
        cfg["server"].close()


if __name__ == "__main__":
    sys.exit(main())
