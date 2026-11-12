#!/usr/bin/python3
"""Privileged macOS supervisor for the experimental SFERA IPv4 test tunnel."""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import ipaddress
import json
import os
import pwd
import re
import secrets
import shlex
import signal
import stat
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any, Optional, Tuple

SERVER_IP = "192.0.2.1"
SIGNAL_TOKEN_NAME = "signaling.token"
HEARTBEAT_TIMEOUT = 20
START_TIMEOUT = 35
SPLIT_ROUTES = ("0.0.0.0/1", "128.0.0.0/1")
DNS_SERVERS = ("1.1.1.1", "9.9.9.9")
RUN_ROOT = Path("/var/run")
STOP_EVENT = threading.Event()


class HelperError(RuntimeError):
    pass


def run(argv: list[str], *, timeout: float = 10, check: bool = True) -> subprocess.CompletedProcess[str]:
    """Run a fixed system command without a shell and return decoded output."""
    try:
        result = subprocess.run(argv, text=True, capture_output=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise HelperError(f"Could not run {argv[0]}: {exc}") from exc
    if check and result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise HelperError(f"{Path(argv[0]).name} failed ({result.returncode}): {detail or 'no details'}")
    return result


def atomic_json(path: Path, value: dict[str, Any], mode: int = 0o600,
                expected_dir_uid: Optional[int] = None,
                expected_dir_identity: Optional[Tuple[int, int]] = None) -> None:
    directory_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) |
                           getattr(os, "O_NOFOLLOW", 0))
    temporary: Optional[str] = None
    created = False
    try:
        directory_stat = os.fstat(directory_fd)
        if expected_dir_uid is not None and directory_stat.st_uid != expected_dir_uid:
            raise HelperError(f"Unsafe status directory ownership: {path.parent}")
        if expected_dir_identity and (directory_stat.st_dev, directory_stat.st_ino) != expected_dir_identity:
            raise HelperError(f"Status directory changed while preparing a write: {path.parent}")
        temporary = f".sfera-{secrets.token_hex(12)}"
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
                     mode, dir_fd=directory_fd)
        created = True
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path.name, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
    finally:
        if created and temporary is not None:
            try:
                os.unlink(temporary, dir_fd=directory_fd)
            except FileNotFoundError:
                pass
        os.close(directory_fd)


def read_json(path: Path) -> Optional[dict[str, Any]]:
    fd = -1
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0))
        metadata = os.fstat(fd)
        if not stat.S_ISREG(metadata.st_mode):
            os.close(fd)
            return None
        with os.fdopen(fd, "r", encoding="utf-8") as stream:
            fd = -1
            value = json.load(stream)
        return value if isinstance(value, dict) else None
    except (OSError, ValueError, json.JSONDecodeError):
        return None
    finally:
        if fd >= 0:
            os.close(fd)


def state_dir(uid: int) -> Path:
    return RUN_ROOT / f"sfera-test-{uid}"


def ensure_root_state_dir(uid: int) -> Path:
    if os.geteuid() != 0:
        raise HelperError("This operation requires administrator privileges.")
    path = state_dir(uid)
    try:
        path.mkdir(mode=0o700)
    except FileExistsError:
        pass
    metadata = path.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise HelperError(f"Unsafe supervisor state path: {path}")
    if metadata.st_uid != 0 or stat.S_IMODE(metadata.st_mode) & 0o077:
        raise HelperError(f"Supervisor state must be root-owned mode 0700: {path}")
    return path


def account_paths(uid: int, home_arg: str, resources_arg: str) -> tuple[pwd.struct_passwd, Path, Path]:
    try:
        account = pwd.getpwuid(uid)
    except KeyError as exc:
        raise HelperError(f"No local account has uid {uid}.") from exc
    home = Path(home_arg).resolve(strict=True)
    expected_home = Path(account.pw_dir).resolve(strict=True)
    if home != expected_home:
        raise HelperError("The supplied home directory does not belong to the selected account.")
    if not Path(resources_arg).is_absolute():
        raise HelperError("The application resource path must be absolute.")
    resources = Path(resources_arg).resolve(strict=True)
    if not resources.is_dir():
        raise HelperError("The application resource path is not a directory.")
    support = home / "Library" / "Application Support" / "SFERA Test"
    runtime = support / "runtime"
    for directory in (support, runtime):
        ensure_user_directory(directory, uid)
    return account, resources, support


def ensure_user_directory(path: Path, uid: int) -> None:
    try:
        metadata = path.lstat()
    except FileNotFoundError as exc:
        raise HelperError(f"Missing user-owned directory: {path}") from exc
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise HelperError(f"Expected a real directory: {path}")
    if metadata.st_uid != uid or stat.S_IMODE(metadata.st_mode) & 0o077:
        raise HelperError(f"Directory must be owned by uid {uid} with mode 0700: {path}")


def read_signaling_token(support: Path, account: pwd.struct_passwd) -> bytes:
    path = support / SIGNAL_TOKEN_NAME
    try:
        with as_user(account):
            directory_fd = os.open(support, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                directory = os.fstat(directory_fd)
                if directory.st_uid != account.pw_uid or stat.S_IMODE(directory.st_mode) != 0o700:
                    raise HelperError(f"Signaling token directory must be owned by uid {account.pw_uid} with mode 0700: {support}")
                fd = os.open(path.name, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW,
                             dir_fd=directory_fd)
                with os.fdopen(fd, "rb") as stream:
                    metadata = os.fstat(stream.fileno())
                    if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != account.pw_uid or
                            stat.S_IMODE(metadata.st_mode) != 0o600):
                        raise HelperError(f"Signaling token must be a regular file owned by uid {account.pw_uid} with mode 0600: {path}")
                    token = stream.read(66)
            finally:
                os.close(directory_fd)
    except FileNotFoundError as exc:
        raise HelperError(f"Signaling token is missing: {path}") from exc
    except OSError as exc:
        raise HelperError(f"Could not safely open the signaling token: {path}") from exc
    if not re.fullmatch(rb"[0-9a-f]{64}\n?", token):
        raise HelperError(f"Signaling token must contain one line of 64 lowercase hexadecimal digits: {path}")
    return token


def private_peer(address: ipaddress.IPv4Address) -> bool:
    first, second, _, _ = address.packed
    return first == 10 or (first == 172 and 16 <= second <= 31) or (first == 192 and second == 168)


def read_profile() -> dict[str, Any]:
    data = sys.stdin.buffer.read(4097)
    try:
        if not data or len(data) > 4096:
            raise ValueError
        profile = json.loads(data)
        host = ipaddress.IPv4Address(profile["host"])
        peer = ipaddress.IPv4Address(profile["peerIP"])
        token = profile["token"]
        if (profile["version"] != 1 or not host.is_global or host.is_multicast or
                not private_peer(peer) or int(peer) & 3 != 2 or
                not re.fullmatch(r"[0-9a-f]{64}", token)):
            raise ValueError
        requested = profile.get("directIPv4", [])
        if not isinstance(requested, list) or len(requested) > 96:
            raise ValueError
        direct = set()
        for item in requested:
            if not isinstance(item, str):
                raise ValueError
            address = ipaddress.IPv4Address(item)
            if not address.is_global or address.is_multicast or address.is_reserved or item in ("1.1.1.1", "9.9.9.9"):
                raise ValueError
            if address != host:
                direct.add(str(address))
        result = {"host": str(host), "peerIP": str(peer), "token": token, "version": 1}
        if direct:
            result["directIPv4"] = sorted(direct)
        return result
    except (TypeError, KeyError, ValueError, AttributeError):
        raise HelperError("Invalid SFERA connection profile.") from None


def publish_gui(runtime: Path, state: str, **fields: Any) -> None:
    payload: dict[str, Any] = {"state": state, "updated_at": int(time.time())}
    payload.update(fields)
    account = pwd.getpwuid(int(payload["user_uid"]))
    with as_user(account):
        metadata = runtime.lstat()
        atomic_json(runtime / "status.json", payload, mode=0o644,
                    expected_dir_uid=account.pw_uid,
                    expected_dir_identity=(metadata.st_dev, metadata.st_ino))
    state_dir(int(payload["user_uid"]))
    private_status = state_dir(int(payload["user_uid"])) / "status.json"
    atomic_json(private_status, payload, mode=0o600)


@contextlib.contextmanager
def as_user(account: pwd.struct_passwd):
    old_euid, old_egid = os.geteuid(), os.getegid()
    os.setegid(account.pw_gid)
    os.seteuid(account.pw_uid)
    try:
        yield
    finally:
        os.seteuid(old_euid)
        os.setegid(old_egid)


def open_root_log(path: Path) -> int:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0), 0o600)
    metadata = os.fstat(fd)
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0:
        os.close(fd)
        raise HelperError(f"Unsafe supervisor log file: {path}")
    os.fchmod(fd, 0o600)
    return fd


def process_command(pid: int) -> Optional[str]:
    result = run(["/bin/ps", "-ww", "-p", str(pid), "-o", "command="], check=False)
    return result.stdout.strip() if result.returncode == 0 and result.stdout.strip() else None


def process_start_token(pid: int) -> Optional[str]:
    result = run(["/bin/ps", "-p", str(pid), "-o", "lstart="], check=False)
    return result.stdout.strip() if result.returncode == 0 and result.stdout.strip() else None


def terminate_recorded_children(record: dict[str, Any]) -> list[str]:
    failures: list[str] = []
    for child in reversed(record.get("children") or []):
        pid = int(child.get("pid", 0))
        current_command = process_command(pid)
        current_start = process_start_token(pid)
        if current_command is None:
            continue
        if current_start != child.get("start_token") or not process_matches_record(current_command, child):
            failures.append(f"refused to signal PID {pid}: process identity changed")
            continue
        run(["/bin/kill", "-TERM", str(pid)], check=False)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and process_command(pid) is not None:
            time.sleep(0.1)
        if process_command(pid) is not None:
            if (process_start_token(pid) == child.get("start_token") and
                    process_matches_record(process_command(pid) or "", child)):
                run(["/bin/kill", "-KILL", str(pid)], check=False)
                second_deadline = time.monotonic() + 2
                while time.monotonic() < second_deadline and process_command(pid) is not None:
                    time.sleep(0.1)
                if process_command(pid) is not None:
                    failures.append(f"owned child PID {pid} did not exit after SIGKILL")
            else:
                failures.append(f"refused to kill PID {pid}: process identity changed")
    return failures


def process_matches_record(command: str, record: dict[str, Any]) -> bool:
    if "command_line" in record:
        return command == record["command_line"]
    try:
        argv = shlex.split(command)
    except ValueError:
        return False
    if not argv or argv[0] != record.get("executable"):
        return False
    if argv[1:1 + len(record.get("argv_prefix", []))] != record.get("argv_prefix", []):
        return False
    return all(token in argv for token in record.get("argv_contains", []))


def owned_supervisor(pid: int, uid: int, start_token: Optional[str] = None) -> bool:
    if pid <= 1:
        return False
    command = process_command(pid)
    if not command:
        return False
    if start_token and process_start_token(pid) != start_token:
        return False
    return "root-helper.py" in command and "supervise" in command and f"--user-uid {uid}" in command


def request_stop(runtime: Path, uid: int) -> None:
    runtime_fd = os.open(runtime, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) |
                         getattr(os, "O_NOFOLLOW", 0))
    try:
        fd = os.open("stop.request", os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                     getattr(os, "O_NOFOLLOW", 0), 0o600, dir_fd=runtime_fd)
        try:
            os.write(fd, b"stop\n")
            os.fsync(fd)
            os.fchown(fd, uid, -1)
        finally:
            os.close(fd)
    except FileExistsError:
        metadata = os.stat("stop.request", dir_fd=runtime_fd, follow_symlinks=False)
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != uid:
            raise HelperError("Unsafe existing stop request marker.")
    finally:
        os.close(runtime_fd)


def remove_stale_stop_request(runtime: Path, uid: int) -> None:
    runtime_fd = os.open(runtime, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) |
                         getattr(os, "O_NOFOLLOW", 0))
    try:
        try:
            metadata = os.stat("stop.request", dir_fd=runtime_fd, follow_symlinks=False)
        except FileNotFoundError:
            return
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != uid:
            raise HelperError("Unsafe stale stop request marker.")
        os.unlink("stop.request", dir_fd=runtime_fd)
    finally:
        os.close(runtime_fd)


def recover_stale_session(record: dict[str, Any], runtime: Path) -> list[str]:
    mutations = record.get("mutations") or {}
    errors: list[str] = terminate_recorded_children(record)
    routes = mutations.get("routes") or {}
    for entry in reversed(routes.get("splits") or []):
        if entry.get("attempted"):
            try:
                remove_split_route_entry(entry)
            except Exception as exc:
                errors.append(f"restore route {entry.get('cidr')}: {exc}")
    errors.extend(restore_network_services(mutations))
    errors.extend(restore_host_routes(routes))
    if errors:
        state_path = state_dir(int(record.get("uid", 0))) / "session.json"
        preserved = dict(record)
        preserved["rollback_errors"] = errors
        preserved["recovery_attempted_at"] = int(time.time())
        atomic_json(state_path, preserved)
    return errors


def remove_split_route_entry(entry: dict[str, Any]) -> None:
    routes = parse_netstat_routes(run(["/usr/sbin/netstat", "-rn", "-f", "inet"]).stdout)
    route = routes.get(entry["cidr"])
    if route and route.get("interface") == entry.get("interface"):
        run(["/sbin/route", "-n", "delete", "-net", entry["cidr"]])


def restore_host_routes(routes: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    for entry in [*routes.get("direct", []), routes.get("host")]:
        if entry and entry.get("attempted") and not entry.get("existing"):
            try:
                remove_host_route(entry)
            except Exception as exc:
                errors.append(f"restore host route {entry.get('cidr')}: {exc}")
    return errors


def remove_host_route(entry: dict[str, Any]) -> None:
    routes = parse_netstat_routes(run(["/usr/sbin/netstat", "-rn", "-f", "inet"]).stdout,
                                 unscoped_only=True)
    cidr = ipaddress.IPv4Network(entry["cidr"])
    route = routes.get(str(cidr))
    if route and host_route_matches(entry, route):
        run(["/sbin/route", "-n", "delete", "-host", str(cidr.network_address)])


def host_route_matches(entry: dict[str, Any], route: dict[str, str]) -> bool:
    return any(route["gateway"] == path.get("gateway") and route["interface"] == path.get("interface")
               for path in (entry, entry.get("previous") or {}))


def restore_network_services(mutations: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    active = mutations.get("network")
    services = ([active] if active else []) + list(reversed(mutations.get("previous_networks") or []))
    for network in services:
        for key, label, restore in (("dns_attempted", "DNS", restore_dns),
                                    ("ipv6_attempted", "IPv6", restore_ipv6)):
            if network.get(key):
                try:
                    restore(network)
                except Exception as exc:
                    errors.append(f"restore {label} on {network.get('service')}: {exc}")
    return errors


def restore_dns(network: dict[str, Any]) -> None:
    args = ["/usr/sbin/networksetup", "-setdnsservers", network["service"]]
    args += network["dns"] or ["Empty"]
    run(args)


def restore_ipv6(network: dict[str, Any]) -> None:
    mode = network["ipv6_mode"]
    flag = {"Automatic": "-setv6automatic", "Off": "-setv6off", "Link-local only": "-setv6linklocal"}.get(mode)
    if not flag:
        raise HelperError(f"Cannot restore unsupported IPv6 mode: {mode}")
    run(["/usr/sbin/networksetup", flag, network["service"]])


def command_start(args: argparse.Namespace) -> int:
    uid = args.user_uid
    if os.geteuid() != 0:
        raise HelperError("Connect must be authorized by macOS administrator authentication.")
    profile = read_profile() if args.profile else None
    account, resources, support = account_paths(uid, args.user_home, args.resources)
    runtime = support / "runtime"
    root_state = ensure_root_state_dir(uid)
    lock_path = root_state / "lock"
    lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
    active_pid: Optional[int] = None
    child: Optional[subprocess.Popen] = None
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        record_path = root_state / "session.json"
        record = read_json(record_path)
        pid = int(record.get("pid", 0)) if record else 0
        if owned_supervisor(pid, uid, record.get("start_token") if record else None):
            active_pid = pid
        else:
            if record and record.get("mutations"):
                recovery_errors = recover_stale_session(record, runtime)
                if recovery_errors:
                    error = "Previous session needs manual network recovery: " + "; ".join(recovery_errors)
                    publish_gui(runtime, "error", error=error, user_uid=uid)
                    raise HelperError(error)
                record_path.unlink(missing_ok=True)

            (root_state / SIGNAL_TOKEN_NAME).unlink(missing_ok=True)
            if profile is None:
                read_signaling_token(support, account)
            with as_user(account):
                remove_stale_stop_request(runtime, uid)
            publish_gui(runtime, "starting", user_uid=uid)

            helper = Path(__file__).resolve(strict=True)
            child_args = [sys.executable, "-I", "-B", str(helper), "supervise", "--user-home", str(account.pw_dir),
                          "--user-uid", str(uid), "--resources", str(resources)]
            if profile is not None:
                child_args.append("--profile")
            child = subprocess.Popen(child_args, stdin=subprocess.PIPE if profile is not None else subprocess.DEVNULL,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                      start_new_session=True, close_fds=True)
            if child.stdin is not None:
                with child.stdin:
                    child.stdin.write(json.dumps(profile).encode())
            atomic_json(record_path, {"pid": child.pid, "uid": uid,
                                      "start_token": process_start_token(child.pid),
                                      "started_at": int(time.time())})
    finally:
        os.close(lock_fd)
    pid = active_pid if active_pid is not None else child.pid
    record = read_json(root_state / "session.json") or {}
    return wait_for_start(root_state, runtime, pid, uid, record.get("start_token"))


def wait_for_start(root_state: Path, runtime: Path, pid: int, uid: int,
                   start_token: Optional[str] = None) -> int:
    deadline = time.monotonic() + START_TIMEOUT
    while time.monotonic() < deadline:
        state = read_json(root_state / "status.json") or {}
        current = state.get("state")
        if current == "connected":
            return 0
        if current == "error":
            raise HelperError(str(state.get("error", "SFERA connection failed.")))
        if not owned_supervisor(pid, uid, start_token) and current not in {"starting", "connecting"}:
            break
        time.sleep(0.25)
    request = runtime / "stop.request"
    try:
        with as_user(pwd.getpwuid(uid)):
            request_stop(runtime, uid)
    except (OSError, HelperError):
        pass
    raise HelperError("SFERA did not reach connected state within 35 seconds.")


def command_stop(args: argparse.Namespace) -> int:
    uid = args.user_uid
    if os.geteuid() != uid:
        raise HelperError("Disconnect must be requested by the signed-in account.")
    account, _resources, support = account_paths(uid, args.user_home, args.resources)
    runtime = support / "runtime"
    request_stop(runtime, uid)
    return 0


def command_supervise(args: argparse.Namespace) -> int:
    uid = args.user_uid
    if os.geteuid() != 0:
        raise HelperError("Supervisor must run as root.")
    profile = read_profile() if args.profile else None
    account, resources, support = account_paths(uid, args.user_home, args.resources)
    runtime = support / "runtime"
    root_state = ensure_root_state_dir(uid)
    supervisor = Supervisor(uid, account, resources, support, runtime, root_state, profile)
    return supervisor.run()


class Supervisor:
    def __init__(self, uid: int, account: pwd.struct_passwd, resources: Path,
                 support: Path, runtime: Path, root_state: Path, profile: Optional[dict] = None):
        self.uid = uid
        self.account = account
        self.resources = resources
        self.support = support
        self.runtime = runtime
        self.root_state = root_state
        self.profile = profile
        self.server_ip = profile["host"] if profile else SERVER_IP
        self.tun_ip = profile["peerIP"] if profile else "10.203.0.2"
        self.gateway_ip = str(ipaddress.IPv4Address(int(ipaddress.IPv4Address(self.tun_ip)) - 1))
        self.children: list[subprocess.Popen[bytes]] = []
        self.child_records: list[dict[str, Any]] = []
        self.mutations: dict[str, Any] = {}
        self.interface: Optional[str] = None
        self.original_gateway: Optional[str] = None
        self.original_interface: Optional[str] = None
        self.network_service: Optional[str] = None
        self.status_fields: dict[str, Any] = {}
        self.backend: Optional[subprocess.Popen] = None
        self.initial_utuns: list[str] = []

    def run(self) -> int:
        os.umask(0o077)
        STOP_EVENT.clear()
        signal.signal(signal.SIGTERM, lambda _signum, _frame: STOP_EVENT.set())
        signal.signal(signal.SIGINT, lambda _signum, _frame: STOP_EVENT.set())
        failure: Optional[str] = None
        try:
            # macOS authorization can leave these signals blocked across exec.
            signal.pthread_sigmask(signal.SIG_UNBLOCK, (signal.SIGTERM, signal.SIGINT))
            lock_fd = os.open(self.root_state / "lock", os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_EX)
                record = read_json(self.root_state / "session.json") or {}
                if record.get("pid") != os.getpid():
                    raise HelperError("Supervisor start record did not match this process.")
                self.checkpoint()
            finally:
                os.close(lock_fd)
            publish_gui(self.runtime, "starting", user_uid=self.uid)
            self.establish_tunnel()
            publish_gui(self.runtime, "connected", **self.status_fields, user_uid=self.uid)
            next_route_check = time.monotonic()
            while not STOP_EVENT.wait(0.5):
                if (self.runtime / "stop.request").exists():
                    break
                heartbeat = self.runtime / "heartbeat"
                try:
                    heartbeat_meta = heartbeat.lstat()
                    if stat.S_ISLNK(heartbeat_meta.st_mode) or not stat.S_ISREG(heartbeat_meta.st_mode) or heartbeat_meta.st_uid != self.uid:
                        raise HelperError("Unsafe heartbeat file.")
                    if time.time() - heartbeat_meta.st_mtime > HEARTBEAT_TIMEOUT:
                        break
                except FileNotFoundError:
                    if time.time() - getattr(self, "connected_at", time.time()) > HEARTBEAT_TIMEOUT:
                        break
                if any(child.poll() is not None for child in self.children):
                    raise HelperError("A SFERA tunnel process exited unexpectedly.")
                now = time.monotonic()
                if now >= next_route_check:
                    next_route_check = now + 1
                    self.refresh_underlay()
                latest = self.read_transport()
                self.status_fields = self.transport_status_fields(latest)
                state = "connecting" if latest.get("state") == "connecting" else "connected"
                publish_gui(self.runtime, state, **self.status_fields, user_uid=self.uid)
            publish_gui(self.runtime, "stopping", **self.status_fields, user_uid=self.uid)
        except Exception as exc:
            failure = str(exc)

        cleanup_errors = self.cleanup()
        if cleanup_errors:
            failure = "; ".join(([failure] if failure else []) + cleanup_errors)
        try:
            if failure:
                publish_gui(self.runtime, "error", error=failure, **self.status_fields, user_uid=self.uid)
            else:
                publish_gui(self.runtime, "disconnected", user_uid=self.uid)
        except Exception:
            pass
        try:
            with as_user(self.account):
                remove_stale_stop_request(self.runtime, self.uid)
        except Exception:
            pass
        try:
            record = read_json(self.root_state / "session.json") or {}
            if record.get("pid") == os.getpid():
                if cleanup_errors:
                    record["rollback_errors"] = cleanup_errors
                    record["failed_at"] = int(time.time())
                    atomic_json(self.root_state / "session.json", record)
                else:
                    (self.root_state / "session.json").unlink(missing_ok=True)
        except OSError:
            pass
        return 1 if failure else 0

    def establish_tunnel(self) -> None:
        self.capture_default_network()
        self.capture_ipv6_and_dns()
        self.ensure_no_route_conflicts()
        routes = self.mutations["routes"]
        self.pin_host_route(routes["host"])
        for entry in routes["direct"]:
            self.pin_host_route(entry)
        self.disable_ipv6()
        self.configure_dns()
        self.initial_utuns = list_utun_interfaces()
        self.launch_backend()
        self.wait_backend_and_interface()
        self.install_split_routes()

    def capture_default_network(self) -> None:
        details = run(["/sbin/route", "-n", "get", "default"]).stdout
        values = parse_route_get(details)
        self.original_gateway = values.get("gateway")
        self.original_interface = values.get("interface")
        if not self.original_gateway or not self.original_interface:
            raise HelperError("Could not identify the active IPv4 default gateway and interface.")
        if self.original_interface.startswith("utun"):
            raise HelperError("An existing VPN owns the default route; refusing to replace it.")
        self.network_service = service_for_interface(self.original_interface)
        if not self.network_service:
            raise HelperError(f"No active macOS network service maps to {self.original_interface}.")

    def capture_ipv6_and_dns(self) -> None:
        assert self.network_service
        self.mutations["network"] = self.snapshot_network_service(self.network_service)
        self.checkpoint()

    @staticmethod
    def snapshot_network_service(service: str) -> dict[str, Any]:
        info = run(["/usr/sbin/networksetup", "-getinfo", service]).stdout
        match = re.search(r"^IPv6:\s*(.+)$", info, re.MULTILINE)
        if not match:
            raise HelperError("Could not read the active service's IPv6 mode.")
        mode = match.group(1).strip()
        if mode not in {"Automatic", "Off", "Link-local only"}:
            raise HelperError(f"IPv6 mode '{mode}' cannot be restored safely; refusing to connect.")
        dns_output = run(["/usr/sbin/networksetup", "-getdnsservers", service]).stdout.strip()
        dns_lower = dns_output.lower()
        if "aren't any dns servers" in dns_lower or "no dns servers" in dns_lower:
            dns: list[str] = []
        else:
            dns = [line.strip() for line in dns_output.splitlines() if line.strip()]
            for server in dns:
                try:
                    ipaddress.ip_address(server)
                except ValueError as exc:
                    raise HelperError(f"Unexpected DNS server value: {server}") from exc
        return {
            "service": service, "ipv6_mode": mode, "dns": dns,
            "ipv6_attempted": False, "dns_attempted": False,
        }

    def refresh_underlay(self) -> None:
        routes = self.mutations["routes"]
        host = routes["host"]
        direct = routes.get("direct", [])
        if host["existing"] and not direct:
            return
        table = run(["/usr/sbin/netstat", "-rn", "-f", "inet"]).stdout
        path = primary_ipv4_path(table)
        if path is None:
            return
        if any(not all(entry.get(key) == value for key, value in path.items()) for entry in direct):
            # Keep the VPN during handoff. A manual reconnect resolves exclusions on the new network.
            errors = restore_host_routes({"direct": direct})
            if errors:
                raise HelperError("; ".join(errors))
            routes["direct"] = []
            self.checkpoint()
        if host["existing"]:
            return
        current = parse_netstat_routes(table, unscoped_only=True).get(host["cidr"])
        if current == path and all(host.get(key) == value for key, value in path.items()):
            if "previous" in host:
                host.pop("previous")
                self.checkpoint()
            return
        if current is not None and not host_route_matches(host, current):
            return
        service = service_for_interface(path["interface"])
        if not service:
            return
        active = self.mutations["network"]
        if service != active["service"]:
            previous = self.mutations.setdefault("previous_networks", [])
            snapshot = next((item for item in previous if item["service"] == service), None)
            if snapshot is None:
                snapshot = self.snapshot_network_service(service)
            else:
                previous.remove(snapshot)
            previous.append(active)
            self.mutations["network"] = snapshot
            self.checkpoint()
        self.disable_ipv6()
        self.configure_dns()
        table = run(["/usr/sbin/netstat", "-rn", "-f", "inet"]).stdout
        if primary_ipv4_path(table) != path:
            return
        current = parse_netstat_routes(table, unscoped_only=True).get(host["cidr"])
        if current is not None and not host_route_matches(host, current):
            return
        # Persist both possible route identities before the kernel operation.
        # Cleanup can then recover either side of an interrupted transition.
        host.update(path, previous=current, attempted=True)
        self.checkpoint()
        action = "add" if current is None else "change"
        result = run(["/sbin/route", "-n", action, "-host", self.server_ip,
                      path["gateway"], "-ifp", path["interface"]], check=False)
        if result.returncode == 0:
            updated = run(["/usr/sbin/netstat", "-rn", "-f", "inet"]).stdout
            if parse_netstat_routes(updated, unscoped_only=True).get(host["cidr"]) == path:
                host.pop("previous", None)
                self.checkpoint()

    def ensure_no_route_conflicts(self) -> None:
        table = run(["/usr/sbin/netstat", "-rn", "-f", "inet"]).stdout
        routes = parse_netstat_routes(table)
        for cidr in SPLIT_ROUTES:
            if cidr in routes:
                raise HelperError(f"Route {cidr} already exists; refusing to overwrite it.")
        server = f"{self.server_ip}/32"
        current = parse_netstat_routes(table, unscoped_only=True)

        def host_entry(cidr: str) -> dict[str, Any]:
            existing = current.get(cidr)
            if existing and (existing.get("gateway") != self.original_gateway or
                             existing.get("interface") != self.original_interface):
                raise HelperError(f"Host route {cidr} already exists through another gateway.")
            return {"cidr": cidr, "gateway": self.original_gateway,
                    "interface": self.original_interface, "existing": bool(existing), "attempted": False}

        self.mutations["routes"] = {
            "host": host_entry(server),
            "direct": [host_entry(f"{address}/32") for address in (self.profile or {}).get("directIPv4", [])],
            "splits": [{"cidr": cidr, "interface": None, "attempted": False} for cidr in SPLIT_ROUTES],
        }
        self.checkpoint()

    def pin_host_route(self, entry: dict[str, Any]) -> None:
        if entry["existing"]:
            return
        entry["attempted"] = True
        self.checkpoint()
        address = entry["cidr"].split("/")[0]
        run(["/sbin/route", "-n", "add", "-host", address,
             entry["gateway"], "-ifp", entry["interface"]])

    def disable_ipv6(self) -> None:
        network = self.mutations["network"]
        if network["ipv6_mode"] != "Off" and not network["ipv6_attempted"]:
            network["ipv6_attempted"] = True
            self.checkpoint()
            run(["/usr/sbin/networksetup", "-setv6off", network["service"]])
        route = run(["/sbin/route", "-n", "get", "-inet6", "2606:4700:4700::1111"], check=False)
        if route.returncode == 0 and parse_route_get(route.stdout).get("interface"):
            raise HelperError("A usable IPv6 route remains active after disabling IPv6.")

    def configure_dns(self) -> None:
        network = self.mutations["network"]
        if network["dns_attempted"]:
            return
        network["dns_attempted"] = True
        self.checkpoint()
        run(["/usr/sbin/networksetup", "-setdnsservers", network["service"], *DNS_SERVERS])

    def launch_backend(self) -> None:
        binary = self.resources / "sfera-net"
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise HelperError(f"Missing executable SFERA transport: {binary}")
        transport = self.root_state / "transport.json"
        try:
            transport.unlink()
        except FileNotFoundError:
            pass
        # The backend runs as root. Give it an immutable-by-user snapshot rather
        # than asking it to reopen a path that the GUI user can replace.
        token = self.profile["token"].encode() if self.profile else read_signaling_token(self.support, self.account)
        token_path = self.root_state / SIGNAL_TOKEN_NAME
        with os.fdopen(os.open(token_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                               0o600), "wb") as stream:
            stream.write(token)
        log_fd = open_root_log(self.root_state / "backend.log")
        argv = [str(binary), "client", "--signal-url", f"https://{self.server_ip}/api/session",
                "--signal-token-file", str(token_path),
                "--mtu", "1280", "--congestion", "ip-tunnel",
                "--status-file", str(transport)]
        if self.profile:
            argv += ["--tun-ip", self.tun_ip, "--peer-ip", self.gateway_ip]
        try:
            child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=log_fd,
                                     stderr=log_fd, start_new_session=True)
        finally:
            os.close(log_fd)
        self.backend = child
        self.children.append(child)
        self.record_child(child, argv, str(binary), argv[1:])

    def record_child(self, child: subprocess.Popen[bytes], argv: list[str], executable: str,
                     argv_prefix: list[str], argv_contains: Optional[list[str]] = None) -> None:
        self.child_records.append({
            "pid": child.pid, "start_token": process_start_token(child.pid),
            "executable": executable, "argv_prefix": argv_prefix,
            "argv_contains": argv_contains or [], "command_line": " ".join(argv),
        })
        self.checkpoint()

    def wait_backend_and_interface(self) -> None:
        deadline = time.monotonic() + START_TIMEOUT
        self.connected_at = time.time()
        while time.monotonic() < deadline:
            if STOP_EVENT.is_set() or (self.runtime / "stop.request").exists():
                raise HelperError("Connection was cancelled.")
            for child in self.children:
                if child.poll() is not None:
                    raise HelperError("SFERA transport exited during connection.")
            data = self.read_transport()
            if data.get("state") == "connected":
                interface = data.get("interface")
                current_utuns = list_utun_interfaces()
                if (isinstance(interface, str) and re.fullmatch(r"utun\d+", interface)
                        and interface in current_utuns and interface not in self.initial_utuns):
                    (self.root_state / SIGNAL_TOKEN_NAME).unlink(missing_ok=True)
                    self.interface = interface
                    self.status_fields = self.transport_status_fields(data)
                    return
            time.sleep(0.25)
        raise HelperError("SFERA transport did not report a connected utun interface within 35 seconds.")

    def read_transport(self) -> dict[str, Any]:
        transport = self.root_state / "transport.json"
        try:
            metadata = transport.lstat()
        except FileNotFoundError:
            return {}
        if (stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode) or
                metadata.st_uid != 0 or stat.S_IMODE(metadata.st_mode) & 0o077):
            raise HelperError("Unsafe root-owned transport status file.")
        data = read_json(transport) or {}
        if not data:
            return {}
        if self.backend is None or data.get("pid") != self.backend.pid:
            raise HelperError("SFERA status did not match the owned backend process.")
        if data.get("state") == "error":
            raise HelperError(str(data.get("error", "SFERA transport failed.")))
        if data.get("state") == "connected":
            if data.get("tun_ip") != self.tun_ip or data.get("peer_ip") != self.gateway_ip:
                raise HelperError("SFERA reported unexpected tunnel addresses.")
        return data

    @staticmethod
    def transport_status_fields(data: dict[str, Any]) -> dict[str, Any]:
        # These are diagnostics from the verified child, safe for the GUI and
        # local troubleshooting without a second administrator prompt.
        visible = ("interface", "rtt_ms", "tx_bytes", "rx_bytes", "bandwidth_mode",
                   "bitrate_mbps", "max_mbps", "dropped_packets", "drops",
                   "udp_recv_buffer_bytes", "udp_send_buffer_bytes", "udp_send_would_block",
                   "udp_send_interruptions", "udp_pending_sent", "udp_pending_peak_packets",
                   "udp_pending_peak_bytes", "rtp_padding_tx_bytes",
                   "delivery_matched_sample", "delivery_matched_age_ms",
                   "adaptive_pacing_mbps", "adaptive_pacing_updates")
        fields = {key: data[key] for key in visible if key in data}
        if data.get("tun_ip"):
            fields["tunnel_ip"] = data["tun_ip"]
        return fields

    def install_split_routes(self) -> None:
        if not self.interface:
            raise HelperError("Cannot install split routes without a SFERA utun interface.")
        for entry in self.mutations["routes"]["splits"]:
            entry["interface"] = self.interface
            entry["attempted"] = True
            self.checkpoint()
            run(["/sbin/route", "-n", "add", "-net", entry["cidr"], "-interface", self.interface])
            entry["added"] = True
            self.checkpoint()

    def checkpoint(self) -> None:
        atomic_json(self.root_state / "session.json", {
            "pid": os.getpid(), "uid": self.uid, "start_token": process_start_token(os.getpid()),
            "interface": self.interface,
            "mutations": self.mutations, "children": self.child_records,
            "updated_at": int(time.time()),
        })

    def cleanup(self) -> list[str]:
        errors: list[str] = []
        for child in reversed(self.children):
            try:
                if child.poll() is None:
                    child.terminate()
            except OSError as exc:
                errors.append(f"stop owned child {child.pid}: {exc}")
        for child in reversed(self.children):
            try:
                if child.poll() is None:
                    child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    child.kill()
                    child.wait(timeout=2)
                except (OSError, subprocess.TimeoutExpired) as exc:
                    errors.append(f"terminate owned child {child.pid}: {exc}")
            except OSError as exc:
                errors.append(f"wait for owned child {child.pid}: {exc}")
        try:
            (self.root_state / SIGNAL_TOKEN_NAME).unlink(missing_ok=True)
        except OSError as exc:
            errors.append(f"remove supervisor signaling token: {exc}")
        errors.extend(self.rollback_network())
        return errors

    def rollback_network(self) -> list[str]:
        errors: list[str] = []
        routes = self.mutations.get("routes", {})
        for entry in reversed(routes.get("splits", [])):
            if entry.get("attempted"):
                try:
                    self.remove_split_route(entry)
                except Exception as exc:
                    errors.append(f"remove route {entry.get('cidr')}: {exc}")
        errors.extend(restore_network_services(self.mutations))
        errors.extend(restore_host_routes(routes))
        return errors

    def remove_split_route(self, entry: dict[str, Any]) -> None:
        current = parse_netstat_routes(run(["/usr/sbin/netstat", "-rn", "-f", "inet"]).stdout)
        route = current.get(entry["cidr"])
        if route and route.get("interface") == entry.get("interface"):
            run(["/sbin/route", "-n", "delete", "-net", entry["cidr"]])

def parse_route_get(output: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in output.splitlines():
        match = re.match(r"\s*(gateway|interface):\s*(\S+)", line)
        if match:
            values[match.group(1)] = match.group(2)
    return values


def primary_ipv4_path(output: str) -> Optional[dict[str, str]]:
    for line in output.splitlines():
        fields = line.split()
        if len(fields) < 4 or fields[0] != "default":
            continue
        _, gateway, flags, interface = fields[:4]
        if "I" in flags or "U" not in flags or "G" not in flags:
            continue
        if interface.startswith(("utun", "lo")):
            return None
        try:
            ipaddress.IPv4Address(gateway)
        except ValueError:
            return None
        return {"gateway": gateway, "interface": interface}
    return None


def parse_netstat_routes(output: str, *, unscoped_only: bool = False) -> dict[str, dict[str, str]]:
    routes: dict[str, dict[str, str]] = {}
    for line in output.splitlines():
        columns = line.split()
        if len(columns) < 4 or columns[0] in {"Routing", "Internet:", "Destination"}:
            continue
        destination, gateway, flags, interface = columns[:4]
        if destination == "default" or (unscoped_only and "I" in flags):
            continue
        try:
            if "/" in destination:
                address, prefix = destination.split("/", 1)
                octets = address.split(".")
                if len(octets) < 4:
                    address = ".".join(octets + ["0"] * (4 - len(octets)))
                network = ipaddress.ip_network(f"{address}/{prefix}", strict=False)
            else:
                octets = destination.split(".")
                if len(octets) < 4:
                    address = ".".join(octets + ["0"] * (4 - len(octets)))
                    prefix = 8 * len(octets)
                    network = ipaddress.ip_network(f"{address}/{prefix}", strict=False)
                else:
                    network = ipaddress.ip_network(f"{destination}/32", strict=False)
        except ValueError:
            continue
        routes[str(network)] = {"gateway": gateway, "interface": interface}
    return routes


def service_for_interface(interface: str) -> Optional[str]:
    output = run(["/usr/sbin/networksetup", "-listnetworkserviceorder"]).stdout
    service: Optional[str] = None
    for line in output.splitlines():
        match = re.match(r"\(\d+\) (.+)$", line.strip())
        if match:
            service = match.group(1)
            if service.startswith("*"):
                service = None
        device = re.search(r"Device: ([^,)]+)", line)
        if device and device.group(1) == interface and service:
            return service
    return None


def list_utun_interfaces() -> list[str]:
    result = run(["/sbin/ifconfig", "-l"], check=False)
    return [name for name in result.stdout.split() if re.fullmatch(r"utun\d+", name)]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="SFERA Test macOS VPN supervisor")
    subs = parser.add_subparsers(dest="action", required=True)
    for action in ("start", "stop", "supervise"):
        sub = subs.add_parser(action)
        sub.add_argument("--resources", required=True)
        sub.add_argument("--user-home", required=True)
        sub.add_argument("--user-uid", type=int, required=True)
        if action != "stop":
            sub.add_argument("--profile", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.user_uid <= 0:
            raise HelperError("A regular user account is required.")
        if args.action == "start":
            return command_start(args)
        if args.action == "stop":
            return command_stop(args)
        return command_supervise(args)
    except HelperError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
