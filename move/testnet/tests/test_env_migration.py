"""Offline regression tests for the embedded environment migration program."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "update_testnet_envs.sh"
PROGRAM = SCRIPT.read_text(encoding="utf-8").split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
LEGACY = "0x55a6b6848a5a343a8ad5ec5db46a93b15011bc3e50fd164e03d996f1aa317425"


def report(package, objects):
    return f"PackageID: {package}\n" + "\n".join(
        f"│  ┌──\n│ ObjectID: {oid}\n│ ObjectType: {package}::{kind} \n│  └──"
        for kind, oid in objects
    )


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.caps = self.root / "caps.txt"
        self.system = self.root / "system.txt"
        self.tasks = self.root / "tasks.txt"
        self.caps.write_text("PackageID: 0xa\n", encoding="utf-8")
        self.system.write_text(report("0xb", [
            ("systemState::State", "0x11"), ("systemState::NodeRegistry", "0x12"),
            ("systemState::OracleTreasury", "0x13"), ("systemState::ControllerCap", "0x14"),
        ]), encoding="utf-8")
        self.tasks.write_text(report("0xc", [
            ("oracle_tasks::TaskRegistry", "0x21"), ("oracle_tasks::SchedulerQueue", "0x22"),
        ]), encoding="utf-8")
        (self.root / "node").mkdir()
        self.env = self.root / "node/.env"
        self.original = (
            "ORACLE_STATE_ID=0xold\nORACLE_STATE_ID=0xolder\n"
            "DELEGATED_CONTROLLER_CAP_ID=0xfeed\nNODE_1_DELEGATED_CONTROLLER_CAP_ID=0xbeef\n"
        )
        self.env.write_text(self.original, encoding="utf-8")

    def run_program(self, *args):
        return subprocess.run([sys.executable, "-c", PROGRAM, str(self.root), str(self.caps),
                               str(self.system), str(self.tasks), *args], capture_output=True, text=True)

    def test_updates_all_duplicates_and_preserves_caps(self):
        result = self.run_program()
        self.assertEqual(result.returncode, 0, result.stderr)
        text = self.env.read_text(encoding="utf-8")
        self.assertEqual(text.splitlines().count("ORACLE_STATE_ID=0x11"), 2)
        self.assertIn("DELEGATED_CONTROLLER_CAP_ID=0xfeed\n", text)
        self.assertIn("NODE_1_DELEGATED_CONTROLLER_CAP_ID=0xbeef\n", text)
        self.assertIn("TESTNET_ORACLE_NODE_REGISTRY_ID=0x12\n", text)
        self.assertIn("REGISTER_MODE=prod\n", text)

    def test_check_only_does_not_modify_configuration(self):
        result = self.run_program("--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.env.read_text(encoding="utf-8"), self.original)

    def test_unattended_node_overrides_and_private_rpc_are_preserved(self):
        self.env.write_text(self.original +
            'IOTA_RPC_URL=https://private.example/rpc\nTESTNET_IOTA_RPC_URL=https://private.example/test\n'
            'NODE_1_NETWORK="testnet" # validator\nNODE_1_REGISTER_MODE=dev\nNODE_1_AUTO_REGISTER=false\n'
            'export NODE_1_ORACLE_STATE_ID = 0xold\nNODE_1_TESTNET_ORACLE_STATE_ID=0xolder\n'
            'NODE_2_NETWORK=devnet\nNODE_2_REGISTER_MODE=dev\nNODE_2_ORACLE_STATE_ID=0xdev\n', encoding='utf-8')
        result = self.run_program()
        self.assertEqual(result.returncode, 0, result.stderr)
        text = self.env.read_text(encoding='utf-8')
        for expected in ['NODE_1_REGISTER_MODE=prod', 'NODE_1_AUTO_REGISTER=true',
                         'NODE_1_ORACLE_STATE_ID=0x11', 'NODE_1_TESTNET_ORACLE_STATE_ID=0x11',
                         'NODE_2_REGISTER_MODE=dev', 'NODE_2_ORACLE_STATE_ID=0xdev',
                         'IOTA_RPC_URL=https://private.example/rpc', 'TESTNET_IOTA_RPC_URL=https://private.example/test']:
            self.assertIn(expected + '\n', text)
        before = text
        self.assertEqual(self.run_program().returncode, 0)
        self.assertEqual(self.env.read_text(encoding='utf-8'), before)

    def test_legacy_reports_fail_before_writes(self):
        self.system.write_text(self.system.read_text(encoding="utf-8").replace("0xb", LEGACY), encoding="utf-8")
        result = self.run_program()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Legacy testnet", result.stderr)
        self.assertEqual(self.env.read_text(encoding="utf-8"), self.original)

    def test_partial_publication_fails_before_writes(self):
        self.tasks.write_text("PackageID: 0xc\n", encoding="utf-8")
        result = self.run_program()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing required", result.stderr)
        self.assertEqual(self.env.read_text(encoding="utf-8"), self.original)

    def test_mixed_report_type_origins_fail(self):
        self.tasks.write_text(self.tasks.read_text(encoding="utf-8").replace("0xc::", "0xd::"), encoding="utf-8")
        result = self.run_program()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing required", result.stderr)
        self.assertEqual(self.env.read_text(encoding="utf-8"), self.original)

    def test_foreign_object_block_cannot_supply_registry_id(self):
        foreign = report("0xd", [("systemState::NodeRegistry", "0xdead")]).split("\n", 1)[1]
        self.system.write_text(foreign + "\n" + self.system.read_text(encoding="utf-8"), encoding="utf-8")
        result = self.run_program()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ORACLE_NODE_REGISTRY_ID=0x12\n", self.env.read_text(encoding="utf-8"))
        self.assertNotIn("0xdead", self.env.read_text(encoding="utf-8"))

    def test_ambiguous_publication_reports_fail_before_writes(self):
        self.system.write_text(self.system.read_text(encoding="utf-8") + "\nPackageID: 0xd\n", encoding="utf-8")
        result = self.run_program()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Ambiguous", result.stderr)
        self.assertEqual(self.env.read_text(encoding="utf-8"), self.original)


if __name__ == "__main__":
    unittest.main()
