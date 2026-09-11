#!/usr/bin/env python3
"""Install the shared Arena skill for Codex and Claude Code without overwriting edits."""
import os
from pathlib import Path
import shutil


def install():
    source = Path(__file__).resolve().parents[1] / 'Sources' / 'Arena' / 'Resources' / 'arena'
    targets = [Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))) / 'skills' / 'arena',
               Path(os.environ.get('CLAUDE_CONFIG_DIR', str(Path.home() / '.claude'))) / 'skills' / 'arena']
    files = [path.relative_to(source) for path in source.rglob('*') if path.is_file()]
    for target in targets:
        for file in files:
            existing = target / file
            if existing.exists() and existing.read_bytes() != (source / file).read_bytes():
                raise SystemExit(f'Existing skill differs: {existing}. Review it before replacing it.')
    for target in targets:
        for file in files:
            destination = target / file
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source / file, destination)
        print(f'Arena skill installed: {target}')


if __name__ == '__main__':
    install()
