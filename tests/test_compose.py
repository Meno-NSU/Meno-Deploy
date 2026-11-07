import itertools
import json
import os
import subprocess
import tempfile
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
        for flags in itertools.product([False, True], repeat=5):
            overlays = [name for name, enabled in zip(('gpu','tls','monitoring','bench','indexing'), flags) if enabled]
            with self.subTest(overlays=overlays):
                services = self.config(overlays)['services']
                for name, service in services.items():
                    if name == 'qdrant' and 'indexing' in overlays:
                        self.assertEqual(len(service['ports']), 1)
                        self.assertEqual(service['ports'][0]['host_ip'], '127.0.0.1')
                        self.assertEqual(int(service['ports'][0]['published']), 6333)
                        self.assertEqual(service['ports'][0]['target'], 6333)
                        continue
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
        for name in ('compose.sh','deploy.sh','backup-db.sh','restore-db.sh','backend.sh'):
            subprocess.run(['bash','-n', str(ROOT/'scripts'/name)], check=True)

    def test_backend_init_is_private_and_preserves_existing_secrets(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / '.env.backend'
            env = dict(os.environ, BACKEND_ENV_FILE=str(destination))
            command = [str(ROOT/'scripts/backend.sh'), 'init']
            subprocess.run(command, env=env, check=True, capture_output=True)
            first = destination.read_bytes()
            subprocess.run(command, env=env, check=True, capture_output=True)
            self.assertEqual(destination.read_bytes(), first)
            self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
            settings = dict(line.split('=', 1) for line in first.decode().splitlines())
            for name in ('AUTH_JWT_SECRET', 'BACKEND_POSTGRES_PASSWORD', 'BENCH_API_TOKEN'):
                self.assertEqual(len(settings[name]), 64)
                int(settings[name], 16)

    def test_backend_bench_token_preserves_settings_and_existing_token(self):
        for value in (None, '', '""', "''", '# not configured'):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as directory:
                destination = Path(directory) / '.env.backend'
                prefix = 'AUTH_JWT_SECRET=existing-secret\nCUSTOM_SETTING=keep-me\n'
                token_line = '' if value is None else f'BENCH_API_TOKEN={value}\n'
                destination.write_text(prefix + token_line + 'DEFAULT_MODEL=meno-lite\n')
                env = dict(os.environ, BACKEND_ENV_FILE=str(destination))
                command = [str(ROOT/'scripts/backend.sh'), 'bench-token']
                first_run = subprocess.run(command, env=env, check=True, text=True, capture_output=True)
                first = destination.read_bytes()
                self.assertTrue(first.decode().startswith(prefix))
                self.assertIn('DEFAULT_MODEL=meno-lite\n', first.decode())
                token = next(line.split('=', 1)[1] for line in first.decode().splitlines()
                             if line.startswith('BENCH_API_TOKEN='))
                self.assertEqual(len(token), 64)
                self.assertNotIn(token, first_run.stdout + first_run.stderr)
                subprocess.run(command, env=env, check=True, capture_output=True)
                self.assertEqual(destination.read_bytes(), first)
                self.assertEqual(destination.stat().st_mode & 0o777, 0o600)

    def test_backend_bench_token_does_not_replace_populated_value(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / '.env.backend'
            original = 'AUTH_JWT_SECRET=keep-secret\nBENCH_API_TOKEN="keep-token" # existing\n'
            destination.write_text(original)
            result = subprocess.run([str(ROOT/'scripts/backend.sh'), 'bench-token'], check=True,
                                    text=True, capture_output=True,
                                    env=dict(os.environ, BACKEND_ENV_FILE=str(destination)))
            self.assertEqual(destination.read_text(), original)
            self.assertNotIn('keep-token', result.stdout + result.stderr)

    def test_backend_runs_isolated_with_native_models_and_existing_qdrant(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / '.env.backend'
            env = dict(os.environ, BACKEND_ENV_FILE=str(destination), COMPOSE_PROJECT_NAME='meno')
            command = [str(ROOT/'scripts/backend.sh')]
            subprocess.run(command + ['init'], env=env, check=True, capture_output=True)
            result = subprocess.run(command + ['config', '--format', 'json'], env=env, cwd=ROOT,
                                    text=True, capture_output=True, check=True)
            config = json.loads(result.stdout)
        self.assertEqual(config['name'], 'meno-ragu-backend')
        services = config['services']
        self.assertEqual(set(services), {'core', 'migrate', 'postgres', 'redis'})
        core, migrate = services['core'], services['migrate']
        for service in (core, migrate):
            self.assertEqual(service['network_mode'], 'host')
            self.assertFalse(service.get('ports'))
            self.assertFalse(service.get('networks'))
            environment = service['environment']
            self.assertEqual(environment['APP_HOST'], '127.0.0.1')
            self.assertEqual(environment['APP_PORT'], '9007')
            self.assertIn('@127.0.0.1:15432/meno', environment['DATABASE_URL'])
            self.assertEqual(environment['REDIS_URL'], 'redis://127.0.0.1:16379/0')
            self.assertEqual(environment['QDRANT_URL'], 'http://127.0.0.1:6333')
            self.assertEqual(environment['DEFAULT_MODEL'], 'meno-lite')
            self.assertNotIn('RAG_REWRITE_RERANK_MODEL', environment)
            self.assertEqual(environment['VLLM_ENDPOINTS'], 'http://127.0.0.1:9020,http://everest.nsu.ru:9022')
            self.assertEqual(environment['EMBEDDER_URL'], 'http://127.0.0.1:8001/v1')
            self.assertEqual(environment['ENGINE_RERANKER_URL'], 'http://127.0.0.1:8002/v1')
            resources = next(volume for volume in service['volumes'] if volume['target'] == '/app/data')
            self.assertTrue(resources['read_only'])
            self.assertFalse(resources['bind']['create_host_path'])
        self.assertEqual(core['environment']['DATABASE_URL'], migrate['environment']['DATABASE_URL'])
        self.assertEqual(core['depends_on']['migrate']['condition'], 'service_completed_successfully')
        for name, port in (('postgres', 15432), ('redis', 16379)):
            self.assertEqual(len(services[name]['ports']), 1)
            self.assertEqual(services[name]['ports'][0]['host_ip'], '127.0.0.1')
            self.assertEqual(int(services[name]['ports'][0]['published']), port)
        for volume in config['volumes'].values():
            self.assertTrue(volume['name'].startswith('meno-ragu-backend_'))

    def test_web_image_uses_existing_server_and_no_env_copy(self):
        dockerfile = (ROOT/'docker/web.Dockerfile').read_text()
        self.assertIn('COPY server.js', dockerfile)
        self.assertNotIn('COPY . .', dockerfile)
        self.assertIn('USER node', dockerfile)


if __name__ == '__main__':
    unittest.main()
