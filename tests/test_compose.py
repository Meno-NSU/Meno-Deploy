import itertools
import json
import os
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def compose_command():
    check = subprocess.run(['docker', 'compose', 'version'], capture_output=True)
    return ['docker', 'compose'] if check.returncode == 0 else ['docker-compose']


class ComposeTests(unittest.TestCase):
    def config(self, overlays=(), external=''):
        env = dict(os.environ, POSTGRES_PASSWORD='test-password', MODEL_API_KEY='test-key', GRAFANA_ADMIN_PASSWORD='test-password', GRAFANA_DB_PASSWORD='a'*64, EVEREST_ENDPOINT=external)
        command = compose_command() + ['--env-file', '.env.example', '-f', 'compose.yaml']
        for overlay in overlays:
            command += ['-f', f'compose.{overlay}.yaml']
        result = subprocess.run(command + ['config', '--no-env-resolution', '--format', 'json'], cwd=ROOT, env=env, text=True, capture_output=True, check=True)
        return json.loads(result.stdout)

    def test_all_overlay_combinations(self):
        for flags in itertools.product([False, True], repeat=4):
            overlays = [name for name, enabled in zip(('gpu','tls','monitoring','bench'), flags) if enabled]
            with self.subTest(overlays=overlays):
                services = self.config(overlays)['services']
                for name, service in services.items():
                    if name != 'edge':
                        self.assertFalse(service.get('ports'), name)
                self.assertEqual(services['web']['environment']['BACKEND_URL'], 'http://core:9006')
                self.assertEqual(services['migrate']['command'], ['meno-rag-migrate'])
                self.assertEqual(services['core']['depends_on']['migrate']['condition'], 'service_completed_successfully')
                self.assertTrue(next(v for v in services['core']['volumes'] if v['target']=='/app/data')['read_only'])
                self.assertEqual(services['core']['environment']['DATABASE_URL'], services['migrate']['environment']['DATABASE_URL'])

    def test_gpu_internal_auth_and_external_endpoint(self):
        services = self.config(['gpu'], 'http://everest.invalid:9022')['services']
        self.assertEqual(services['core']['environment']['VLLM_ENDPOINTS'], 'http://llm:8000,http://everest.invalid:9022')
        self.assertEqual(services['core']['environment']['OPENAI_API_KEY'], 'test-key')
        self.assertEqual(services['core']['environment']['EMBEDDER_API_KEY'], 'test-key')
        for name in ('llm','embedder','reranker'):
            self.assertIn('--api-key', services[name]['command'])
            self.assertEqual(services[name]['deploy']['resources']['reservations']['devices'][0]['capabilities'], ['gpu'])

    def test_shell_syntax(self):
        for name in ('compose.sh','deploy.sh','backup-db.sh','restore-db.sh'):
            subprocess.run(['bash','-n', str(ROOT/'scripts'/name)], check=True)

    def test_web_image_uses_existing_server_and_no_env_copy(self):
        dockerfile = (ROOT/'docker/web.Dockerfile').read_text()
        self.assertIn('COPY server.js', dockerfile)
        self.assertNotIn('COPY . .', dockerfile)
        self.assertIn('USER node', dockerfile)


if __name__ == '__main__':
    unittest.main()
