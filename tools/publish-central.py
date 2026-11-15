#!/usr/bin/env python3
"""Sign the verified SDK payload and validate/publish it through the Central Portal API."""
import argparse
import base64
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

API = 'https://central.sonatype.com/api/v1/publisher'
GROUP_PATH = 'io/github/gkobakhidze/e2e-studio-sdk'


def gpg(args, *, payload=None, env=None):
    result = subprocess.run(['gpg', '--batch', '--yes', *args], input=payload, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError('GPG operation failed; no signing credential was logged')
    return result.stdout


def bundle(root, destination, env):
    version = (root / 'VERSION').read_text().strip()
    manifest = json.loads((root / 'sdk-manifest.json').read_text())
    if version != manifest['version']:
        raise ValueError('SDK version and manifest differ')
    for name, checksum in manifest['files'].items():
        if hashlib.sha256((root / name).read_bytes()).hexdigest() != checksum:
            raise ValueError('Staged SDK checksum mismatch: ' + name)
    source = root / 'maven' / GROUP_PATH / version
    names = [f'e2e-studio-sdk-{version}{suffix}' for suffix in ('.aar', '.pom', '-sources.jar', '-javadoc.jar')]
    with tempfile.TemporaryDirectory(prefix='central-payload-') as folder:
        directory = Path(folder) / GROUP_PATH / version
        directory.mkdir(parents=True)
        for name in names:
            target = directory / name
            shutil.copy2(source / name, target)
            password = env.get('GPG_SIGNING_PASSWORD', '').encode()
            gpg(['--pinentry-mode', 'loopback', '--passphrase-fd', '0', '--armor', '--detach-sign', str(target)],
                payload=password, env=env)
            gpg(['--verify', str(target) + '.asc', str(target)], env=env)
            for algorithm in ('md5', 'sha1', 'sha256', 'sha512'):
                target.with_name(name + '.' + algorithm).write_text(hashlib.new(algorithm, target.read_bytes()).hexdigest() + '\n')
        destination.parent.mkdir(parents=True, exist_ok=True)
        with ZipFile(destination, 'w', compression=ZIP_DEFLATED) as archive:
            for path in sorted(Path(folder).rglob('*')):
                if path.is_file():
                    archive.write(path, path.relative_to(folder).as_posix())
    return version


def request(path, method, credential, data=b'', content_type=None):
    headers = {'Authorization': 'Bearer ' + credential}
    if content_type:
        headers['Content-Type'] = content_type
    req = urllib.request.Request(API + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=120) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        raise RuntimeError(f'Central API returned HTTP {error.code}; publisher credentials were not logged') from None


def deploy(archive, version, publish):
    username = os.environ.get('MAVEN_CENTRAL_USERNAME')
    password = os.environ.get('MAVEN_CENTRAL_PASSWORD')
    if not username or not password:
        raise ValueError('MAVEN_CENTRAL_USERNAME and MAVEN_CENTRAL_PASSWORD secrets are required')
    credential = base64.b64encode((username + ':' + password).encode()).decode()
    boundary = 'sdk-' + uuid.uuid4().hex
    data = (f'--{boundary}\r\nContent-Disposition: form-data; name="bundle"; filename="sdk-{version}.zip"\r\n'
            'Content-Type: application/octet-stream\r\n\r\n').encode() + archive.read_bytes() + f'\r\n--{boundary}--\r\n'.encode()
    query = urllib.parse.urlencode({'name': f'E2E Studio SDK {version}', 'publishingType': 'USER_MANAGED'})
    deployment = request('/upload?' + query, 'POST', credential, data, 'multipart/form-data; boundary=' + boundary).decode().strip().strip('"')
    uuid.UUID(deployment)
    print('Central deployment:', deployment, flush=True)
    previous = None
    published = False
    for _ in range(180):
        status = json.loads(request('/status?' + urllib.parse.urlencode({'id': deployment}), 'POST', credential))
        state = status.get('deploymentState')
        if state != previous:
            print('Central state:', state, flush=True)
            previous = state
        if state == 'FAILED':
            print(json.dumps(status.get('errors', {}), indent=2))
            raise RuntimeError('Central validation failed')
        if state == 'VALIDATED':
            if not publish:
                print('Validation passed. Publication was not requested.', flush=True)
                return
            if not published:
                request('/deployment/' + deployment, 'POST', credential)
                published = True
        if state == 'PUBLISHED':
            print('Published: io.github.gkobakhidze:e2e-studio-sdk:' + version, flush=True)
            return
        time.sleep(5)
    raise RuntimeError('Central processing did not finish within the polling window; inspect the deployment before retrying')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--upload', action='store_true')
    parser.add_argument('--publish', action='store_true')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='sdk-gpg-') as folder:
        env = os.environ.copy()
        if env.get('GPG_SIGNING_KEY'):
            Path(folder).chmod(0o700)
            env['GNUPGHOME'] = folder
            gpg(['--import'], payload=env['GPG_SIGNING_KEY'].encode(), env=env)
        version = bundle(args.root.resolve(), args.output.resolve(), env)
        print('Signed and verified SDK bundle:', args.output, flush=True)
        if args.upload or args.publish:
            deploy(args.output, version, args.publish)


if __name__ == '__main__':
    main()
