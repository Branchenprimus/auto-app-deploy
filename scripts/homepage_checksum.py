"""Keep Homepage's pod-template config checksum in sync with its ConfigMaps.

Homepage reads its mounted config and icons only at startup. Argo CD applies
ConfigMap changes, but only a changed pod template triggers a rollout. Both
renderers that rewrite platform/homepage.yaml call update_config_checksum().
"""
import hashlib
import json
from pathlib import Path
import re
import yaml

ANNOTATION = 'homepage.darwin-labs.org/config-checksum'
CONFIGMAPS = ('homepage', 'homepage-icons')


def config_checksum(text):
    payload = {}
    for document in yaml.safe_load_all(text):
        if document and document.get('kind') == 'ConfigMap' and document['metadata']['name'] in CONFIGMAPS:
            name = document['metadata']['name']
            payload[name] = {key: document.get(key) or {} for key in ('data', 'binaryData')}
    if set(payload) != set(CONFIGMAPS):
        raise ValueError('Homepage ConfigMaps not found')
    canonical = json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()
    return hashlib.sha256(canonical).hexdigest()


def update_config_checksum(manifest: Path):
    text = manifest.read_text(encoding='utf-8')
    checksum = config_checksum(text)
    sections = text.split('\n---\n')
    for index, section in enumerate(sections):
        document = yaml.safe_load(section)
        if not (document and document.get('kind') == 'Deployment' and document['metadata']['name'] == 'homepage'):
            continue
        # Edit lines in place so the hand-maintained Deployment keeps its layout.
        section = re.sub(r'\n      annotations:\n        ' + re.escape(ANNOTATION) + r': .*', '', section)
        section, count = re.subn(
            r'(\n  template:\n    metadata:\n)',
            r'\g<1>      annotations:\n        ' + ANNOTATION + ': ' + checksum + '\n',
            section,
            count=1,
        )
        if count != 1:
            raise ValueError('Homepage Deployment pod template metadata not found')
        sections[index] = section
        manifest.write_text('\n---\n'.join(sections), encoding='utf-8')
        return checksum
    raise ValueError('Homepage Deployment not found')
