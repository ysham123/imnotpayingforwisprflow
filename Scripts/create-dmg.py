#!/usr/bin/env python3
"""Build a Finder drag-to-Applications layout without automating Finder."""
import argparse
from pathlib import Path


def settings(content, source):
    return {
        'format': 'UDZO', 'filesystem': 'HFS+',
        'files': [str(content / name) for name in ['Local Dictation.app', 'START HERE.html', 'READ ME FIRST.txt']],
        'symlinks': {'Applications': '/Applications'},
        'hide': ['START HERE.html', 'READ ME FIRST.txt'],
        'icon': str(source / 'Resources/AppIcon.icns'),
        'background': str(source / 'Distribution/Artwork/dmg-background.png'),
        # Finder's saved frame includes the 32-point title bar above the artwork.
        'window_rect': ((240, 160), (720, 492)),
        'default_view': 'icon-view', 'icon_size': 112, 'text_size': 14,
        'icon_locations': {'Local Dictation.app': (200, 224), 'Applications': (520, 224)},
        'show_status_bar': False, 'show_tab_view': False, 'show_toolbar': False,
        'show_pathbar': False, 'show_sidebar': False, 'show_icon_preview': False,
        'include_icon_view_settings': True, 'arrange_by': None,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('content', type=Path)
    parser.add_argument('image', type=Path)
    args = parser.parse_args()
    try:
        from dmgbuild import build_dmg
    except ImportError:
        raise SystemExit('Install build-only DMG tools from Scripts/dmg-requirements.txt in a virtual environment')
    source = Path(__file__).resolve().parents[1]
    build_dmg(str(args.image.resolve()), 'Local Dictation', settings=settings(args.content.resolve(), source))


if __name__ == '__main__':
    main()
