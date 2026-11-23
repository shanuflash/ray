#!/usr/bin/env python3
import argparse
import pathlib


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    source = args.input.read_text()
    delimiter = 'ray_bootstrap'
    if f'){delimiter}"' in source:
        parser.error('bootstrap contains the C++ literal delimiter')
    text = ('#ifndef RAY_LINUX_HOST_BOOTSTRAP_H_\n'
            '#define RAY_LINUX_HOST_BOOTSTRAP_H_\n'
            'namespace ray {\n'
            f'inline constexpr char kRayHostBootstrap[] = R"{delimiter}({source}){delimiter}";\n'
            '}\n'
            '#endif\n')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if not args.output.exists() or args.output.read_text() != text:
        args.output.write_text(text)


if __name__ == '__main__':
    main()
