import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / 'core-reboot.sh').read_text()


def case(name, target='riscv', operation='reboot', markers=True, failure=None):
    with tempfile.TemporaryDirectory() as directory:
        p = Path(directory)
        boot = p / 'boot'
        boot.mkdir()
        sys = p / 'sys'
        kind = sys / 'class/block/mmcblk0/device/type'
        kind.parent.mkdir(parents=True)
        kind.write_text('MMC' if failure == 'emmc' else 'SD')
        (p / 'cmdline').write_text('nixbadge.bootmedium=1')
        (boot / 'fip.bin').write_bytes(b'tested firmware')
        for core in ('arm', 'riscv'):
            for slot in ('A', 'B'):
                d = boot / core / ('slot-' + slot)
                d.mkdir(parents=True)
                (d / 'boot.itb').write_bytes(b'FIT')
                (d / 'vbmeta.itb').write_bytes(b'metadata')
        if failure == 'image':
            (boot / 'riscv/slot-A/boot.itb').unlink()
        before = {}
        if markers:
            for marker in ('coreswap.request', 'coreswap.pending'):
                before[marker] = b'riscv\n'
                (boot / marker).write_bytes(before[marker])
        expected = p / 'expected-firmware'
        expected.write_bytes(b'other firmware' if failure == 'hash' else b'tested firmware')
        script = source
        for key, value in [('boot', boot), ('sys', sys), ('cmdline', p / 'cmdline'), ('lock', p / 'lock'), ('firmware', expected)]:
            script = '\n'.join(key + '=' + shlex.quote(str(value)) if line.startswith(key + '=') else line for line in script.splitlines())
        script = script.replace('[[ $EUID == 0 ]]', '[[ 1 == 1 ]]')
        (p / 'helper').write_text(script)
        bin = p / 'bin'
        bin.mkdir()
        def command(name, body):
            path = bin / name
            path.write_text('#!' + shutil.which('bash') + '\n' + body)
            path.chmod(0o755)
        command('findmnt', 'case "$*" in *SOURCE) echo /dev/mmcblk0p1;; *FSTYPE) echo vfat;; *) exit 1;; esac\n')
        command('systemctl', 'echo "$*" >> ' + shlex.quote(str(p/'reboots')) + '\nexit ' + ('1' if failure == 'reboot' else '0') + '\n')
        if failure == 'publish': command('mv', 'exit 1\n')
        env = dict(os.environ, PATH=str(bin) + ':' + os.environ['PATH'])
        r = subprocess.run(['bash', str(p/'helper'), operation, target], env=env, capture_output=True, text=True)
        expected_failure = failure is not None or target not in ('arm', 'riscv')
        assert (r.returncode != 0) == expected_failure, (name, r.stdout, r.stderr)
        after = {x: (boot/x).read_bytes() for x in before if (boot/x).exists()}
        backups = list(boot.glob('core-reboot-*.orig'))
        if operation == 'check' or expected_failure:
            assert after == before, (name, after, before)
        elif target == 'arm':
            assert not (boot/'coreswap.request').exists() and not (boot/'coreswap.pending').exists()
        else:
            assert (boot/'coreswap.request').read_bytes() == b'riscv\n'
            assert not (boot/'coreswap.pending').exists()
        if operation == 'check' or failure in ('emmc', 'hash', 'image') or target == 'invalid':
            assert not backups and not (p/'reboots').exists()
        else:
            assert len(backups) == 1
            for marker, value in before.items(): assert (backups[0]/marker).read_bytes() == value
        print(name + ': PASS')


case('read-only preflight', operation='check')
case('ARM clears request and pending with backups', target='arm')
case('new RISC-V request', markers=False)
case('explicit RISC-V retry archives pending')
case('reboot refusal rolls back markers', failure='reboot')
case('publication failure rolls back markers', failure='publish')
case('unknown firmware refused', failure='hash')
case('eMMC refused', failure='emmc')
case('missing alternate payload refused', failure='image')
case('unknown core refused', target='invalid')
