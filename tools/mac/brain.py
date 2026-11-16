#!/usr/bin/env python3
"""Shared AI brain for macOS: syncs the config folder, memory and vault between machines over
Tailscale with Syncthing. Mirrors the Windows tools (install, invite, accept, add-peer,
connect-clients, register-hooks, check). Python 3.8+, standard library only.

  python3 brain.py install --work-folder ~/Work                    first machine
  python3 brain.py install --work-folder ~/Work --invite AIB1-...  join an existing brain
  python3 brain.py invite | accept | add-peer | connect-clients | register-hooks | usage-guard | check
Test options: --home-root DIR, and for install --gui-port --listen-port --no-service --syncthing --wait-minutes.
"""
import argparse
import base64
import datetime
import hashlib
import json
import os
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zipfile
import xml.etree.ElementTree as ET

try:
    import qr  # optional, same folder
except Exception:  # noqa: BLE001
    qr = None

HERE = os.path.dirname(os.path.abspath(__file__))
IS_MAC = sys.platform == 'darwin'
IS_WIN = sys.platform == 'win32'
FOLDER_IDS = ('ai-claude', 'ai-memory', 'ai-brain')
DEVICE_RX = re.compile(r'^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$')
TS_RX = re.compile(r'^100\.\d+\.\d+\.\d+$')


class BrainError(Exception):
    pass


def step(msg):
    print('\n== ' + msg)


def now(fmt):
    return datetime.datetime.now().strftime(fmt)


# ---- paths and edition -------------------------------------------------------

def tools_dir():
    """Folder that holds edition.json (tools/ in a built kit, _tools/ in the vault)."""
    for d in (os.path.dirname(HERE), HERE):
        if os.path.isfile(os.path.join(d, 'edition.json')):
            return d
    raise BrainError('Missing edition.json. Use a built kit (dist), not the source folder.')


def get_edition():
    with open(os.path.join(tools_dir(), 'edition.json'), encoding='utf-8-sig') as f:
        return json.load(f)


class Paths(object):
    def __init__(self, home_root=None):
        self.ed = get_edition()
        self.home = os.path.abspath(home_root) if home_root else os.path.expanduser('~')
        self.config = os.path.join(self.home, '.claude')
        self.vault = os.path.join(self.home, self.ed['vaultName'])
        self.state = os.path.join(self.home, self.ed['stateDirName'])
        self.st_home = os.path.join(self.state, 'syncthing')
        self.logs = os.path.join(self.state, 'logs')
        self.bin = os.path.join(self.state, 'bin')
        self.backups = os.path.join(self.home, self.ed['stateDirName'] + '-backup')
        self.brain_json = os.path.join(self.state, 'brain.json')


def memory_dir_for(config_dir, work_folder):
    """Same encoding as the Windows tools: every non letter/digit becomes '-' (per UTF-16 unit)."""
    full = os.path.abspath(work_folder).rstrip('\\' if IS_WIN else '/')
    enc = ''
    for ch in full:
        if re.match(r'[A-Za-z0-9]', ch):
            enc += ch
        else:
            enc += '--' if ord(ch) > 0xFFFF else '-'
    return os.path.join(config_dir, 'projects', enc, 'memory')


def write_utf8(path, text):
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    with open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(text)


def read_text(path):
    with open(path, encoding='utf-8-sig', newline='') as f:
        return f.read()


def copy_if_missing(src, dst):
    if os.path.lexists(dst):
        return False
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(src, dst)
    return True


def read_brain_json(path):
    if os.path.isfile(path):
        return json.loads(read_text(path))
    return None


def config_ignore(ed):
    return '\n'.join([
        "// %s: sync knowledge only. Never sync sign-ins, settings or conversation history." % ed['vaultName'],
        '(?d)/hooks/state', '(?d)**/__pycache__', '!/CLAUDE.md', '!/rules', '!/skills', '!/agents',
        '!/commands', '!/handoffs', '!/hooks', '*', ''])


def vault_ignore(ed):
    return '\n'.join([
        "// %s: these junctions point into the config folder, which syncs on its own." % ed['vaultName'],
        '/config/rules', '/config/skills', '/config/agents', '/config/commands',
        '/config/CLAUDE (read-only copy).md', '/memory', '/handoffs',
        '/.obsidian/workspace*.json', '/.trash', ''])


# ---- links (symlinks on macOS; junction fallback on Windows for tests) ---------

def is_link(p):
    if os.path.islink(p):
        return True
    if IS_WIN and os.path.lexists(p):
        try:
            return bool(os.lstat(p).st_file_attributes & 0x400)
        except (AttributeError, OSError):
            return False
    return False


def link_target(p):
    t = os.readlink(p)
    if t.startswith('\\\\?\\'):
        t = t[4:]
    return t


def remove_link(p):
    try:
        os.unlink(p)
    except (PermissionError, IsADirectoryError, OSError):
        os.rmdir(p)


def make_link(path, target):
    if IS_WIN:
        try:
            os.symlink(target, path, target_is_directory=True)
            return
        except OSError:
            r = subprocess.run(['cmd', '/c', 'mklink', '/J', path, target], capture_output=True)
            if r.returncode != 0:
                raise BrainError('Cannot create link %s: %s' % (path, r.stderr.decode(errors='replace')))
            return
    os.symlink(target, path)


def set_link(path, target):
    """Creates a symlink; leaves real folders and links pointing elsewhere untouched."""
    if not os.path.exists(target):
        print('  skip   %s (target missing: %s)' % (path, target))
        return
    if os.path.lexists(path):
        if is_link(path):
            if os.path.normcase(os.path.normpath(link_target(path))) == os.path.normcase(os.path.normpath(target)):
                return
            print('WARNING: %s is a link to %s; left unchanged.' % (path, link_target(path)))
            return
        print('WARNING: %s is a real folder or file; left unchanged.' % path)
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    make_link(path, target)
    print('  link   %s -> %s' % (path, target))


# ---- Tailscale and Syncthing binaries ------------------------------------------------

def get_tailscale_ip():
    exe = shutil.which('tailscale')
    if not exe:
        for c in ('/Applications/Tailscale.app/Contents/MacOS/Tailscale',
                  os.path.join(os.environ.get('ProgramFiles', ''), 'Tailscale', 'tailscale.exe')):
            if os.path.isfile(c):
                exe = c
                break
    if not exe:
        raise BrainError('Tailscale is not installed. Install it, sign in, then run this again.')
    r = subprocess.run([exe, 'ip', '-4'], capture_output=True, text=True)
    lines = [x.strip() for x in r.stdout.splitlines() if x.strip()]
    if not lines:
        raise BrainError('Tailscale is not connected. Sign in, then run this again.')
    if not TS_RX.match(lines[0]):
        raise BrainError('Unexpected Tailscale address: %s' % lines[0])
    return lines[0]


def http_get(url, timeout=60):
    req = urllib.request.Request(url, headers={'User-Agent': 'ai-brain-kit'})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def download_syncthing(bin_dir):
    step('Download Syncthing')
    rel = json.loads(http_get('https://api.github.com/repos/syncthing/syncthing/releases/latest').decode('utf-8'))
    assets = {a['name']: a['browser_download_url'] for a in rel.get('assets', [])}
    pick = [n for n in assets if re.match(r'^syncthing-macos-universal-v[\d.]+\.zip$', n)]
    if not pick:
        arch = 'arm64' if platform.machine().lower() in ('arm64', 'aarch64') else 'amd64'
        pick = [n for n in assets if re.match(r'^syncthing-macos-%s-v[\d.]+\.zip$' % arch, n)]
    if not pick:
        raise BrainError('No macOS Syncthing build found in the latest release.')
    name = pick[0]
    sums = assets.get('sha256sum.txt.asc')
    if not sums:
        raise BrainError('The release has no sha256sum.txt.asc; refusing to install an unverified download.')
    want = None
    for line in http_get(sums).decode('utf-8', 'replace').splitlines():
        m = re.match(r'^([0-9a-fA-F]{64})\s+\*?(\S+)\s*$', line.strip())
        if m and m.group(2) == name:
            want = m.group(1).lower()
    if not want:
        raise BrainError('No checksum line for %s; aborting.' % name)
    data = http_get(assets[name], timeout=300)
    got = hashlib.sha256(data).hexdigest()
    if got != want:
        raise BrainError('Checksum mismatch for %s; aborting.' % name)
    print('  checksum ok (%s)' % name)
    os.makedirs(bin_dir, exist_ok=True)
    tmp = os.path.join(bin_dir, name)
    with open(tmp, 'wb') as f:
        f.write(data)
    dst = os.path.join(bin_dir, 'syncthing')
    with zipfile.ZipFile(tmp) as z:
        # The archive also holds etc/ init scripts named 'syncthing'; the program sits at '<top folder>/syncthing'.
        member = sorted((m for m in z.namelist() if m.rsplit('/', 1)[-1] == 'syncthing' and not m.endswith('/')),
                        key=lambda m: m.count('/'))
        if not member:
            raise BrainError('The archive has no syncthing binary.')
        with z.open(member[0]) as src, open(dst, 'wb') as out:
            shutil.copyfileobj(src, out)
    os.remove(tmp)
    if not is_macho(dst):
        os.remove(dst)
        raise BrainError('The file taken from %s is not a macOS program (%s); aborting.' % (name, member[0]))
    os.chmod(dst, 0o755)
    subprocess.run(['xattr', '-d', 'com.apple.quarantine', dst], capture_output=True)  # ignore failure
    return dst


MACHO_MAGIC = (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf', b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe')


def is_macho(path):
    """True when the file starts with a Mach-O or universal-binary header."""
    try:
        with open(path, 'rb') as f:
            return f.read(4) in MACHO_MAGIC
    except OSError:
        return False


def find_syncthing(P, explicit=None):
    if explicit:
        if not os.path.isfile(explicit):
            raise BrainError('Syncthing not found at %s' % explicit)
        return explicit
    cand = os.path.join(P.bin, 'syncthing' + ('.exe' if IS_WIN else ''))
    if os.path.isfile(cand):
        if not IS_MAC or is_macho(cand):
            return cand
        # A broken earlier download (1.2.0 could save a shell script here): replace it.
        print('  %s is not a macOS program; downloading again' % cand)
        os.remove(cand)
        return download_syncthing(P.bin)
    exe = shutil.which('syncthing')
    if exe:
        return exe
    for c in ('/opt/homebrew/bin/syncthing', '/usr/local/bin/syncthing'):
        if os.path.isfile(c):
            return c
    if IS_MAC:
        return download_syncthing(P.bin)
    raise BrainError('Syncthing is not installed.')


# ---- Syncthing REST --------------------------------------------------------------------

class St(object):
    def __init__(self, st_home, gui_port):
        cfg = os.path.join(st_home, 'config.xml')
        if not os.path.isfile(cfg):
            raise BrainError('No Syncthing config at %s. Run install first.' % cfg)
        self.key = ET.parse(cfg).getroot().find('gui').find('apikey').text
        self.base = 'http://127.0.0.1:%d' % gui_port

    def call(self, method, route, body=None, timeout=15):
        data = None
        headers = {'X-API-Key': self.key}
        if body is not None:
            data = json.dumps(body).encode('utf-8')
            headers['Content-Type'] = 'application/json; charset=utf-8'
        req = urllib.request.Request(self.base + route, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                raw = r.read()
        except urllib.error.HTTPError as e:
            raise BrainError('Syncthing %s %s failed: %s %s' % (method, route, e.code, e.read()[:200]))
        return json.loads(raw.decode('utf-8')) if raw.strip() else None

    def my_id(self):
        return self.call('GET', '/rest/system/status')['myID']


def gui_up(port):
    try:
        urllib.request.urlopen('http://127.0.0.1:%d/rest/noauth/health' % port, timeout=2).read()
        return True
    except Exception:  # noqa: BLE001
        return False


def connect_api(P, gui_port=None):
    B = read_brain_json(P.brain_json)
    port = gui_port or (int(B['guiPort']) if B and B.get('guiPort') else 8384)
    return St(P.st_home, port), B, port


# ---- Device ID and invite code ----------------------------------------------------------

LUHN = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'


def luhn32(s):
    factor, total = 1, 0
    for ch in s:
        addend = factor * LUHN.index(ch)
        factor = 1 if factor == 2 else 2
        total += addend // 32 + addend % 32
    return LUHN[(32 - total % 32) % 32]


def device_id_to_raw(dev):
    s = dev.replace('-', '')
    if len(s) != 56:
        raise BrainError('Not a Syncthing Device ID.')
    data = ''
    for i in range(0, 56, 14):
        chunk = s[i:i + 14]
        if luhn32(chunk[:13]) != chunk[13]:
            raise BrainError('Device ID check character is wrong.')
        data += chunk[:13]
    return base64.b32decode(data + '====')


def raw_to_device_id(raw):
    data = base64.b32encode(raw).decode('ascii')[:52]
    s = ''.join(data[i:i + 13] + luhn32(data[i:i + 13]) for i in range(0, 52, 13))
    return '-'.join(s[i:i + 7] for i in range(0, 56, 7))


def device_id_from_cert(st_home):
    """Device ID = SHA-256 of the certificate DER, shown in Syncthing's base-32 form."""
    pem = read_text(os.path.join(st_home, 'cert.pem'))
    m = re.search(r'-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----', pem, re.S)
    if not m:
        raise BrainError('No certificate in %s.' % st_home)
    der = base64.b64decode(''.join(m.group(1).split()))
    return raw_to_device_id(hashlib.sha256(der).digest())


def crc16_ccitt(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def kit_tag(ed):
    return hashlib.sha256(ed['kitName'].encode('utf-8')).digest()[0]


def make_invite(ed, device_id, ip, port):
    p = bytearray([1]) + bytearray(device_id_to_raw(device_id))
    p += bytearray(int(x) for x in ip.split('.'))
    p += bytearray([(port >> 8) & 255, port & 255, kit_tag(ed)])
    p += bytearray([(crc16_ccitt(bytes(p)) >> 8) & 255, crc16_ccitt(bytes(p)) & 255])
    s = base64.b32encode(bytes(p)).decode('ascii').rstrip('=')
    return 'AIB1-' + '-'.join(s[i:i + 4] for i in range(0, len(s), 4))


def decode_invite(ed, code):
    s = re.sub(r'[\s-]', '', code.upper())
    if not s.startswith('AIB1'):
        raise BrainError('This is not an invite code.')
    s = s[4:]
    try:
        s += '=' * (-len(s) % 8)
        b = base64.b32decode(s)
    except Exception:  # noqa: BLE001
        raise BrainError('The invite code has characters that do not belong. Check it and try again.')
    if len(b) != 42 or b[0] != 1:
        raise BrainError('The invite code is incomplete or from a different version.')
    if crc16_ccitt(b[:40]) != (b[40] << 8 | b[41]):
        raise BrainError('The invite code has a typo (check failed). Check it and try again.')
    if b[39] != kit_tag(ed):
        raise BrainError('This invite is for a different kit')
    return {'id': raw_to_device_id(b[1:33]), 'ip': '.'.join(str(x) for x in b[33:37]),
            'port': b[37] << 8 | b[38]}


def show_invite(P):
    B = read_brain_json(P.brain_json)
    if not B:
        raise BrainError('No %s. Run install first.' % P.brain_json)
    dev = device_id_from_cert(P.st_home)
    ip = get_tailscale_ip()
    code = make_invite(P.ed, dev, ip, int(B['listenPort']))
    print('Invite code for this machine:\n\n  %s\n' % code)
    if qr:
        try:
            qr.print_qr(code)
        except Exception as e:  # noqa: BLE001
            print('(QR not shown: %s)' % e)
    print('On the new machine run install with --invite <code>, then run accept here.')
    return code


# ---- pairing -------------------------------------------------------------------------------

def add_peer(st, peer_id, peer_ip, peer_name, peer_port=22000):
    if not DEVICE_RX.match(peer_id):
        raise BrainError('PeerId is not a Syncthing Device ID.')
    if not TS_RX.match(peer_ip):
        raise BrainError("PeerIp must be a Tailscale IPv4 address (100.x.y.z).")
    my = st.my_id()
    if peer_id == my:
        raise BrainError("PeerId is this machine's own ID.")
    known = [d['deviceID'] for d in st.call('GET', '/rest/config/devices')]
    if peer_id not in known:
        st.call('POST', '/rest/config/devices', {
            'deviceID': peer_id, 'name': peer_name, 'addresses': ['tcp://%s:%d' % (peer_ip, peer_port)],
            'autoAcceptFolders': False, 'introducer': False})
        print('Added %s (%s)' % (peer_name, peer_ip))
    else:
        print('%s is already known' % peer_name)
    for fid in FOLDER_IDS:
        cur = st.call('GET', '/rest/config/folders/' + fid)
        if peer_id not in [d['deviceID'] for d in cur['devices']]:
            cur['devices'].append({'deviceID': peer_id})
            st.call('PUT', '/rest/config/folders/' + fid, cur)
            print('Shared %s with %s' % (fid, peer_name))
        else:
            print('%s already shared with %s' % (fid, peer_name))
    return my


def cmd_add_peer(a):
    P = Paths(a.home_root)
    st, _, _ = connect_api(P)
    my = add_peer(st, a.peer_id, a.peer_ip, a.peer_name, a.peer_port)
    print('\nDevice ID of this machine: %s' % my)
    try:
        print('Tailscale IP: %s' % get_tailscale_ip())
    except BrainError:
        pass


def cmd_accept(a):
    P = Paths(a.home_root)
    st, _, _ = connect_api(P)
    deadline = time.time() + max(0, a.wait_seconds)
    while True:
        pend = st.call('GET', '/rest/cluster/pending/devices') or {}
        offer = {}
        for did, info in pend.items():
            host = (info.get('address') or '').rsplit(':', 1)[0].strip('[]')
            if TS_RX.match(host):
                offer[did] = (info.get('name') or 'peer', host)
        if offer or time.time() >= deadline:
            break
        time.sleep(2)
    if not offer:
        print('No new machines are waiting.')
        return
    for did, (name, ip) in offer.items():
        if not a.yes:
            ans = input('Add device %s (%s, %s)? [y/N] ' % (name, did, ip)).strip().lower()
            if ans not in ('y', 'yes'):
                print('Skipped %s' % name)
                continue
        add_peer(st, did, ip, name, a.peer_port)


# ---- install ------------------------------------------------------------------------------------

def start_detached(exe, args, cwd, log_path, env):
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    log = open(log_path, 'ab')
    kw = {}
    if IS_WIN:
        kw['creationflags'] = 0x00000008 | 0x00000200 | 0x08000000  # detached, new group, no window
    else:
        kw['start_new_session'] = True
    subprocess.Popen([exe] + args, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log, **kw)


def service_label(ed):
    return 'io.github.%s.syncthing' % ed['kitName']


def install_service(P, exe, serve_args):
    if not IS_MAC:
        raise BrainError('The launchd service needs macOS. Use --no-service here.')
    label = service_label(P.ed)
    plist_dir = os.path.join(P.home, 'Library', 'LaunchAgents')
    os.makedirs(plist_dir, exist_ok=True)
    os.makedirs(P.logs, exist_ok=True)
    path = os.path.join(plist_dir, label + '.plist')
    with open(path, 'wb') as f:
        plistlib.dump({
            'Label': label, 'ProgramArguments': [exe] + serve_args, 'RunAtLoad': True, 'KeepAlive': True,
            'EnvironmentVariables': {'STNODEFAULTFOLDER': '1'}, 'WorkingDirectory': P.st_home,
            'StandardOutPath': os.path.join(P.logs, 'syncthing.out.log'),
            'StandardErrorPath': os.path.join(P.logs, 'syncthing.err.log')}, f)
    dom = 'gui/%d' % os.getuid()
    subprocess.run(['launchctl', 'bootout', '%s/%s' % (dom, label)], capture_output=True)
    r = subprocess.run(['launchctl', 'bootstrap', dom, path], capture_output=True, text=True)
    if r.returncode != 0:
        r2 = subprocess.run(['launchctl', 'load', '-w', path], capture_output=True, text=True)
        if r2.returncode != 0:
            raise BrainError('launchctl failed: %s %s' % (r.stderr.strip(), r2.stderr.strip()))
    print('  service %s (%s)' % (label, path))


def cmd_install(a):
    P = Paths(a.home_root)
    ed = P.ed
    work = os.path.abspath(os.path.expanduser(a.work_folder))
    peer_id, peer_ip, peer_port, peer_name = a.peer_id, a.peer_ip, a.peer_port, a.peer_name
    if a.invite:
        inv = decode_invite(ed, a.invite)
        peer_id, peer_ip, peer_port = inv['id'], inv['ip'], inv['port']
    join = bool(peer_id)
    step('Check prerequisites')
    if not os.path.isdir(work):
        raise BrainError('WorkFolder does not exist: %s\nUse the folder you already open your AI assistant in. '
                         'If the path is right and the folder is new, create it first, then run this again.' % work)
    ts = get_tailscale_ip()
    if join:
        if not DEVICE_RX.match(peer_id):
            raise BrainError('PeerId is not a Syncthing Device ID.')
        if not (peer_ip and TS_RX.match(peer_ip)):
            raise BrainError("PeerIp must be the other machine's Tailscale IPv4 address (100.x.y.z).")
    exe = find_syncthing(P, a.syncthing)
    mem = memory_dir_for(P.config, work)
    print('Mode: %s' % ('join an existing brain' if join else 'first machine'))
    print('Vault: %s' % P.vault)
    print('Memory for %s: %s' % (work, mem))

    marker = os.path.join(P.state, 'installed.txt')
    if join and not os.path.isfile(marker):
        step('Prepare this machine to receive the brain')
        # Files this installer writes itself (or Finder adds) do not count: a failed run can be re-run.
        own = ('.stignore', '.stfolder', '.DS_Store')
        if os.path.isdir(P.vault) and [n for n in os.listdir(P.vault) if n not in own]:
            raise BrainError('Vault folder is not empty: %s. Move it away first; joining needs an empty vault.' % P.vault)
        bk = os.path.join(P.backups, 'before-join-' + now('%Y-%m-%d_%H%M%S'))
        moved = 0
        for n in ('CLAUDE.md', 'rules', 'skills', 'agents', 'commands', 'handoffs', 'hooks'):
            src = os.path.join(P.config, n)
            if os.path.lexists(src):
                os.makedirs(bk, exist_ok=True)
                shutil.move(src, os.path.join(bk, n))
                moved += 1
        if os.path.isdir(mem) and os.listdir(mem):
            os.makedirs(bk, exist_ok=True)
            shutil.move(mem, os.path.join(bk, 'memory'))
            moved += 1
        if moved:
            print('Moved %d existing item(s) to %s. Merge anything you need back in after the first sync.' % (moved, bk))

    step('Create folders')
    for d in (P.config, P.vault, mem, P.st_home, P.logs):
        os.makedirs(d, exist_ok=True)

    if not join:
        step('Lay down empty templates (existing files are kept)')
        tdir = os.path.join(os.path.dirname(tools_dir()), 'templates')
        if not os.path.isdir(tdir):
            tdir = os.path.join(tools_dir(), 'templates')
        for sub, dst in (('vault', P.vault), ('config', P.config), ('memory', mem)):
            root = os.path.join(tdir, sub)
            for dp, _dn, fns in os.walk(root):
                for fn in fns:
                    s = os.path.join(dp, fn)
                    rel = os.path.relpath(s, root)
                    if copy_if_missing(s, os.path.join(dst, rel)):
                        print('  new    %s' % rel)
        tools_dst = os.path.join(P.vault, '_tools')
        os.makedirs(tools_dst, exist_ok=True)
        if os.path.abspath(tools_dir()) != os.path.abspath(tools_dst):
            shutil.copytree(tools_dir(), tools_dst, dirs_exist_ok=True,
                            ignore=shutil.ignore_patterns('__pycache__', 'templates'))
        tpl_dst = os.path.join(tools_dst, 'templates')
        if not os.path.exists(tpl_dst) and os.path.isdir(tdir):
            shutil.copytree(tdir, tpl_dst)
        print('  tools  -> %s' % tools_dst)

    step('Write sync filters')
    write_utf8(os.path.join(P.config, '.stignore'), config_ignore(ed))
    write_utf8(os.path.join(P.vault, '.stignore'), vault_ignore(ed))

    step('Start a dedicated Syncthing instance')
    env = dict(os.environ, STNODEFAULTFOLDER='1')
    if not os.path.isfile(os.path.join(P.st_home, 'config.xml')):
        subprocess.run([exe, 'generate', '--home=' + P.st_home], env=env, capture_output=True, check=True)
    serve_args = ['serve', '--no-browser', '--home=' + P.st_home, '--gui-address=127.0.0.1:%d' % a.gui_port]
    if not gui_up(a.gui_port):
        if a.no_service:
            start_detached(exe, serve_args, P.st_home, os.path.join(P.logs, 'syncthing.log'), env)
        else:
            install_service(P, exe, serve_args)
        for _ in range(30):
            if gui_up(a.gui_port):
                break
            time.sleep(1)
        if not gui_up(a.gui_port):
            raise BrainError('Syncthing did not start on port %d. See %s.' % (a.gui_port, P.st_home))
    st = St(P.st_home, a.gui_port)
    try:
        my = st.my_id()
    except BrainError:
        raise BrainError('Another Syncthing instance already uses port %d. Stop it or pass --gui-port.' % a.gui_port)

    step('Allow traffic over Tailscale only')
    st.call('PATCH', '/rest/config/options', {
        'listenAddresses': ['tcp://%s:%d' % (ts, a.listen_port)],
        'globalAnnounceEnabled': False, 'localAnnounceEnabled': False, 'relaysEnabled': False,
        'natEnabled': False, 'urAccepted': -1, 'crashReportingEnabled': False,
        'autoUpgradeIntervalH': 0, 'startBrowser': False})
    st.call('PATCH', '/rest/config/gui', {'address': '127.0.0.1:%d' % a.gui_port})

    if join:
        known = [d['deviceID'] for d in st.call('GET', '/rest/config/devices')]
        if peer_id not in known:
            st.call('POST', '/rest/config/devices', {
                'deviceID': peer_id, 'name': peer_name, 'addresses': ['tcp://%s:%d' % (peer_ip, peer_port)],
                'autoAcceptFolders': False, 'introducer': False})
            print('  added  %s (%s)' % (peer_name, peer_ip))

    step('Share the three folders')
    folders = [('ai-claude', 'AI - config', P.config), ('ai-memory', 'AI - memory', mem),
               ('ai-brain', 'AI - vault', P.vault)]
    have = {f['id']: f for f in st.call('GET', '/rest/config/folders')}
    for fid, label, path in folders:
        cur = have.get(fid)
        if cur:
            if os.path.normcase(os.path.realpath(cur['path'])) != os.path.normcase(os.path.realpath(path)):
                raise BrainError('Folder %s already points at %s, not %s. Check before running again.' % (fid, cur['path'], path))
            if join and peer_id not in [d['deviceID'] for d in cur['devices']]:
                cur['devices'].append({'deviceID': peer_id})
                st.call('PUT', '/rest/config/folders/' + fid, cur)
            print('  ok     ' + fid)
        else:
            devs = [{'deviceID': my}] + ([{'deviceID': peer_id}] if join else [])
            st.call('POST', '/rest/config/folders', {
                'id': fid, 'label': label, 'path': path, 'type': 'sendreceive', 'devices': devs,
                'fsWatcherEnabled': True, 'rescanIntervalS': 300,
                'versioning': {'type': 'trashcan', 'params': {'cleanoutDays': '30'}}})
            print('  new    %s -> %s' % (fid, path))

    write_utf8(P.brain_json, json.dumps({
        'workFolder': work, 'memoryDir': mem, 'guiPort': a.gui_port, 'listenPort': a.listen_port,
        'edition': ed['id'], 'kitVersion': ed['version']}, indent=2))
    write_utf8(marker, 'installed %s\n' % now('%Y-%m-%dT%H:%M:%S'))

    cc = argparse.Namespace(home_root=a.home_root, dry_run=False)
    if not join:
        step('Connect the vault and installed AI clients')
        cmd_connect_clients(cc)
    elif a.wait_minutes > 0:
        step('Wait up to %d minutes for the first sync' % a.wait_minutes)
        print('On the other machine, run accept (or add-peer) so it adds this one.')
        print('  Device ID:    %s' % my)
        print('  Tailscale IP: %s   (port %d)' % (ts, a.listen_port))
        need = [os.path.join(P.vault, 'AGENTS.md'), os.path.join(P.config, 'CLAUDE.md'), os.path.join(mem, 'MEMORY.md')]
        deadline = time.time() + a.wait_minutes * 60
        ready = False
        while time.time() < deadline:
            files_ok = all(os.path.exists(p) for p in need)
            idle = True
            for fid in FOLDER_IDS:
                try:
                    s = st.call('GET', '/rest/db/status?folder=' + fid)
                    if s['state'] != 'idle' or s['needFiles'] > 0:
                        idle = False
                except BrainError:
                    idle = False
            if files_ok and idle:
                ready = True
                break
            time.sleep(10 if a.wait_minutes > 1 else 5)
        if ready:
            step('Connect the vault and installed AI clients')
            cmd_connect_clients(cc)
        else:
            print('First sync not finished yet. When the other machine has added this one, run this again.')

    if a.usage_guard:
        if os.path.isdir(ug_paths(P)[0]):
            step('Turn on plan-usage warnings')
            cmd_usage_guard(argparse.Namespace(home_root=a.home_root, settings_path=None, on=True, off=False,
                                               warn=80, prepare=90, handoff=95, dry_run=False))
        else:
            print('This kit edition has no usage warnings; --usage-guard ignored.')

    print('\nDevice ID of this machine : %s' % my)
    print('Tailscale IP              : %s (port %d)' % (ts, a.listen_port))
    try:
        code = make_invite(ed, my, ts, a.listen_port)
        print('Invite code of this machine: %s' % code)
        if qr:
            qr.print_qr(code)
    except Exception:  # noqa: BLE001
        pass
    print('To add another machine: run install there with --invite <code of this machine>, then run accept here.')


# ---- connect-clients --------------------------------------------------------------------------

def cmd_connect_clients(a):
    P = Paths(a.home_root)
    ed = P.ed
    B = read_brain_json(P.brain_json)
    if not B:
        raise BrainError('No %s. Run install first.' % P.brain_json)
    dry = a.dry_run
    marker = ("<!-- %s: generated from the vault's AGENTS.md by _tools/mac/brain.py connect-clients. "
              "Edit the original, not this copy. -->" % ed['vaultName'])
    sig = "generated from the vault's AGENTS.md by"
    H = P.home
    appsup = os.path.join(H, 'Library', 'Application Support')
    cop = os.environ.get('COPILOT_HOME') if (os.environ.get('COPILOT_HOME') and not a.home_root) else os.path.join(H, '.copilot')
    tools = [
        {'name': 'Codex', 'detect': [os.path.join(H, '.codex')], 'file': os.path.join(H, '.codex', 'AGENTS.md'),
         'skills': [os.path.join(H, '.agents', 'skills')]},
        {'name': 'Gemini/Antigravity', 'detect': [os.path.join(H, '.gemini')],
         'file': os.path.join(H, '.gemini', 'GEMINI.md'),
         'skills': [os.path.join(H, '.gemini', 'config', 'skills'), os.path.join(H, '.gemini', 'antigravity', 'skills')]},
        {'name': 'OpenCode', 'detect': [os.path.join(H, '.config', 'opencode')],
         'file': os.path.join(H, '.config', 'opencode', 'AGENTS.md'), 'skills': []},
        {'name': 'GitHub Copilot', 'detect': [cop, os.path.join(appsup, 'Code', 'User')],
         'file': os.path.join(cop, 'copilot-instructions.md'), 'skills': [os.path.join(cop, 'skills')]},
        {'name': 'Cursor', 'detect': [os.path.join(H, '.cursor'), os.path.join(appsup, 'Cursor')], 'file': None,
         'skills': [], 'note': 'global rules are only in Cursor Settings > Rules (paste AGENTS.md there once); '
                               'skills are read from ~/.claude/skills directly'}]
    if dry:
        print('DRY RUN: nothing will be changed.')

    def act(msg, fn):
        if dry:
            print('  would  ' + msg)
        else:
            fn()
            print('  ' + msg)

    def link(path, target):
        if dry:
            if not os.path.lexists(path):
                print('  would  link %s -> %s' % (path, target))
            elif not is_link(path):
                print('  keep   %s (real folder, left as is)' % path)
            return
        set_link(path, target)

    if not dry:
        for d in ('rules', 'skills', 'agents', 'commands', 'handoffs', 'hooks'):
            os.makedirs(os.path.join(P.config, d), exist_ok=True)
    print('Vault links:')
    for d in ('rules', 'skills', 'agents', 'commands'):
        link(os.path.join(P.vault, 'config', d), os.path.join(P.config, d))
    link(os.path.join(P.vault, 'memory'), B['memoryDir'])
    link(os.path.join(P.vault, 'handoffs'), os.path.join(P.config, 'handoffs'))

    src = os.path.join(P.config, 'CLAUDE.md')
    if os.path.isfile(src):
        copy = os.path.join(P.vault, 'config', 'CLAUDE (read-only copy).md')
        head = ('> Read-only copy made %s. Edit `~/.claude/CLAUDE.md` and run `_tools/mac/brain.py connect-clients` again.\n\n'
                % now('%Y-%m-%d %H:%M'))
        act('write  ' + copy, lambda: write_utf8(copy, head + read_text(src)))

    agents_file = os.path.join(P.vault, 'AGENTS.md')
    agents = read_text(agents_file) if os.path.isfile(agents_file) else None
    print('Client instructions:')
    for t in tools:
        if not any(os.path.exists(d) for d in t['detect']):
            print('  skip   %s (not installed)' % t['name'])
            continue
        if not t['file']:
            print('  note   %s: %s' % (t['name'], t['note']))
            continue
        if not agents:
            print('  skip   %s: no AGENTS.md in the vault yet (wait for the first sync)' % t['name'])
            continue
        f = t['file']
        new = '%s\n\n%s' % (marker, agents)
        if os.path.isfile(f):
            old = read_text(f)
            if old == new:
                print('  same   ' + f)
                continue
            if sig not in old:
                bak = '%s.before-brain-%s' % (f, now('%Y%m%d-%H%M%S'))
                act('backup %s -> %s (file was not made by this script)' % (f, bak), lambda f=f, bak=bak: shutil.copyfile(f, bak))
        act('write  %s (%s)' % (f, t['name']), lambda f=f, new=new: write_utf8(f, new))

    skills = os.path.join(P.config, 'skills')
    skill_list = []
    if os.path.isdir(skills):
        skill_list = sorted(n for n in os.listdir(skills)
                            if os.path.isdir(os.path.join(skills, n)) and os.path.isfile(os.path.join(skills, n, 'SKILL.md')))
    print('Skills (%d in %s):' % (len(skill_list), skills))
    for t in tools:
        if not any(os.path.exists(d) for d in t['detect']):
            continue
        for sh in t['skills']:
            if not os.path.isdir(sh):
                act('create ' + sh, lambda sh=sh: os.makedirs(sh, exist_ok=True))
            if os.path.isdir(sh):
                for n in os.listdir(sh):
                    p = os.path.join(sh, n)
                    if is_link(p):
                        tg = link_target(p)
                        if tg.startswith(skills + os.sep) and not os.path.exists(tg):
                            act('remove %s (skill deleted)' % p, lambda p=p: remove_link(p))
            cnt = 0
            for s in skill_list:
                lk = os.path.join(sh, s)
                if not os.path.lexists(lk):
                    cnt += 1
                    if not dry:
                        make_link(lk, os.path.join(skills, s))
            print('  %s %s : %d new (%s)' % ('would ' if dry else '', sh, cnt, t['name']))
    print('Dry run done. Run again without --dry-run to apply.' if dry else 'Done.')


# ---- register-hooks -----------------------------------------------------------------------------

def cmd_register_hooks(a):
    P = Paths(a.home_root)
    settings_path = a.settings_path or os.path.join(P.config, 'settings.json')
    py = os.path.abspath(sys.executable)
    print('Python: ' + py)
    td = tools_dir()
    if not a.dry_run:
        os.makedirs(P.config, exist_ok=True)
        for f in ('run_shared_hook.py', 'personal_memory_hook.py'):
            shutil.copyfile(os.path.join(td, f), os.path.join(P.config, f))
    entries = []
    mp = os.path.join(P.config, 'hooks', 'hooks.json')
    if os.path.isfile(mp):
        entries = [e for e in (json.loads(read_text(mp)).get('hooks') or []) if e and e.get('name') and e.get('event')]
    py_f = py.replace('\\', '/')
    cfg_f = P.config.replace('\\', '/')
    settings = json.loads(read_text(settings_path)) if os.path.isfile(settings_path) else {}
    H = settings.setdefault('hooks', {})
    rx = re.compile(r'run_shared_hook\.py|personal_memory_hook\.py')
    for ev in list(H.keys()):
        keep = [x for x in H[ev] if not any(rx.search(h.get('command', '')) for h in x.get('hooks', []))]
        if keep:
            H[ev] = keep
        else:
            del H[ev]

    def add(ev, matcher, cmd, timeout):
        e = {}
        if matcher:
            e['matcher'] = matcher
        e['hooks'] = [{'type': 'command', 'command': cmd, 'timeout': timeout}]
        H.setdefault(ev, []).append(e)

    for e in entries:
        add(e['event'], e.get('matcher'), '"%s" -B "%s/run_shared_hook.py" %s' % (py_f, cfg_f, e['name']),
            int(e.get('timeout') or 30))
        print('  hook   %s %s -> %s' % (e['event'], e.get('matcher') or '', e['name']))
    if a.personal_memory:
        pm = os.path.join(P.config, 'personal-memory', 'MEMORY.md')
        if not a.dry_run and not os.path.isfile(pm):
            write_utf8(pm, '# Personal memory (this machine only)\n')
        add('SessionStart', None, '"%s" -B "%s/personal_memory_hook.py"' % (py_f, cfg_f), 15)
        print('  hook   SessionStart -> personal memory')
    if not H:
        del settings['hooks']
    if a.dry_run:
        print('DRY RUN: %s would get this hooks section (other settings unchanged):' % settings_path)
        print(json.dumps(settings.get('hooks', '(no hooks)'), indent=2))
        return
    if os.path.isfile(settings_path):
        shutil.copyfile(settings_path, '%s.bak-%s' % (settings_path, now('%Y%m%d-%H%M%S')))
    write_utf8(settings_path, json.dumps(settings, indent=2, ensure_ascii=False))
    print('Saved %s (%d shared hook(s)%s).' % (settings_path, len(entries), ', personal memory' if a.personal_memory else ''))
    print('Hooks take effect in new sessions.')


# ---- usage-guard (optional plan-usage warnings; only in editions that ship tools/usage-guard) ----

UG_KEY = 'CLAUDE_CODE_PLUGIN_DIRS'
UG_LEVELS_RX = re.compile(r'const WARN = (\d+), PREPARE = (\d+), HANDOFF = (\d+)')


def ug_paths(P):
    return os.path.join(tools_dir(), 'usage-guard'), os.path.join(P.state, 'usage-guard')


def ug_state(P, settings_path):
    """(value of the env key, whether it points at this machine's mod copy)."""
    _src, dst = ug_paths(P)
    cur = ''
    if os.path.isfile(settings_path):
        cur = str((json.loads(read_text(settings_path)).get('env') or {}).get(UG_KEY) or '')
    ours = bool(cur) and cur.rstrip('/\\').replace('\\', '/').lower() == dst.replace('\\', '/').lower()
    return cur, ours


def cmd_usage_guard(a):
    P = Paths(a.home_root)
    settings_path = a.settings_path or os.path.join(P.config, 'settings.json')
    src, dst = ug_paths(P)
    dst_f = dst.replace('\\', '/')
    if a.on and a.off:
        raise BrainError('Use --on or --off, not both.')
    if not os.path.isfile(os.path.join(src, 'hooks', 'register.ts')):
        raise BrainError('The usage-guard mod is not part of this kit edition (%s missing).' % src)
    cur, ours = ug_state(P, settings_path)
    if not a.on and not a.off:
        reg = os.path.join(dst, 'hooks', 'register.ts')
        if ours and os.path.isfile(reg):
            m = UG_LEVELS_RX.search(read_text(reg))
            print('Usage warnings: on (levels %s), mod at %s' % ('/'.join(m.groups()) + '%' if m else '?', dst))
        elif ours:
            print('Usage warnings: switched on in settings.json but the mod is missing at %s. Run --on again.' % dst)
        elif cur:
            print('Usage warnings: off (%s is set to another folder: %s)' % (UG_KEY, cur))
        else:
            print('Usage warnings: off')
        return 0
    settings = json.loads(read_text(settings_path)) if os.path.isfile(settings_path) else {}

    def save():
        if a.dry_run:
            print('DRY RUN: %s would get this env section (other settings unchanged):' % settings_path)
            print(json.dumps(settings.get('env', '(no env)'), indent=2))
            return
        if os.path.isfile(settings_path):
            shutil.copyfile(settings_path, '%s.bak-%s' % (settings_path, now('%Y%m%d-%H%M%S')))
        write_utf8(settings_path, json.dumps(settings, indent=2, ensure_ascii=False))
        print('Saved %s.' % settings_path)

    if a.on:
        lv = (a.warn, a.prepare, a.handoff)
        if not all(1 <= x <= 100 for x in lv) or not (lv[0] < lv[1] < lv[2]):
            raise BrainError('Levels must be 1-100 and rise: warn < prepare < handoff (got %d/%d/%d).' % lv)
        if cur and not ours:
            raise BrainError('%s in %s already points to another folder (%s). Nothing changed. Remove that line or '
                             'add the mod folder (%s) by hand.' % (UG_KEY, settings_path, cur, dst_f))
        if a.dry_run:
            print('DRY RUN: would copy the mod to %s with levels %d/%d/%d%%.' % ((dst,) + lv))
        else:
            if os.path.isdir(dst):
                shutil.rmtree(dst)
            os.makedirs(P.state, exist_ok=True)
            shutil.copytree(src, dst)
            reg = os.path.join(dst, 'hooks', 'register.ts')
            text = read_text(reg)
            if not UG_LEVELS_RX.search(text):
                raise BrainError('Could not find the levels line in %s.' % reg)
            write_utf8(reg, UG_LEVELS_RX.sub('const WARN = %d, PREPARE = %d, HANDOFF = %d' % lv, text))
            print('Mod copied to %s (levels %d/%d/%d%%).' % ((dst,) + lv))
        settings.setdefault('env', {})[UG_KEY] = dst_f
        save()
        print('Usage warnings are on. They take effect in new sessions.')
        return 0
    if cur and not ours:
        print('%s points to another folder (%s); left as is.' % (UG_KEY, cur))
    elif ours:
        del settings['env'][UG_KEY]
        if not settings['env']:
            del settings['env']
        save()
    if os.path.isdir(dst):
        if a.dry_run:
            print('DRY RUN: would remove %s.' % dst)
        else:
            shutil.rmtree(dst)
            print('Removed %s.' % dst)
    print('Usage warnings are off. New sessions start without them.')
    return 0


# ---- check ----------------------------------------------------------------------------------------

def cmd_check(a):
    P = Paths(a.home_root)
    B = read_brain_json(P.brain_json)
    fails = [0]

    def res(ok, what, detail=''):
        if not ok:
            fails[0] += 1
        print('%s  %s  %s' % ('PASS' if ok else 'FAIL', what, detail))

    if not B:
        res(False, 'install', 'no ' + P.brain_json)
        return 1
    for p in (P.config, P.vault, P.state):
        if os.path.lexists(p):
            d = 'link -> ' + link_target(p) if is_link(p) else 'folder'
        else:
            d = 'missing'
        res(os.path.lexists(p), p, d)
    res(os.path.isfile(os.path.join(P.config, 'CLAUDE.md')), 'main instructions', os.path.join(P.config, 'CLAUDE.md'))
    res(os.path.isfile(os.path.join(B['memoryDir'], 'MEMORY.md')), 'shared memory index', B['memoryDir'])
    res(os.path.isfile(os.path.join(P.vault, 'AGENTS.md')), 'vault AGENTS.md', P.vault)
    conf = []
    for root in (P.config, P.vault):
        for dp, _dn, fns in os.walk(root):
            conf += [os.path.join(dp, f) for f in fns if 'sync-conflict' in f]
    res(not conf, 'sync conflicts', '%d file(s)%s' % (len(conf), (': ' + '; '.join(conf[:3])) if conf else ''))
    try:
        st = St(P.st_home, int(B['guiPort']))
        devs = st.call('GET', '/rest/config/devices')
        my = st.my_id()
        conns = st.call('GET', '/rest/system/connections')['connections']
        for fid in FOLDER_IDS:
            s = st.call('GET', '/rest/db/status?folder=' + fid)
            errs = [e for e in ((st.call('GET', '/rest/folder/errors?folder=' + fid) or {}).get('errors') or []) if e]
            res(s['state'] == 'idle' and not errs and s['needFiles'] == 0, 'sync ' + fid,
                'state=%s need=%s errors=%d' % (s['state'], s['needFiles'], len(errs)))
        for d in devs:
            if d['deviceID'] == my:
                continue
            c = conns.get(d['deviceID'], {})
            pct = [round(st.call('GET', '/rest/db/completion?folder=%s&device=%s' % (fid, d['deviceID']))['completion'], 1)
                   for fid in FOLDER_IDS]
            res(bool(c.get('connected')), 'peer ' + d['name'],
                'connected=%s completion=%s%%' % (bool(c.get('connected')), '/'.join(str(x) for x in pct)))
    except Exception as e:  # noqa: BLE001
        res(False, 'syncthing', str(e))
    sp = os.path.join(P.config, 'settings.json')
    if os.path.isfile(sp):
        n = len(re.findall(r'run_shared_hook\.py', read_text(sp)))
        mp = os.path.join(P.config, 'hooks', 'hooks.json')
        want = len(json.loads(read_text(mp)).get('hooks') or []) if os.path.isfile(mp) else 0
        res(n == want, 'hooks registered', '%d of %d in manifest (run register-hooks if different)' % (n, want))
    if os.path.isdir(ug_paths(P)[0]):
        _cur, ours = ug_state(P, sp)
        if ours:
            res(os.path.isfile(os.path.join(ug_paths(P)[1], 'hooks', 'register.ts')), 'usage warnings',
                'on, mod at %s (run usage-guard --on if missing)' % ug_paths(P)[1])
        else:
            print('INFO  usage warnings  off (optional: brain.py usage-guard --on)')
    print('')
    if fails[0]:
        print('%d check(s) failed.' % fails[0])
        return 1
    print('All checks passed.')
    return 0


def cmd_selftest(_a):
    for _ in range(20):
        raw = os.urandom(32)
        dev = raw_to_device_id(raw)
        assert DEVICE_RX.match(dev) and device_id_to_raw(dev) == raw, dev
    ed = get_edition()
    ip = '.'.join(['100', '64', '0', '7'])
    inv = make_invite(ed, raw_to_device_id(os.urandom(32)), ip, 22000)
    d = decode_invite(ed, inv)
    assert d['ip'] == ip and d['port'] == 22000
    print('selftest ok')


# ---- main -------------------------------------------------------------------------------------------

def build_parser():
    ap = argparse.ArgumentParser(prog='brain.py', description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)

    def sp(name, fn, help_):
        p = sub.add_parser(name, help=help_)
        p.add_argument('--home-root', help='test option: use this folder as the home folder')
        p.set_defaults(fn=fn)
        return p

    p = sp('install', cmd_install, 'set up this machine')
    p.add_argument('--work-folder', required=True)
    p.add_argument('--invite')
    p.add_argument('--peer-id')
    p.add_argument('--peer-ip')
    p.add_argument('--peer-port', type=int, default=22000)
    p.add_argument('--peer-name', default='peer')
    p.add_argument('--gui-port', type=int, default=8384)
    p.add_argument('--listen-port', type=int, default=22000)
    p.add_argument('--no-service', action='store_true')
    p.add_argument('--syncthing')
    p.add_argument('--wait-minutes', type=int, default=30)
    p.add_argument('--usage-guard', action='store_true', help='also turn on plan-usage warnings (if this edition has them)')
    sp('invite', lambda a: show_invite(Paths(a.home_root)), 'print this machine\'s invite code and QR')
    p = sp('accept', cmd_accept, 'pair machines that joined with your invite')
    p.add_argument('--yes', action='store_true')
    p.add_argument('--peer-port', type=int, default=22000)
    p.add_argument('--wait-seconds', type=int, default=0)
    p = sp('add-peer', cmd_add_peer, 'pair with another machine by ID and IP')
    p.add_argument('--peer-id', required=True)
    p.add_argument('--peer-ip', required=True)
    p.add_argument('--peer-name', required=True)
    p.add_argument('--peer-port', type=int, default=22000)
    p = sp('connect-clients', cmd_connect_clients, 'connect the vault and AI tools')
    p.add_argument('--dry-run', action='store_true')
    p = sp('register-hooks', cmd_register_hooks, 'register shared hooks')
    p.add_argument('--dry-run', action='store_true')
    p.add_argument('--personal-memory', action='store_true')
    p.add_argument('--settings-path')
    p = sp('usage-guard', cmd_usage_guard, 'optional plan-usage warnings on/off for this machine (no option: status)')
    p.add_argument('--on', action='store_true')
    p.add_argument('--off', action='store_true')
    p.add_argument('--warn', type=int, default=80)
    p.add_argument('--prepare', type=int, default=90)
    p.add_argument('--handoff', type=int, default=95)
    p.add_argument('--dry-run', action='store_true')
    p.add_argument('--settings-path')
    sp('check', cmd_check, 'read-only health check')
    sp('selftest', cmd_selftest, 'check the code and ID routines')
    return ap


def main(argv=None):
    a = build_parser().parse_args(argv)
    try:
        r = a.fn(a)
    except BrainError as e:
        print('ERROR: %s' % e, file=sys.stderr)
        return 1
    return r if isinstance(r, int) else 0


if __name__ == '__main__':
    sys.exit(main())
