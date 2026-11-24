"""Exercise update.sh offline with fake Docker/git; never touch real services."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]

class UnattendedUpgradeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        shutil.copy2(ROOT / 'update.sh', self.root / 'update.sh')
        for directory in ['bin', 'node', 'move/testnet']:
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        (self.root / 'node/.env').write_text('IOTA_NETWORK=testnet\nDELEGATED_CONTROLLER_CAP_ID=0xfeed\n')
        (self.root / 'node/docker-compose.yml').write_text('services: {}\n')
        (self.root / 'move/testnet/update_testnet_envs.sh').write_text('touch env-migrated\n')
        self.executable('git', '#!/bin/sh\nexit 0\n')
        self.executable('npm', '#!/bin/sh\necho unexpected-host-npm >&2\nexit 42\n')
        self.executable('docker', '''#!/bin/sh
echo "$*" >> "$FAKE_ROOT/docker.log"
case "$*" in
  *"config --services"*)
    [ "${FAKE_CONFIG_FAILURE:-0}" = 0 ] || exit 14
    [ "${FAKE_EMPTY_SERVICES:-0}" = 0 ] && echo oracle-node-1 ;;
  *"exec -T"*) exit "${FAKE_HEALTH_FAILURE:-0}" ;;
esac
exit 0
''')

    def executable(self, name, content):
        path = self.root / 'bin' / name
        path.write_text(content)
        path.chmod(0o755)

    def run_update(self, failing=False, config_failure=False, empty_services=False):
        env = dict(os.environ, PATH=str(self.root / 'bin') + os.pathsep + os.environ['PATH'],
                   FAKE_ROOT=str(self.root), UPDATE_READY_TIMEOUT='1', FAKE_HEALTH_FAILURE='1' if failing else '0',
                   FAKE_CONFIG_FAILURE='1' if config_failure else '0', FAKE_EMPTY_SERVICES='1' if empty_services else '0')
        return subprocess.run(['bash', 'update.sh', '--skip-git', '--network', 'testnet', '--no-webview'],
                              cwd=self.root, env=env, capture_output=True, text=True, timeout=25)

    def test_rebuild_restart_and_readiness_without_prompts_or_host_npm(self):
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / 'env-migrated').exists())
        log = (self.root / 'docker.log').read_text()
        self.assertIn('up --build --force-recreate -d', log)
        self.assertIn('exec -T oracle-node-1', log)
        self.assertIn('Update completed', result.stdout)
        self.assertIn('DELEGATED_CONTROLLER_CAP_ID=0xfeed', (self.root / 'node/.env').read_text())

    def test_failed_registration_does_not_report_upgrade_success(self):
        result = self.run_update(failing=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Upgrade is not confirmed', result.stderr)
        self.assertNotIn('Update completed', result.stdout)

    def test_failed_service_inventory_is_not_success(self):
        result = self.run_update(config_failure=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('Update completed', result.stdout)

    def test_empty_service_inventory_is_not_success(self):
        result = self.run_update(empty_services=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('No oracle-node services', result.stderr)

if __name__ == '__main__':
    unittest.main()
