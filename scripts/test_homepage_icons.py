"""Offline regression gate: every Homepage service uses a checked-in icon."""
import base64
from pathlib import Path
import struct
import subprocess
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / 'platform/homepage-icons'
REGISTRY = ROOT / 'chart/single-container-webapp/files/homepage-icons.yaml'


class HomepageIcons(unittest.TestCase):
    def registry(self):
        return yaml.safe_load(REGISTRY.read_text())

    def assert_local_asset(self, icon):
        self.assertIsInstance(icon, str)
        self.assertTrue(icon.startswith('/icons/'), icon)
        name = icon.removeprefix('/icons/')
        self.assertEqual(Path(name).name, name)
        image = (ASSETS / name).read_bytes()
        self.assertTrue(image.startswith(b'\x89PNG\r\n\x1a\n'), name)
        width, height = struct.unpack('>II', image[16:24])
        self.assertGreaterEqual(width, 32)
        self.assertGreaterEqual(height, 32)
        return image

    def test_every_app_has_local_registered_icon(self):
        registry = self.registry()
        for path in sorted((ROOT/'apps').glob('*.yaml')):
            app = yaml.safe_load(path.read_text())
            with self.subTest(app=app['name']):
                self.assert_local_asset(registry.get(app['name'], '/icons/app-default.png'))
        self.assert_local_asset('/icons/app-default.png')

    def test_all_manual_service_icons_are_local(self):
        docs = list(yaml.safe_load_all((ROOT/'platform/homepage.yaml').read_text()))
        config = next(d for d in docs if d.get('kind') == 'ConfigMap' and d['metadata']['name'] == 'homepage')
        for group in yaml.safe_load(config['data']['services.yaml']):
            for services in group.values():
                for service in services:
                    for name, values in service.items():
                        with self.subTest(service=name):
                            self.assert_local_asset(values['icon'])

    def test_mounted_configmap_matches_checked_in_assets(self):
        docs = list(yaml.safe_load_all((ROOT/'platform/homepage.yaml').read_text()))
        config = next(d for d in docs if d.get('kind') == 'ConfigMap' and d['metadata']['name'] == 'homepage-icons')
        self.assertFalse(config.get('data'))
        actual = config['binaryData']
        expected = {p.name for p in ASSETS.glob('*.png')}
        self.assertEqual(set(actual), expected)
        self.assertLess(sum(len(base64.b64decode(v)) for v in actual.values()), 800_000)
        for name, encoded in actual.items():
            self.assertEqual(base64.b64decode(encoded), (ASSETS/name).read_bytes())

    def test_chart_cannot_reintroduce_cross_origin_icons(self):
        registry = self.registry()
        for path in sorted((ROOT/'apps').glob('*.yaml')):
            app = yaml.safe_load(path.read_text())
            output = subprocess.check_output(['helm', 'template', app['name'], str(ROOT/'chart/single-container-webapp'), '-f', str(path)], text=True)
            ingress = next(d for d in yaml.safe_load_all(output) if d and d['kind'] == 'Ingress')
            with self.subTest(app=app['name']):
                self.assertEqual(ingress['metadata']['annotations']['gethomepage.dev/icon'], registry.get(app['name'], '/icons/app-default.png'))
        output = subprocess.check_output(['helm', 'template', 'future-app', str(ROOT/'chart/single-container-webapp'), '--set', 'name=future-app', '--set', 'homepage.icon=https://external.example/favicon.ico'], text=True)
        ingress = next(d for d in yaml.safe_load_all(output) if d and d['kind'] == 'Ingress')
        self.assertEqual(ingress['metadata']['annotations']['gethomepage.dev/icon'], '/icons/app-default.png')


if __name__ == '__main__':
    unittest.main()
