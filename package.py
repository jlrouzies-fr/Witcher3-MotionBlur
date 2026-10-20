r"""Build the Nexus release folder for Object Motion Blur.

  py package.py [--images <png> ...]

Creates _modCreation\release\ObjectMotionBlur_<version>\:
  ObjectMotionBlur_<version>.zip   bin\x64_dx12\ObjectMotionBlur.addon64 (unzip into the game folder)
  description.bbcode.txt, CHANGELOG.txt (copied from release_page\)
  images\                          with --images: the given screenshots, numbered in order
Build first (build.bat). Nothing is installed or uploaded.
"""
import os
import re
import shutil
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))  # _modCreation
ADDON = os.path.join(HERE, 'out', 'ObjectMotionBlur.addon64')
PAGE = os.path.join(HERE, 'release_page')


def version():
    src = open(os.path.join(HERE, 'src', 'motion_blur.cpp'), encoding='utf-8').read()
    return re.search(r'#define OMB_VERSION "([^"]+)"', src).group(1)


def main():
    ver = version()
    out = os.path.join(ROOT, 'release', f'ObjectMotionBlur_{ver}')
    os.makedirs(out, exist_ok=True)
    with zipfile.ZipFile(os.path.join(out, f'ObjectMotionBlur_{ver}.zip'), 'w', zipfile.ZIP_DEFLATED) as z:
        z.write(ADDON, 'bin/x64_dx12/ObjectMotionBlur.addon64')
    for f in ('description.bbcode.txt', 'CHANGELOG.txt'):
        shutil.copy2(os.path.join(PAGE, f), out)

    if '--images' in sys.argv:
        img = os.path.join(out, 'images')
        os.makedirs(img, exist_ok=True)
        for n, src in enumerate(sys.argv[sys.argv.index('--images') + 1:]):
            shutil.copy2(src, os.path.join(img, f'{n:02d}_{os.path.basename(src)}'))
        print(f'images -> {img}')
    print(f'release folder: {out}')


if __name__ == '__main__':
    main()
