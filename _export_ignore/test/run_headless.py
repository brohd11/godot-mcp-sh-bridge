#!/usr/bin/env python3
"""Run the bridge tests in an isolated project, so the dev project's plugins and
res://.mcp-sh config can't affect them. Exits 0 on pass (Python 3, Godot 4.4+)."""
import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

PACKAGE = Path('addons/_lib/mcp_sh_bridge')
ENTRY = 'res://addons/_lib/mcp_sh_bridge/_export_ignore/test/bridge_test.gd'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', default='godot')
    parser.add_argument('--keep', action='store_true', help='Keep the temporary project for inspection')
    args = parser.parse_args()
    package = Path(__file__).resolve().parents[2]
    project = Path(tempfile.mkdtemp(prefix='mcp-sh-bridge-test-'))
    try:
        (project / 'project.godot').write_text('config_version=5\n')
        shutil.copytree(package, project / PACKAGE,
                        ignore=shutil.ignore_patterns('.git', 'exports', '__pycache__', '*.py'))
        result = subprocess.run([args.godot, '--headless', '--path', str(project), '--script', ENTRY],
                                capture_output=True, text=True, timeout=120)
        out = result.stdout + result.stderr
        print(out)
        if 'SCRIPT ERROR' in out:
            print('script errors in the bridge or the tests')
            return 1
        return result.returncode
    finally:
        if args.keep:
            print(f'Kept {project}')
        else:
            shutil.rmtree(project, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
