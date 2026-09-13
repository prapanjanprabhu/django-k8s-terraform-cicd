"""Offline control-flow tests: python -m unittest discover -s scripts -p 'test_*.py'."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
MOCK = r'''
python3() { "$TEST_PYTHON" "$@"; }
kubectl() {
  echo "$*" >> "$CALLS"
  case "$*" in
    *"get secret"*) printf '%s' "$SECRET_JSON" ;;
    *"set image deployment/django"*) touch "$APPLIED" ;;
    *"create -f"*) echo job.batch/django-migrate-test ;;
    *"get deployment django"*) printf '%s' "$PREVIOUS" ;;
    *"wait --for=condition=complete"*) [[ "$SCENARIO" != migration_failure ]] || return 1 ;;
    *"rollout status deployment/django"*)
      if [[ "$SCENARIO" == rollout_failure || "$SCENARIO" == first_failure ]]; then
        if [[ -f "$APPLIED" && ! -f "$UNDONE" ]]; then return 1; fi
      fi ;;
    *"rollout undo"*) touch "$UNDONE" ;;
  esac
  return 0
}
source scripts/deploy.sh
'''


class DeployTests(unittest.TestCase):
    def run_scenario(self, scenario, previous='7'):
        with tempfile.TemporaryDirectory(dir=ROOT) as directory:
            folder = Path(directory)
            # Relative paths work in both Unix Bash and Git Bash on Windows.
            relative = folder.relative_to(ROOT).as_posix()
            env = dict(os.environ, IMAGE='example/wrapzy:test', KUBE_CONTEXT='test',
                       TEST_PYTHON=Path(sys.executable).as_posix(),
                       SCENARIO=scenario, PREVIOUS=previous,
                       CALLS=f'{relative}/calls', APPLIED=f'{relative}/applied',
                       UNDONE=f'{relative}/undone')
            # The mock returns all required keys for either Secret query.
            keys = ['DJANGO_SECRET_KEY', 'ADMIN_USERNAME', 'ADMIN_PASSWORD',
                    'MYSQL_ROOT_PASSWORD', 'MYSQL_DATABASE', 'MYSQL_USER', 'MYSQL_PASSWORD']
            env['SECRET_JSON'] = json.dumps({'metadata': {'name': 'mysql-secret'},
                                            'data': dict.fromkeys(keys, 'dGVzdA==')})
            env['DEPLOYMENT_JSON'] = json.dumps({'spec': {'template': {'spec': {
                'containers': [{'name': 'django', 'image': env['IMAGE']}]
            }}}})
            result = subprocess.run([os.environ.get('BASH_BIN', 'bash'), '-c', MOCK],
                                    cwd=ROOT, env=env, capture_output=True, text=True)
            calls = (folder / 'calls').read_text() if (folder / 'calls').exists() else ''
            return result, calls

    def test_success(self):
        result, calls = self.run_scenario('success')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('rollout undo', calls)

    def test_failed_rollout_restores_previous_revision_and_fails(self):
        result, calls = self.run_scenario('rollout_failure')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('rollout undo deployment/django --to-revision=7', calls)

    def test_first_release_has_no_rollback(self):
        result, calls = self.run_scenario('first_failure', previous='')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('no previous revision', result.stdout)
        self.assertNotIn('rollout undo', calls)

    def test_failed_migration_does_not_apply_application(self):
        result, calls = self.run_scenario('migration_failure')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Migration failed', result.stdout)
        self.assertNotIn('apply -f k8s/django-deployment.yaml', calls)
        self.assertNotIn('set image deployment/django', calls)
        self.assertNotIn('rollout undo', calls)
