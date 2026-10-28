#!/usr/bin/env python3
"""Rename Helium to Ray in a Chromium tree's strings, after Helium's own name_substitution.py and i18n_apply.py.

Runs Helium's name substitution machinery (its utils, unchanged) with Ray's rules over every .grd, .grdp and
.xtb: "Helium" becomes "Ray", helium:// shown to the user becomes ray://, links inside strings go back to
chrome:// so they keep opening inside the engine, and the copyright and company lines that Helium's pass made "The
Helium Authors" go back to "The Chromium Authors" in every language (first, so a translation like "Die
Helium-Autoren" becomes "Die Chromium-Autoren", never "Die Ray-Autoren"). Helium's copyright and licence live
in the credits page's licence data, not in strings. Translation ids are remapped as Helium's pass does, for every
translation of a changed message. Running it again changes nothing. Exits non-zero if any string, its
placeholders and link targets included, still says helium or imput in any case.

Usage: ray_namesub.py --tree <chromium/src> --helium <helium-chromium checkout> [--workers N] [--check-only]
"""
import argparse
import multiprocessing
import pathlib
import re
import sys
import xml.etree.ElementTree as xml

RAY_RULES = [
    (r'The Helium Authors', 'The Chromium Authors'),
    (r'''(href\s*=\s*["']?)helium://''', r'\1chrome://'),
    (r'helium://', 'ray://'),
    (r'(?<![/._0-9])Helium(?![A-Z0-9_])', 'Ray'),
]

SANITY = [
    ('Helium', 'Ray'),
    ('About Helium', 'About Ray'),
    ('Helium\'s settings', 'Ray\'s settings'),
    ('helium://settings', 'ray://settings'),
    ('Type helium://extensions here', 'Type ray://extensions here'),
    ('<a href="helium://management">helium://management</a>', '<a href="chrome://management">ray://management</a>'),
    ('Copyright 2026 The Helium Authors. All rights reserved.',
     'Copyright 2026 The Chromium Authors. All rights reserved.'),
    ('Helium-Einstellungen', 'Ray-Einstellungen'),
    ('Vula imenyu yeHelium', 'Vula imenyu yeRay'),
    ('Heliumin asetukset', 'Rayin asetukset'),
    ('ku-Helium', 'ku-Ray'),
    ('HeliumWidget', 'HeliumWidget'),
    ('https://example.com/Helium/page', 'https://example.com/Helium/page'),
]

COPYRIGHT_RULES = [(r'Helium', 'Chromium')]
COPYRIGHT_MARK = 'Helium Authors'

LEFTOVER = re.compile(r'(?i)helium|imput')


def helium_utils(helium):
    utils = pathlib.Path(helium).resolve() / 'utils'
    if not (utils / 'name_substitution.py').is_file():
        sys.exit(f'ray_namesub: no Helium utils at {utils}')
    if str(utils) not in sys.path:
        sys.path.insert(0, str(utils))
    import name_substitution
    import name_substitution_utils
    use_rules(name_substitution_utils, RAY_RULES)
    remap_every_translation(name_substitution_utils)
    return name_substitution, name_substitution_utils


def use_rules(util, rules):
    util.REPLACEMENT_REGEXES = [(re.compile(p), r) for p, r in rules]


def remap_every_translation(util):
    def replace_xtb_translation(msg, fp_map):
        matched = util.replace_grit_message(msg)
        msg_id = msg.get('id')
        if msg_id in fp_map:
            msg.set('id', fp_map[msg_id])
            return True
        return matched
    util.replace_xtb_translation = replace_xtb_translation


def parse(path, util):
    return xml.fromstring(path.read_text(encoding='utf-8').replace('&#36;', '!!dollar-sign-literal!!'), util.get_parser())


def write(path, root):
    text = xml.tostring(root, encoding='unicode', xml_declaration=True)
    path.write_text(text.replace('!!dollar-sign-literal!!', '&#36;'), encoding='utf-8')


def restore_copyright(namesub, util, tree):
    util.add_grit_to_path(tree)
    use_rules(util, COPYRIGHT_RULES)
    fp_map = {}
    for path in namesub.get_substitutable_files(tree, ['grd', 'grdp']):
        if COPYRIGHT_MARK not in path.read_text(encoding='utf-8'):
            continue
        root = parse(path, util)
        for msg in root.iter('message'):
            if COPYRIGHT_MARK in ''.join(msg.itertext()):
                old = util.compute_fp(msg)
                util.replace_grit_message(msg)
                fp_map[old] = util.compute_fp(msg)
        write(path, root)
    ids = {f'id="{i}"' for i in fp_map}
    translations = 0
    for path in namesub.get_substitutable_files(tree, ['xtb']):
        raw = path.read_text(encoding='utf-8')
        if not any(i in raw for i in ids):
            continue
        root = parse(path, util)
        for t in root.iter('translation'):
            if t.get('id') in fp_map:
                util.replace_grit_message(t)
                t.set('id', fp_map[t.get('id')])
                translations += 1
        write(path, root)
    use_rules(util, RAY_RULES)
    return set(fp_map.values()), translations


def copyright_claims(namesub, tree, copyright_ids):
    found = []
    for path in namesub.get_substitutable_files(tree, ['xtb', 'grd', 'grdp']):
        raw = path.read_text(encoding='utf-8')
        if 'Ray Authors' in raw:
            found.append(f'{path.relative_to(tree)}: Ray Authors')
        if path.suffix != '.xtb' or not any(f'id="{i}"' in raw for i in copyright_ids):
            continue
        for t in xml.fromstring(raw.replace('&#36;', '$')).iter('translation'):
            if t.get('id') in copyright_ids and 'Ray' in ''.join(t.itertext()):
                found.append(f'{path.relative_to(tree)}: {t.get("id")}: {"".join(t.itertext())[:80]!r}')
    return found


def sanity(util):
    for source, expected in SANITY:
        got, _ = util.replace_text(source)
        if got != expected:
            sys.exit(f'ray_namesub: rule check failed: {source!r} -> {got!r}, expected {expected!r}')


def all_texts(elem):
    return ''.join(elem.itertext()) + ' '.join(v for e in elem.iter() for v in e.attrib.values()
                                               if e is not elem and e.tag not in ('ph',))


def leftovers(namesub, tree):
    found = []
    for ext, tag in (('grd', 'message'), ('grdp', 'message'), ('xtb', 'translation')):
        for path in namesub.get_substitutable_files(tree, [ext]):
            raw = path.read_text(encoding='utf-8')
            if not LEFTOVER.search(raw):
                continue
            root = xml.fromstring(raw.replace('&#36;', '$'))
            for msg in root.iter(tag):
                text = all_texts(msg)
                if LEFTOVER.search(text):
                    found.append(f'{path.relative_to(tree)}: {msg.get("name") or msg.get("id")}: {text.strip()[:120]!r}')
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--tree', type=pathlib.Path, required=True)
    parser.add_argument('--helium', type=pathlib.Path, required=True)
    parser.add_argument('--workers', type=int, default=multiprocessing.cpu_count())
    parser.add_argument('--check-only', action='store_true')
    args = parser.parse_args()
    tree = args.tree.resolve()
    if not (tree / 'chrome/app/chromium_strings.grd').is_file():
        sys.exit(f'ray_namesub: {tree} is not a chromium/src tree')
    namesub, util = helium_utils(args.helium)
    sanity(util)
    copyright_ids = set()
    if not args.check_only:
        copyright_ids, translations = restore_copyright(namesub, util, tree)
        print(f'ray_namesub: copyright lines back to The Chromium Authors: {len(copyright_ids)} messages, '
              f'{translations} translations')
        multiprocessing.set_start_method('fork', force=True)
        namesub.do_substitution(tree, None, args.workers, False)
    claims = copyright_claims(namesub, tree, copyright_ids)
    if claims:
        print('ray_namesub: copyright lines that name Ray:', *claims, sep='\n  ', file=sys.stderr)
        sys.exit(1)
    left = leftovers(namesub, tree)
    if left:
        print(f'ray_namesub: {len(left)} user-visible Helium strings left:', *left, sep='\n  ', file=sys.stderr)
        sys.exit(1)
    print('ray_namesub: no user-visible Helium left in .grd/.grdp/.xtb')


if __name__ == '__main__':
    main()
