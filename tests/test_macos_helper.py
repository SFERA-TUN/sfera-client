"""Regression tests for the macOS supervisor without root or network changes."""

import importlib.util
import io
import json
import os
from pathlib import Path
import pwd
import signal
import stat
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


HELPER_PATH = Path(__file__).resolve().parents[1] / "root-helper.py"
SPEC = importlib.util.spec_from_file_location("sfera_macos_helper", HELPER_PATH)
if SPEC is None or SPEC.loader is None:
    raise ImportError(f"Cannot load supervisor from {HELPER_PATH}")
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)


NETSTAT = """\
Routing tables

Internet:
Destination        Gateway            Flags               Netif Expire
0/1                link#27            UCS                 utun8
128.0/1            link#27            UCS                 utun8
10.241/16          10.242.35.176      UGSc                utun4
192.0.2.1     192.168.1.1        UGHS                  en1
"""


class MacOSHelperTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.runtime = self.base / "runtime"
        self.root_state = self.base / "supervisor"
        self.runtime.mkdir()
        self.root_state.mkdir()
        self.journal = self.root_state / "session.json"
        self.transport = self.root_state / "transport.json"
        self.netstat = NETSTAT
        self.account = pwd.getpwuid(os.getuid())
        self.supervisor = helper.Supervisor(
            self.account.pw_uid, self.account, self.base, self.base,
            self.runtime, self.root_state,
        )

    def test_darwin_abbreviates_network_routes(self):
        for upper in ("128.0/1", "128/1"):
            with self.subTest(upper=upper):
                routes = helper.parse_netstat_routes(NETSTAT.replace("128.0/1", upper))
                self.assertEqual(routes["0.0.0.0/1"]["interface"], "utun8")
                self.assertEqual(routes["128.0.0.0/1"]["interface"], "utun8")
                self.assertEqual(routes["10.241.0.0/16"]["interface"], "utun4")
                self.assertEqual(routes["192.0.2.1/32"]["gateway"], "192.168.1.1")

    def test_primary_route_ignores_interface_scoped_defaults(self):
        table = "default 192.168.1.1 UGScIg en1\ndefault 172.20.10.1 UGScg en5\n"
        self.assertEqual(helper.primary_ipv4_path(table), {"gateway": "172.20.10.1", "interface": "en5"})
        self.assertIsNone(helper.primary_ipv4_path("default 10.8.0.1 UGSc utun3\n" + table))

    def test_handoff_journals_and_restores_both_network_services(self):
        self.supervisor.mutations = self.mutations()
        self.netstat = "default 172.20.10.1 UGScg en5\n" + NETSTAT

        def run(argv, **kwargs):
            if argv[1:2] == ["-getinfo"]:
                return subprocess.CompletedProcess(argv, 0, stdout="IPv6: Automatic\n")
            if argv[1:2] == ["-getdnsservers"]:
                return subprocess.CompletedProcess(argv, 0, stdout="172.20.10.1\n")
            if "-inet6" in argv:
                return subprocess.CompletedProcess(argv, 1, stdout="")
            if argv[:3] == ["/sbin/route", "-n", "change"]:
                host = json.loads(self.journal.read_text())["mutations"]["routes"]["host"]
                self.assertEqual(host["previous"], {"gateway": "192.168.1.1", "interface": "en1"})
                self.assertEqual(host["interface"], "en5")
                self.netstat = self.netstat.replace(
                    "192.0.2.1     192.168.1.1        UGHS                  en1",
                    "192.0.2.1     172.20.10.1        UGHS                  en5")
            return self.network_command(argv, **kwargs)

        with mock.patch.object(helper, "service_for_interface", return_value="USB Tether"), \
                mock.patch.object(helper, "run", side_effect=run) as command:
            self.supervisor.refresh_underlay()
            host = self.supervisor.mutations["routes"]["host"]
            self.assertEqual(host["gateway"], "172.20.10.1")
            self.assertNotIn("previous", host)
            self.supervisor.cleanup()
        self.assert_restorations_attempted(command)
        command.assert_any_call(["/usr/sbin/networksetup", "-setdnsservers", "USB Tether", "172.20.10.1"])
        command.assert_any_call(["/usr/sbin/networksetup", "-setv6automatic", "USB Tether"])

    def test_stale_recovery_can_remove_route_from_before_interrupted_handoff(self):
        entry = self.mutations()["routes"]["host"]
        entry.update(interface="en5", gateway="172.20.10.1",
                     previous={"gateway": "192.168.1.1", "interface": "en1"})
        with mock.patch.object(helper, "run", side_effect=self.network_command) as command:
            helper.remove_host_route(entry)
        command.assert_any_call(["/sbin/route", "-n", "delete", "-host", "192.0.2.1"])

    def test_direct_route_is_journaled_and_removed_during_recovery(self):
        self.supervisor.profile = {"directIPv4": ["77.88.55.242"]}
        self.supervisor.original_gateway = "192.168.1.1"
        self.supervisor.original_interface = "en1"
        self.netstat = "default 192.168.1.1 UGScg en1\n"
        with mock.patch.object(helper, "run", side_effect=self.network_command) as command:
            self.supervisor.ensure_no_route_conflicts()
            entry = helper.direct_routes(self.supervisor.mutations["routes"])[0]
            self.supervisor.pin_host_route(entry)
            command.assert_any_call(["/sbin/route", "-n", "add", "-net", "77.88.55.242/32",
                                     "192.168.1.1", "-ifp", "en1"])
            record = json.loads(self.journal.read_text())
            self.netstat += "77.88.55.242 192.168.1.1 UGHS en1\n"
            legacy_entry = next(item for item in record["mutations"]["routes"]["splits"] if item["attempted"])
            helper.remove_split_route_entry(legacy_entry)
            command.assert_any_call(["/sbin/route", "-n", "delete", "-net", "77.88.55.242/32"])
            command.reset_mock()
            self.assertEqual(helper.recover_stale_session(record, self.runtime), [])
            command.assert_any_call(["/sbin/route", "-n", "delete", "-net", "77.88.55.242/32"])

    def test_direct_routes_reject_ranges_private_addresses_and_tunnel_dns(self):
        profile = {"version": 1, "host": "8.8.4.4", "peerIP": "10.203.0.6", "token": "b" * 64}
        for value in ("0.0.0.0/0", "192.168.1.1", "1.1.1.1", "224.0.0.1"):
            with self.subTest(value=value):
                profile["directIPv4"] = [value]
                data = io.BytesIO(json.dumps(profile).encode())
                with mock.patch.object(helper.sys, "stdin", SimpleNamespace(buffer=data)):
                    with self.assertRaises(helper.HelperError):
                        helper.read_profile()

    def test_handoff_leaves_an_externally_replaced_host_route_alone(self):
        self.supervisor.mutations = self.mutations()
        self.netstat = ("default 172.20.10.1 UGScg en5\n"
                        "192.0.2.1 192.0.2.1 UGHS en8\n")
        with mock.patch.object(helper, "run", side_effect=self.network_command) as command:
            self.supervisor.refresh_underlay()
        command.assert_called_once_with(["/usr/sbin/netstat", "-rn", "-f", "inet"])

    def test_signaling_token_requires_private_regular_file_with_one_hex_line(self):
        token = self.base / helper.SIGNAL_TOKEN_NAME
        valid = b"a" * 64 + b"\n"
        for content, mode in ((valid, 0o644), (valid, 0o400), (b"A" * 64, 0o600),
                              (valid + b"\n", 0o600), (valid + b"extra", 0o600)):
            with self.subTest(content=content, mode=oct(mode)):
                token.unlink(missing_ok=True)
                token.write_bytes(content)
                token.chmod(mode)
                with self.assertRaises(helper.HelperError):
                    helper.read_signaling_token(self.base, self.account)
        token.write_bytes(valid)
        self.assertEqual(helper.read_signaling_token(self.base, self.account), valid)
        target = token.rename(self.base / "token-target")
        token.symlink_to(target)
        with self.assertRaisesRegex(helper.HelperError, "safely open"):
            helper.read_signaling_token(self.base, self.account)

    def test_backend_receives_only_private_token_path_and_removes_snapshot(self):
        token = self.base / helper.SIGNAL_TOKEN_NAME
        content = b"a" * 64 + b"\n"
        token.write_bytes(content)
        token.chmod(0o600)
        binary = self.base / "sfera-net"
        binary.touch(mode=0o700)
        snapshot = self.root_state / helper.SIGNAL_TOKEN_NAME
        backend = mock.Mock(pid=4321)
        backend.poll.return_value = 0

        with mock.patch.object(helper, "open_root_log", return_value=os.open(os.devnull, os.O_WRONLY)), \
                mock.patch.object(helper.subprocess, "Popen", return_value=backend) as spawn, \
                mock.patch.object(helper, "process_start_token", return_value="start"):
            self.supervisor.launch_backend()
        spawn.assert_called_once()
        argv = spawn.call_args.args[0]
        self.assertEqual(argv[:6], [str(binary), "client", "--signal-url",
                                    "https://192.0.2.1/api/session",
                                    "--signal-token-file", str(snapshot)])
        self.assertNotIn(content.strip().decode(), self.journal.read_text(encoding="utf-8"))
        self.assertEqual(snapshot.read_bytes(), content)
        self.assertEqual(stat.S_IMODE(snapshot.stat().st_mode), 0o600)
        self.assertEqual(self.supervisor.cleanup(), [])
        self.assertFalse(snapshot.exists())
        self.assertEqual(token.read_bytes(), content)

    def test_selfhost_profile_pins_the_supplied_host_and_tunnel_pair(self):
        profile = {"version": 1, "host": "1.1.1.1", "peerIP": "10.203.0.6", "token": "b" * 64}
        with mock.patch.object(helper.sys, "stdin", SimpleNamespace(buffer=io.BytesIO(json.dumps(profile).encode()))):
            parsed = helper.read_profile()
        self.assertEqual(parsed, profile)
        supervisor = helper.Supervisor(self.account.pw_uid, self.account, self.base, self.base,
                                       self.runtime, self.root_state, parsed)
        binary = self.base / "sfera-net"
        binary.touch(mode=0o700)
        backend = mock.Mock(pid=4321)
        with mock.patch.object(helper, "open_root_log", return_value=os.open(os.devnull, os.O_WRONLY)), \
                mock.patch.object(helper.subprocess, "Popen", return_value=backend) as spawn, \
                mock.patch.object(helper, "process_start_token", return_value="start"):
            supervisor.launch_backend()
        argv = spawn.call_args.args[0]
        self.assertEqual(argv[3], "https://1.1.1.1/api/session")
        self.assertEqual(argv[-4:], ["--tun-ip", "10.203.0.6", "--peer-ip", "10.203.0.5"])
        self.assertNotIn(profile["token"], argv)
        self.assertEqual((self.root_state / helper.SIGNAL_TOKEN_NAME).read_bytes(), b"b" * 64)

        table = NETSTAT.replace("192.0.2.1", "1.1.1.1")
        host = {"cidr": "1.1.1.1/32", "gateway": "192.168.1.1", "interface": "en1"}
        with mock.patch.object(helper, "run", return_value=SimpleNamespace(stdout=table)) as command:
            helper.remove_host_route(host)
        command.assert_called_with(["/sbin/route", "-n", "delete", "-host", "1.1.1.1"])

    def test_selfhost_profile_rejects_non_rfc1918_peer(self):
        profile = {"version": 1, "host": "1.1.1.1", "peerIP": "192.0.2.2", "token": "b" * 64}
        with mock.patch.object(helper.sys, "stdin", SimpleNamespace(buffer=io.BytesIO(json.dumps(profile).encode()))):
            with self.assertRaisesRegex(helper.HelperError, "Invalid SFERA"):
                helper.read_profile()

    def test_supervisor_recovers_inherited_blocked_stop_signals(self):
        signals = (signal.SIGTERM, signal.SIGINT)
        original_handlers = {signum: signal.getsignal(signum) for signum in signals}
        original_mask = signal.pthread_sigmask(signal.SIG_BLOCK, signals)
        original_umask = os.umask(0o077)
        observed = []

        def start_test_backend():
            mask = signal.pthread_sigmask(signal.SIG_BLOCK, [])
            for signum in signals:
                with subprocess.Popen(["/bin/sleep", "10"], start_new_session=True) as child:
                    child.send_signal(signum)
                    try:
                        exit_code = child.wait(timeout=0.5)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait(timeout=2)
                        exit_code = None
                if signum not in mask:
                    signal.raise_signal(signum)
                observed.append((exit_code, helper.STOP_EVENT.is_set()))
                helper.STOP_EVENT.clear()
            helper.STOP_EVENT.set()

        try:
            for signum in signals:
                signal.signal(signum, signal.SIG_IGN)
            self.journal.write_text(json.dumps({"pid": os.getpid()}), encoding="utf-8")
            with mock.patch.object(self.supervisor, "establish_tunnel", side_effect=start_test_backend), \
                    mock.patch.object(helper, "publish_gui"):
                self.assertEqual(self.supervisor.run(), 0)
        finally:
            signal.pthread_sigmask(signal.SIG_BLOCK, signals)
            for signum, handler in original_handlers.items():
                signal.signal(signum, handler)
            signal.pthread_sigmask(signal.SIG_SETMASK, original_mask)
            os.umask(original_umask)
            helper.STOP_EVENT.clear()
        self.assertEqual(observed, [(-signum, True) for signum in signals])

    def test_failed_route_removal_does_not_skip_other_restorations(self):
        self.supervisor.mutations = self.mutations()
        with mock.patch.object(helper, "run", side_effect=self.network_command) as command:
            errors = self.supervisor.cleanup()
        self.assertTrue(errors)
        self.assertIn("injected route removal failure", " ".join(errors))
        self.assert_restorations_attempted(command)

    def test_failed_recovery_preserves_original_mutations_for_retry(self):
        saved = {"pid": 12345, "uid": self.account.pw_uid, "mutations": self.mutations()}
        self.journal.write_text(json.dumps(saved), encoding="utf-8")
        with mock.patch.object(helper, "state_dir", return_value=self.root_state), \
                mock.patch.object(helper, "run", side_effect=self.network_command) as command:
            errors = helper.recover_stale_session(saved, self.runtime)
        self.assertTrue(errors)
        self.assert_restorations_attempted(command)
        retained = json.loads(self.journal.read_text(encoding="utf-8"))
        self.assertEqual(retained["pid"], saved["pid"])
        self.assertEqual(retained["mutations"], saved["mutations"])
        self.assertIn("injected route removal failure", " ".join(retained["rollback_errors"]))

    def test_readiness_requires_trusted_current_transport(self):
        backend = mock.Mock(pid=4321)
        backend.poll.return_value = None
        self.supervisor.backend = backend
        self.supervisor.children = [backend]
        self.supervisor.initial_utuns = ["utun4"]
        valid_status = {
            "state": "connected",
            "pid": backend.pid,
            "tun_ip": "10.203.0.2",
            "peer_ip": "10.203.0.1",
            "interface": "utun8",
            "rtt_ms": 42.5,
            "tx_bytes": 1200,
            "rx_bytes": 1600,
        }
        # A valid-looking status written by the GUI user cannot grant readiness.
        (self.runtime / "transport.json").write_text(json.dumps(valid_status), encoding="utf-8")
        for change in (
            None,
            {"pid": 4322},
            {"tun_ip": "10.203.0.3"},
            {"peer_ip": "10.203.0.2"},
            {"interface": "utun4"},
            {"interface": "utun9"},
            {"interface": None},
        ):
            with self.subTest(change=change):
                if change is not None:
                    self.write_transport(dict(valid_status, **change))
                with self.transport_owner(0), \
                        mock.patch.object(helper, "list_utun_interfaces", return_value=["utun4", "utun8"]), \
                        mock.patch.object(helper.time, "monotonic", side_effect=[0.0, 0.0, 36.0]), \
                        mock.patch.object(helper.time, "sleep"):
                    with self.assertRaises(helper.HelperError):
                        self.supervisor.wait_backend_and_interface()
                self.assertIsNone(self.supervisor.interface)
        self.write_transport(valid_status)
        snapshot = self.root_state / helper.SIGNAL_TOKEN_NAME
        snapshot.touch(mode=0o600)
        with self.transport_owner(0), \
                mock.patch.object(helper, "list_utun_interfaces", return_value=["utun4", "utun8"]), \
                mock.patch.object(helper.time, "monotonic", side_effect=[0.0, 0.0, 36.0]), \
                mock.patch.object(helper.time, "sleep"):
            self.supervisor.wait_backend_and_interface()
        self.assertFalse(snapshot.exists())
        self.assertEqual(self.supervisor.interface, "utun8")
        self.assertEqual(self.supervisor.status_fields, {
            "interface": "utun8", "tunnel_ip": "10.203.0.2",
            "rtt_ms": 42.5, "tx_bytes": 1200, "rx_bytes": 1600,
        })

    def test_transport_status_rejects_nonroot_owner_and_open_permissions(self):
        self.supervisor.backend = mock.Mock(pid=4321)
        status = {"state": "connected", "pid": 4321, "tun_ip": "10.203.0.2", "peer_ip": "10.203.0.1"}
        for owner, mode in ((501, 0o600), (0, 0o644)):
            with self.subTest(owner=owner, mode=oct(mode)):
                self.write_transport(status, mode)
                with self.transport_owner(owner), self.assertRaisesRegex(helper.HelperError, "Unsafe"):
                    self.supervisor.read_transport()

    def test_stale_recovery_does_not_signal_a_reused_child_pid(self):
        executable = "/Applications/SFERA Test.app/Contents/Resources/sfera-net"
        # Darwin ps flattens argv without quoting spaces in the app bundle path.
        command = f"{executable} client"
        ssh_command = "/usr/bin/ssh -N -i /Users/example/Library/Application Support/SFERA Test/id_ed25519"
        saved_child = {"start_token": "original start", "command_line": command}
        record = {"children": [
            {"pid": 4323, "start_token": "ssh start", "command_line": ssh_command},
            dict(saved_child, pid=4321),
            dict(saved_child, pid=4322),
        ]}
        processes = {
            4321: (command, "different start"),
            4322: (command, "original start"),
            4323: (ssh_command, "ssh start"),
        }
        signaled = []

        def run(argv, **_kwargs):
            if argv[0] == "/bin/kill":
                pid = int(argv[-1])
                signaled.append(pid)
                processes.pop(pid)
                return subprocess.CompletedProcess(argv, 0)
            self.assertEqual(argv[0], "/bin/ps")
            if argv[-1] == "command=":
                self.assertIn("-ww", argv)
            process = processes.get(int(argv[argv.index("-p") + 1]))
            if process is None:
                return subprocess.CompletedProcess(argv, 1, stdout="")
            current_command, start_token = process
            output = start_token if argv[-1] == "lstart=" else current_command
            return subprocess.CompletedProcess(argv, 0, stdout=output)

        with mock.patch.object(helper, "run", side_effect=run):
            errors = helper.terminate_recorded_children(record)
        self.assertEqual(signaled, [4322, 4323])
        self.assertEqual(len(errors), 1)
        self.assertIn("4321", errors[0])

    def write_transport(self, status, mode=0o600):
        self.transport.write_text(json.dumps(status), encoding="utf-8")
        self.transport.chmod(mode)

    def transport_owner(self, uid):
        real_lstat = Path.lstat

        def lstat(path):
            metadata = real_lstat(path)
            if path == self.transport:
                return SimpleNamespace(st_mode=metadata.st_mode, st_uid=uid)
            return metadata

        return mock.patch.object(Path, "lstat", autospec=True, side_effect=lstat)

    def assert_restorations_attempted(self, command):
        attempts = [tuple(call.args[0]) for call in command.call_args_list]
        for restoration in (
            ("/sbin/route", "-n", "delete", "-net", "0.0.0.0/1"),
            ("/sbin/route", "-n", "delete", "-net", "128.0.0.0/1"),
            ("/sbin/route", "-n", "delete", "-host", "192.0.2.1"),
            ("/usr/sbin/networksetup", "-setdnsservers", "Wi-Fi", "192.168.1.1"),
            ("/usr/sbin/networksetup", "-setv6automatic", "Wi-Fi"),
        ):
            self.assertIn(restoration, attempts)

    @staticmethod
    def mutations():
        return {
            "routes": {
                "splits": [
                    {"cidr": "0.0.0.0/1", "interface": "utun8", "attempted": True},
                    {"cidr": "128.0.0.0/1", "interface": "utun8", "attempted": True},
                ],
                "host": {"cidr": "192.0.2.1/32", "interface": "en1",
                         "gateway": "192.168.1.1", "attempted": True, "existing": False},
            },
            "network": {"service": "Wi-Fi", "ipv6_mode": "Automatic", "dns": ["192.168.1.1"],
                        "ipv6_attempted": True, "dns_attempted": True},
        }

    def network_command(self, argv, **_kwargs):
        if argv[0] == "/usr/sbin/netstat":
            return subprocess.CompletedProcess(argv, 0, stdout=self.netstat, stderr="")
        if argv[:3] == ["/sbin/route", "-n", "delete"]:
            if argv[-1] == "128.0.0.0/1":
                raise helper.HelperError("injected route removal failure")
            destination = "0/1" if argv[-1] == "0.0.0.0/1" else argv[-1]
            self.netstat = "\n".join(
                line for line in self.netstat.splitlines() if not line.startswith(destination + " ")
            )
        return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")


if __name__ == "__main__":
    unittest.main()
