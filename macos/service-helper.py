"""Install and contact the local, account-scoped SFERA LaunchDaemon."""

import argparse
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import pwd
import shlex
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time


LABEL = "dev.sfera.test.helper"
INSTALL_ROOT = Path("/Library/PrivilegedHelperTools") / LABEL
PLIST = Path("/Library/LaunchDaemons") / f"{LABEL}.plist"
SOCKET_PATH = INSTALL_ROOT / "control.sock"
PYTHON = ["/usr/bin/python3", "-I", "-B"]
FILES = {"service-helper.py": 0o644, "root-helper.py": 0o644, "sfera-net": 0o755}
MAX_PAYLOAD = 32 * 1024 * 1024


def payloads(resources):
    files = {}
    for name in FILES:
        fd = os.open(resources / name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise ValueError(f"Invalid SFERA resource {name}")
            data = stream.read(MAX_PAYLOAD + 1)
        if not data or len(data) > MAX_PAYLOAD:
            raise ValueError(f"Invalid size for SFERA resource {name}")
        files[name] = data
    return files


def release_id(files):
    digest = hashlib.sha256()
    for name, data in files.items():
        digest.update(name.encode("ascii") + b"\0" + hashlib.sha256(data).digest())
    return digest.hexdigest()


def peer_uid(connection):
    uid = ctypes.c_uint()
    gid = ctypes.c_uint()
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.getpeereid(connection.fileno(), ctypes.byref(uid), ctypes.byref(gid)):
        raise OSError(ctypes.get_errno(), "getpeereid")
    return uid.value


def read_line(connection, limit):
    with connection.makefile("rb") as stream:
        line = stream.readline(limit + 1)
    if len(line) > limit or not line.endswith(b"\n"):
        raise ValueError("Invalid SFERA helper message")
    return line


def request(command, timeout):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(timeout)
        connection.connect(str(SOCKET_PATH))
        if peer_uid(connection) != 0:
            raise PermissionError("SFERA helper is not running as root")
        connection.sendall(command)
        return json.loads(read_line(connection, 4096))


def serve(uid, version):
    resources = Path(__file__).resolve().parent
    if os.geteuid() != 0 or resources.parent != INSTALL_ROOT or resources.name != version:
        raise PermissionError("Invalid SFERA service installation")
    account = pwd.getpwuid(uid)
    arguments = PYTHON + [str(resources / "root-helper.py"), "start",
                          "--resources", str(resources), "--user-uid", str(uid),
                          "--user-home", account.pw_dir]
    signal.pthread_sigmask(signal.SIG_UNBLOCK, (signal.SIGTERM, signal.SIGINT))
    os.umask(0o077)
    if SOCKET_PATH.exists():
        if not stat.S_ISSOCK(SOCKET_PATH.lstat().st_mode):
            raise ValueError("Invalid SFERA socket path")
        SOCKET_PATH.unlink()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
        listener.bind(str(SOCKET_PATH))
        os.chown(SOCKET_PATH, uid, -1)
        os.chmod(SOCKET_PATH, 0o600)
        listener.listen(4)
        while True:
            connection, _ = listener.accept()
            with connection:
                try:
                    connection.settimeout(2)
                    caller = peer_uid(connection)
                    command = read_line(connection, 4096)
                    if command == b"probe\n" and caller in (0, uid):
                        reply = {"version": version}
                    elif caller == uid and (command == b"start\n" or command.startswith(b"start-profile ")):
                        profile = command[len(b"start-profile "):] if command != b"start\n" else None
                        argv = arguments + ["--profile"] if profile is not None else arguments
                        result = subprocess.run(argv, input=profile, capture_output=True, timeout=40)
                        message = result.stderr.decode(errors="replace").strip() if result.returncode else ""
                        reply = {"ok": result.returncode == 0, "error": message[:512]}
                    else:
                        reply = {"ok": False, "error": "Команда SFERA запрещена."}
                    connection.sendall(json.dumps(reply, ensure_ascii=False).encode() + b"\n")
                except (OSError, ValueError, subprocess.TimeoutExpired):
                    continue


def verify_directory(path):
    metadata = path.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o022:
        raise PermissionError(f"Unsafe SFERA installation directory {path}")


def atomic_plist(data):
    fd, name = tempfile.mkstemp(prefix=f".{LABEL}.", dir=PLIST.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            os.fchmod(stream.fileno(), 0o644)
        os.replace(name, PLIST)
    finally:
        Path(name).unlink(missing_ok=True)


def launchctl(*args, check=True):
    return subprocess.run(["/bin/launchctl", *args], check=check, capture_output=True, timeout=15)


def wait_service(version):
    for _ in range(30):
        try:
            if request(b"probe\n", 1).get("version") == version:
                return
        except (FileNotFoundError, ConnectionRefusedError, TimeoutError):
            time.sleep(0.1)
    raise RuntimeError("Системный помощник SFERA не запустился.")


def install(resources, uid, version):
    if os.geteuid() != 0 or uid <= 0:
        raise PermissionError("SFERA helper installation requires administrator authorization")
    pwd.getpwuid(uid)
    files = payloads(resources)
    if release_id(files) != version:
        raise ValueError("SFERA resources changed during authorization")
    os.umask(0o022)
    verify_directory(INSTALL_ROOT.parent)
    verify_directory(PLIST.parent)
    INSTALL_ROOT.mkdir(mode=0o755, exist_ok=True)
    verify_directory(INSTALL_ROOT)
    lock_path = INSTALL_ROOT / "install.lock"
    with lock_path.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        release = INSTALL_ROOT / version
        if release.exists():
            verify_directory(release)
            if payloads(release) != files:
                raise ValueError("Invalid installed SFERA resources")
        else:
            with tempfile.TemporaryDirectory(prefix=".install-", dir=INSTALL_ROOT) as staging:
                directory = Path(staging)
                for name, data in files.items():
                    destination = directory / name
                    destination.write_bytes(data)
                    destination.chmod(FILES[name])
                directory.chmod(0o755)
                directory.rename(release)
        previous = PLIST.read_bytes() if PLIST.exists() else None
        settings = {"Label": LABEL, "RunAtLoad": True, "KeepAlive": True,
                    "ProgramArguments": PYTHON + [str(release / "service-helper.py"), "serve", str(uid), version]}
        launchctl("bootout", f"system/{LABEL}", check=False)
        try:
            atomic_plist(plistlib.dumps(settings))
            launchctl("bootstrap", "system", str(PLIST))
            wait_service(version)
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
            launchctl("bootout", f"system/{LABEL}", check=False)
            if previous is None:
                PLIST.unlink(missing_ok=True)
            else:
                atomic_plist(previous)
                launchctl("bootstrap", "system", str(PLIST), check=False)
            raise


def connect(resources, profile=None):
    files = payloads(resources)
    version = release_id(files)
    try:
        installed = request(b"probe\n", 5).get("version")
    except (FileNotFoundError, ConnectionRefusedError):
        installed = None
    if installed != version:
        # Pass the installer code by value so elevation never reopens it from
        # the writable application directory. The payload digest pins the copy.
        command = shlex.join(PYTHON + ["-c", files["service-helper.py"].decode(),
                                      "install", str(resources), str(os.getuid()), version])
        quoted = command.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
        result = subprocess.run(
            ["/usr/bin/osascript", "-e", f'do shell script "{quoted}" with administrator privileges'],
            capture_output=True, text=True,
        )
        if result.returncode:
            raise RuntimeError(result.stderr.strip()[:512] or "Установка помощника SFERA прервана.")
    message = b"start-profile " + profile + b"\n" if profile is not None else b"start\n"
    response = request(message, 45)
    if not response.get("ok"):
        raise RuntimeError(response.get("error") or "Системный помощник не подключил SFERA.")


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("connect", "install", "serve"):
        command = commands.add_parser(name)
        if name != "serve":
            command.add_argument("resources", type=Path)
        if name == "connect":
            command.add_argument("--profile", action="store_true")
        else:
            command.add_argument("uid", type=int)
            command.add_argument("version")
    args = parser.parse_args()
    try:
        if args.command == "connect":
            profile = sys.stdin.buffer.read(2049).strip() if args.profile else None
            if args.profile and (not profile or len(profile) > 2048 or b"\n" in profile):
                raise ValueError("Invalid SFERA profile message")
            connect(args.resources, profile)
        elif args.command == "install":
            install(args.resources, args.uid, args.version)
        else:
            serve(args.uid, args.version)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
