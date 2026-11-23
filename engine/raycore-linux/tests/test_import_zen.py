import base64
import json
import sqlite3
import unittest

from support import ImportFixture, mozlz4

PNG = b'\x89PNG\r\n\x1a\n' + b'\x00\x00\x00\rIHDR' + b'\x00' * 17
STORED_PNG = b'\x89PNG\r\n\x1a\n' + b'stored-icon'
WORK = '{work-space}'
HOME = '{home-space}'
SHOP = '{shop-space}'
UNSET = object()


def data_png(raw=PNG):
    return 'data:image/png;base64,' + base64.b64encode(raw).decode()


def tab(url, title='', workspace=None, pinned=False, essential=False, sync=None, group=None, container=0, **extra):
    made = {'entries': [{'url': 'https://old.example/', 'title': 'Old'}, {'url': url, 'title': title}], 'index': 2,
            'pinned': pinned or essential, 'zenWorkspace': workspace, 'zenEssential': essential, 'zenSyncId': sync,
            'userContextId': container, 'lastAccessed': 1795065357225, 'zenIsEmpty': False, 'zenIsGlance': False,
            'zenLiveFolderItemId': None}
    if group is not None:
        made['groupId'] = group
    made.update(extra)
    return made


def space(uuid, name, icon=None, container=0, colors=None):
    made = {'uuid': uuid, 'name': name, 'containerTabId': container,
            'theme': {'type': 'gradient', 'gradientColors': colors or []}}
    if icon is not None:
        made['icon'] = icon
    return made


def zen_folder(ident, name, workspace=None, parent=None, previous=UNSET, live=False, split=False):
    made = {'id': ident, 'name': name, 'parentId': parent, 'workspaceId': workspace, 'pinned': True,
            'isLiveFolder': live, 'splitViewGroup': split}
    if previous is not UNSET:
        made['prevSiblingInfo'] = {'type': 'tab', 'id': previous}
    return made


def shape(nodes):
    return [n['title'] if n['type'] == 'url' else (n['title'], shape(n['children'])) for n in nodes]


class ZenImportTests(ImportFixture):
    def zen_root(self):
        return self.config / 'zen'

    def zen_profile(self, session=None, path='abcd.Work', name='Work', others=()):
        root = self.zen_root()
        profile = root / path
        profile.mkdir(parents=True, exist_ok=True)
        entries = [(path, name), *others]
        (root / 'profiles.ini').write_text(''.join(f'[Profile{i}]\nName={n}\nIsRelative=1\nPath={p}\n\n' for i, (p, n) in enumerate(entries)))
        (profile / 'places.sqlite').write_bytes(b'')
        if session is not None:
            (profile / 'zen-sessions.jsonlz4').write_bytes(mozlz4(json.dumps(session)))
        return profile

    def sources(self):
        return {s['id']: s for s in self.json('discover', *self.env_args())}

    def read_zen(self, kinds, profile='abcd.Work', space_ids=None, browser='zen'):
        args = ['read', *self.env_args(), browser, profile, ','.join(kinds), 0, 0, 0, '-', '-', 1700000000000, '-']
        if space_ids is not None:
            args.append(','.join(space_ids))
        return self.json(*args)['result']

    def full_session(self):
        tabs = [
            tab('https://mail.example/', 'Mail', essential=True, sync='e1', image=data_png()),
            tab('https://mail.example/', 'Mail again', essential=True, sync='e2'),
            tab('https://mail.example/', 'Mail at work', essential=True, sync='e3', container=2),
            tab('https://linear.example/', 'Linear', WORK, pinned=True, sync='p1',
                _zenPinnedInitialState={'entry': {'url': 'https://linear.example/home', 'title': 'Linear home'},
                                        'image': data_png()}),
            tab('https://notion.example/', 'Notion', WORK, pinned=True, sync='p2', zenStaticLabel='Notes',
                image='data:image/svg+xml;base64,PHN2Zz4='),
            tab('https://notion.example/', 'Notion copy', WORK, pinned=True, sync='p2'),
            tab('about:blank', '', WORK, pinned=True, sync='p3', group='docs', zenIsEmpty=True),
            tab('https://mdn.example/', 'MDN', WORK, pinned=True, sync='p4', group='docs'),
            tab('https://inner.example/', 'Inner', WORK, pinned=True, sync='p5', group='inner'),
            tab('https://left.example/', 'Left', WORK, pinned=True, sync='p6', group='split'),
            tab('https://right.example/', 'Right', WORK, pinned=True, sync='p7', group='split'),
            tab('https://feed.example/', 'Feed', WORK, pinned=True, sync='p8', group='live', zenLiveFolderItemId='item'),
            tab('https://glance.example/', 'Glance', WORK, zenIsGlance=True),
            tab('https://news.example/', 'News', WORK, sync='t1'),
            tab('https://news.example/', 'News twice', WORK, sync='t1'),
            tab('https://shop.example/', 'Shop', None, container=2),
            tab('https://home.example/', 'Home', HOME, pinned=True, sync='h1'),
            tab('https://reddit.example/r/linux', 'Reddit', HOME),
        ]
        folders = [
            zen_folder('docs', 'Docs', WORK, previous='p1'),
            zen_folder('inner', 'Inner', parent='docs', previous='p4'),
            zen_folder('split', 'Split', WORK, previous=None, split=True),
            zen_folder('live', 'Feeds', WORK, live=True),
        ]
        spaces = [
            space(WORK, 'Work', '💼', colors=[{'c': [10, 20, 30], 'isPrimary': False}, {'c': '#aabbcc', 'isPrimary': True}]),
            space(HOME, 'Home', 'chrome://browser/skin/home.svg'),
            space(SHOP, '', '🛍️', container=2),
        ]
        return {'tabs': tabs, 'folders': folders, 'spaces': spaces}

    def test_discovery_marks_zen_and_summarizes_each_space(self):
        profile = self.zen_profile(self.full_session())
        (profile / 'containers.json').write_text(json.dumps({'identities': [
            {'userContextId': 2, 'public': True, 'l10nId': 'user-context-shopping'},
            {'userContextId': 3, 'public': True, 'name': 'Banking'},
            {'userContextId': 4294967295, 'public': False, 'name': 'internal'},
        ]}))
        firefox = self.home / '.mozilla' / 'firefox'
        (firefox / 'abcd.default').mkdir(parents=True)
        (firefox / 'abcd.default' / 'places.sqlite').write_bytes(b'')
        (firefox / 'profiles.ini').write_text('[Profile0]\nName=default\nIsRelative=1\nPath=abcd.default\n')
        sources = self.sources()
        self.assertEqual(sources['zen']['sidebar'], 'zen')
        self.assertNotIn('sidebar', sources['firefox'])
        self.assertNotIn('spaces', sources['firefox']['profiles'][0])
        self.assertEqual(sources['firefox']['profiles'][0]['available'], ['bookmarks', 'history'])
        zen = sources['zen']['profiles'][0]
        self.assertEqual(zen['available'], ['bookmarks', 'history', 'spaces', 'pinnedTabs', 'tabs', 'favorites'])
        self.assertEqual(zen['spaces'], [
            {'id': WORK, 'name': 'Work', 'color': '#AABBCC', 'emoji': '💼', 'pinnedCount': 6, 'tabCount': 1},
            {'id': HOME, 'name': 'Home', 'pinnedCount': 1, 'tabCount': 1},
            {'id': SHOP, 'name': 'Space 3', 'emoji': '🛍️', 'pinnedCount': 0, 'tabCount': 1, 'container': 2,
             'containerName': 'Shopping'},
        ])

    def test_read_brings_spaces_pinned_folders_tabs_and_essentials(self):
        profile = self.zen_profile(self.full_session())
        (profile / 'prefs.js').write_text('user_pref("zen.workspaces.active", "x");\nuser_pref("zen.workspaces.separate-essentials", false);\n')
        result = self.read_zen(['tabs', 'spaces', 'pinnedTabs', 'favorites'])
        self.assertEqual((result['failed'], result['warnings']), ([], []))
        self.assertIs(result['separateEssentials'], False)
        work, home, shop = result['spaces']
        self.assertEqual(shape(work['pinned']), [
            'Left', 'Right', 'Linear home', ('Docs', ['MDN', ('Inner', ['Inner'])]), 'Notes'])
        notes = work['pinned'][-1]
        self.assertEqual((notes['url'], notes['pageTitle']), ('https://notion.example/', 'Notion'))
        self.assertEqual(work['pinned'][2]['url'], 'https://linear.example/home')
        self.assertEqual((work['color'], work['colors'], work['emoji'], work['profileId']),
                         ('#AABBCC', ['#AABBCC', '#0A141E'], '💼', 'abcd.Work'))
        self.assertEqual([t['url'] for t in work['tabs']], ['https://news.example/'])
        self.assertEqual(work['tabs'][0], {'url': 'https://news.example/', 'title': 'News', 'pinned': False, 'windowIndex': 0,
                                           'active': False, 'lastActive': 1795065357225})
        self.assertNotIn('emoji', home)
        self.assertEqual(shape(home['pinned']), ['Home'])
        self.assertEqual((shop['name'], shop['container'], [t['url'] for t in shop['tabs']]),
                         ('Space 3', 2, ['https://shop.example/']))
        self.assertEqual([t['url'] for t in result['tabs']],
                         ['https://news.example/', 'https://reddit.example/r/linux', 'https://shop.example/'])
        self.assertEqual(result['favorites'], [
            {'url': 'https://mail.example/', 'title': 'Mail', 'pinned': True, 'windowIndex': 0, 'active': False},
            {'url': 'https://mail.example/', 'title': 'Mail at work', 'pinned': True, 'windowIndex': 0, 'active': False,
             'container': 2},
        ])
        icons = {i['page']: i for i in result['favicons']}
        self.assertEqual(sorted(icons), ['https://linear.example/home', 'https://mail.example/'])
        self.assertEqual(icons['https://mail.example/']['icon'], 'https://mail.example/favicon.ico')
        self.assertEqual(base64.b64decode(icons['https://mail.example/']['png']), PNG)
        progress = {(p['kind'], p['phase']): p['processed'] for p in self.json(
            'read', *self.env_args(), 'zen', 'abcd.Work', 'tabs,spaces,pinnedTabs,favorites', 0, 0, 0)['progress']}
        self.assertEqual((progress[('tabs', 'end')], progress[('spaces', 'end')], progress[('pinnedTabs', 'end')],
                          progress[('favorites', 'end')]), (3, 3, 7, 2))

    def test_session_icons_come_first_and_favicons_sqlite_fills_the_rest(self):
        profile = self.zen_profile(self.full_session())
        db = sqlite3.connect(profile / 'favicons.sqlite')
        db.execute('CREATE TABLE moz_icons(id INTEGER PRIMARY KEY, icon_url TEXT, width INTEGER, data BLOB)')
        db.execute('CREATE TABLE moz_pages_w_icons(id INTEGER PRIMARY KEY, page_url TEXT)')
        db.execute('CREATE TABLE moz_icons_to_pages(page_id INTEGER, icon_id INTEGER)')
        for index, page in enumerate(['https://mail.example/', 'https://news.example/'], start=1):
            db.execute('INSERT INTO moz_icons VALUES (?,?,?,?)', (index, f'{page}stored.ico', 32, STORED_PNG))
            db.execute('INSERT INTO moz_pages_w_icons VALUES (?,?)', (index, page))
            db.execute('INSERT INTO moz_icons_to_pages VALUES (?,?)', (index, index))
        db.commit()
        db.close()
        icons = {i['page']: i for i in self.read_zen(['spaces', 'tabs', 'favorites'])['favicons']}
        self.assertEqual(icons['https://mail.example/']['icon'], 'https://mail.example/favicon.ico')
        self.assertEqual(icons['https://news.example/']['icon'], 'https://news.example/stored.ico')
        self.assertEqual(base64.b64decode(icons['https://news.example/']['png']), STORED_PNG)

    def test_space_ids_pick_spaces_and_unasked_kinds_stay_empty(self):
        self.zen_profile(self.full_session())
        result = self.read_zen(['tabs', 'spaces'], space_ids=[HOME, '{gone}'])
        self.assertEqual([s['id'] for s in result['spaces']], [HOME])
        self.assertEqual(result['spaces'][0]['pinned'], [])
        self.assertEqual([t['url'] for t in result['tabs']], ['https://reddit.example/r/linux'])
        self.assertEqual(result['favorites'], [])
        result = self.read_zen(['spaces', 'pinnedTabs'], space_ids=[WORK])
        self.assertEqual([s['id'] for s in result['spaces']], [WORK])
        self.assertEqual(result['spaces'][0]['tabs'], [])
        self.assertEqual(len(shape(result['spaces'][0]['pinned'])), 5)
        self.assertEqual(result['tabs'], [])
        self.assertEqual(self.read_zen(['spaces'], space_ids=[])['spaces'], [])

    def test_separate_essentials_follows_prefs(self):
        profile = self.zen_profile(self.full_session())
        (profile / 'prefs.js').write_text('user_pref("zen.workspaces.separate-essentials", true);\n')
        self.assertIs(self.read_zen(['favorites'])['separateEssentials'], True)
        (profile / 'prefs.js').unlink()
        self.assertIs(self.read_zen(['favorites'])['separateEssentials'], True)

    def test_windows_sessions_skip_popups_and_the_newest_dated_backup_wins(self):
        profile = self.zen_profile()
        backups = profile / 'zen-sessions-backup'
        backups.mkdir()
        older = {'windows': [{'spaces': [space(WORK, 'Old')], 'tabs': [tab('https://old.example/', 'Old', WORK)]}]}
        newer = {'windows': [
            {'spaces': [space(WORK, 'Work')], 'tabs': [tab('https://new.example/', 'New', WORK)]},
            {'isPopup': True, 'spaces': [space(HOME, 'Popup')], 'tabs': [tab('https://popup.example/', 'Popup', HOME)]},
        ]}
        (backups / 'zen-sessions-20261101-1.jsonlz4').write_bytes(mozlz4(json.dumps(older)))
        (backups / 'zen-sessions-20261118-1.jsonlz4').write_bytes(mozlz4(json.dumps(newer)))
        (backups / 'notes.txt').write_text('ignored')
        result = self.read_zen(['spaces', 'tabs'])
        self.assertEqual([(s['name'], [t['url'] for t in s['tabs']]) for s in result['spaces']],
                         [('Work', ['https://new.example/'])])

    def test_a_malformed_session_falls_back_to_the_clean_backup(self):
        profile = self.zen_profile()
        (profile / 'zen-sessions.jsonlz4').write_bytes(b'not a session')
        (profile / 'zen-sessions-backup').mkdir()
        (profile / 'zen-sessions-backup' / 'clean.jsonlz4').write_bytes(
            mozlz4(json.dumps({'spaces': [space(HOME, 'Home')], 'tabs': [tab('https://clean.example/', 'Clean', HOME)]})))
        result = self.read_zen(['spaces', 'tabs'])
        self.assertEqual([t['url'] for t in result['tabs']], ['https://clean.example/'])

    def test_places_workspaces_stand_in_when_the_session_declares_no_spaces(self):
        profile = self.zen_profile({'tabs': [
            tab('https://pinned.example/', 'Pinned', HOME, pinned=True, sync='p1'),
            tab('https://open.example/', 'Open', WORK),
        ]})
        (profile / 'places.sqlite').unlink()
        db = sqlite3.connect(profile / 'places.sqlite')
        db.execute('CREATE TABLE zen_workspaces(id INTEGER PRIMARY KEY, uuid TEXT, name TEXT, icon TEXT, container_id INTEGER, '
                   'position INTEGER, created_at INTEGER, theme_colors TEXT)')
        db.executemany('INSERT INTO zen_workspaces(uuid, name, icon, container_id, position, created_at, theme_colors) VALUES (?,?,?,?,?,?,?)', [
            (HOME, 'Home', '🏡', 0, 2, 5, json.dumps([{'c': [255, 0, 0], 'isPrimary': True}])),
            (WORK, 'Work', None, 3, 1, 9, 'not json'),
            ('{unordered}', None, None, None, None, 1, None),
        ])
        db.commit()
        db.close()
        summaries = self.sources()['zen']['profiles'][0]['spaces']
        self.assertEqual(summaries, [
            {'id': WORK, 'name': 'Work', 'pinnedCount': 0, 'tabCount': 1, 'container': 3},
            {'id': HOME, 'name': 'Home', 'color': '#FF0000', 'emoji': '🏡', 'pinnedCount': 1, 'tabCount': 0},
            {'id': '{unordered}', 'name': 'Space 3', 'pinnedCount': 0, 'tabCount': 0},
        ])
        result = self.read_zen(['pinnedTabs', 'spaces'])
        self.assertEqual(shape(result['spaces'][1]['pinned']), ['Pinned'])

    def test_a_zen_profile_without_a_sidebar_warns_instead_of_failing(self):
        profile = self.zen_profile()
        sources = self.sources()
        self.assertEqual(sources['zen']['sidebar'], 'zen')
        self.assertNotIn('spaces', sources['zen']['profiles'][0])
        self.assertEqual(sources['zen']['profiles'][0]['available'], ['bookmarks', 'history'])
        result = self.read_zen(['spaces', 'pinnedTabs', 'favorites'])
        self.assertEqual(result['failed'], [])
        self.assertEqual([(w['kind'], w['code']) for w in result['warnings']],
                         [('spaces', 'empty'), ('pinnedTabs', 'empty'), ('favorites', 'empty')])
        self.assertNotIn('separateEssentials', result)

        (profile / 'zen-sessions.jsonlz4').write_bytes(b'mozLz40\0garbage')
        result = self.read_zen(['spaces', 'pinnedTabs', 'tabs'])
        self.assertEqual(result['failed'], [])
        self.assertEqual([(w['kind'], w['code']) for w in result['warnings']],
                         [('tabs', 'empty'), ('spaces', 'empty'), ('pinnedTabs', 'empty')])

        (profile / 'zen-sessions.jsonlz4').write_bytes(mozlz4('{"tabs": [], "spaces": []}'))
        result = self.read_zen(['spaces', 'favorites'])
        self.assertEqual(result['failed'], [])
        self.assertEqual([(w['kind'], w['code']) for w in result['warnings']], [('spaces', 'empty')])
        self.assertIs(result['separateEssentials'], True)

    def test_zen_without_spaces_still_reads_its_firefox_session_tabs(self):
        profile = self.zen_profile()
        session = {'windows': [{'tabs': [{'entries': [{'url': 'https://ff.example/', 'title': 'FF'}], 'index': 1}]}]}
        (profile / 'sessionstore.jsonlz4').write_bytes(mozlz4(json.dumps(session)))
        result = self.read_zen(['tabs'])
        self.assertEqual([t['url'] for t in result['tabs']], ['https://ff.example/'])
        self.assertEqual(result['spaces'], [])

    def test_firefox_keeps_its_session_tabs_and_has_no_sidebar_kinds(self):
        root = self.home / '.mozilla' / 'firefox'
        profile = root / 'abcd.default'
        profile.mkdir(parents=True)
        (root / 'profiles.ini').write_text('[Profile0]\nName=default\nIsRelative=1\nPath=abcd.default\n')
        session = {'windows': [{'spaces': [space(WORK, 'Work')],
                                'tabs': [{'entries': [{'url': 'https://ff.example/', 'title': 'FF'}], 'index': 1, 'zenWorkspace': WORK}]}]}
        (profile / 'zen-sessions.jsonlz4').write_bytes(mozlz4(json.dumps(session)))
        (profile / 'sessionstore.jsonlz4').write_bytes(mozlz4(json.dumps(session)))
        firefox = self.sources()['firefox']
        self.assertNotIn('sidebar', firefox)
        self.assertEqual(firefox['profiles'][0]['available'], ['tabs'])
        self.assertNotIn('spaces', firefox['profiles'][0])
        result = self.read_zen(['tabs', 'spaces', 'pinnedTabs', 'favorites'], profile='abcd.default', browser='firefox')
        self.assertEqual([t['url'] for t in result['tabs']], ['https://ff.example/'])
        self.assertEqual((result['spaces'], result['favorites']), ([], []))
        self.assertEqual(result['failed'], ['spaces', 'pinnedTabs', 'favorites'])
        self.assertNotIn('separateEssentials', result)

    def test_a_session_with_thousands_of_folders_keeps_the_first_2048_and_stays_fast(self):
        folders = [zen_folder(f'f{i}', f'Folder {i}', WORK) for i in range(20000)]
        self.zen_profile({'windows': [{'spaces': [space(WORK, 'Work')], 'folders': folders, 'tabs': []}]})
        summary = self.sources()['zen']['profiles'][0]['spaces'][0]
        self.assertEqual((summary['name'], summary['pinnedCount']), ('Work', 0))
        pinned = self.read_zen(['spaces', 'pinnedTabs'])['spaces'][0]['pinned']
        self.assertEqual(len(pinned), 2048)
        self.assertEqual((pinned[0]['title'], pinned[-1]['title']), ('Folder 0', 'Folder 2047'))

    def test_spaces_stop_at_256_and_tabs_at_5000(self):
        spaces = [space(f'{{s{i}}}', f'Space {i}') for i in range(300)]
        tabs = [tab(f'https://t{i}.example/', f'T{i}', '{s0}', sync=f't{i}') for i in range(6000)]
        self.zen_profile({'windows': [{'spaces': spaces, 'tabs': tabs}]})
        summaries = self.sources()['zen']['profiles'][0]['spaces']
        self.assertEqual((len(summaries), summaries[-1]['name'], summaries[0]['tabCount']), (256, 'Space 255', 5000))
        self.assertEqual(len(self.read_zen(['tabs'], space_ids=['{s0}'])['tabs']), 5000)

    def test_tabs_and_folders_of_spaces_past_the_cap_stay_out(self):
        spaces = [space(f'{{s{i}}}', f'Space {i}') for i in range(258)]
        tabs = [tab('https://kept.example/', 'Kept', '{s0}', sync='k'),
                tab('https://dropped.example/', 'Dropped', '{s257}', sync='d'),
                tab('https://dropped-pin.example/', 'Dropped pin', '{s257}', pinned=True, sync='dp', group='late'),
                tab('https://nested-pin.example/', 'Nested pin', pinned=True, sync='np', group='inner')]
        folders = [zen_folder('inner', 'Inner', parent='late'), zen_folder('late', 'Late', '{s257}')]
        spaces.append(space('{' + 'x' * 300 + '}', 'Too long'))
        spaces.insert(1, space('{' + 'y' * 300 + '}', 'Too long first'))
        self.zen_profile({'windows': [{'spaces': spaces, 'tabs': tabs, 'folders': folders}]})
        self.assertNotIn('Too long first', [s['name'] for s in self.sources()['zen']['profiles'][0]['spaces']])
        result = self.read_zen(['spaces', 'pinnedTabs', 'tabs'])
        self.assertEqual(len(result['spaces']), 256)
        self.assertEqual([t['url'] for t in result['tabs']], ['https://kept.example/'])
        self.assertEqual([n for s in result['spaces'] for n in s['pinned']], [])

    def test_left_out_spaces_keep_their_tabs_out_past_the_long_id_depth_and_folder_limits(self):
        long_id = '{' + 'z' * 300 + '}'
        spaces = [space('{s0}', 'Kept'), space(long_id, 'Too long')] + [space(f'{{s{i}}}', f'Space {i}') for i in range(1, 258)]
        chain = [zen_folder(f'c{i}', f'C{i}', '{s257}' if i == 0 else None, parent=None if i == 0 else f'c{i - 1}') for i in range(34)]
        filler = [zen_folder(f'f{i}', f'F{i}', '{s0}') for i in range(2048)]
        folders = list(reversed(chain)) + filler + [zen_folder('late', 'Late', '{s257}')]
        tabs = [tab('https://kept.example/', 'Kept', '{s0}', sync='k'),
                tab('https://long.example/', 'Long', long_id, sync='l'),
                tab('https://deep.example/', 'Deep', pinned=True, sync='d', group='c33'),
                tab('https://late.example/', 'Late', pinned=True, sync='a', group='late')]
        self.zen_profile({'windows': [{'spaces': spaces, 'tabs': tabs, 'folders': folders}]})
        result = self.read_zen(['spaces', 'pinnedTabs', 'tabs'], space_ids=['{s0}'])
        self.assertEqual([t['url'] for t in result['tabs']], ['https://kept.example/'])
        links = [n.get('url') for s in result['spaces'] for n in s['pinned'] if n['type'] == 'url']
        self.assertEqual(links, [])
        self.assertEqual(len(result['spaces'][0]['pinned']), 2048)

    def test_stored_workspaces_are_scanned_up_to_a_bound(self):
        profile = self.zen_profile({'tabs': [tab('https://open.example/', 'Open', '{w4095}')]})
        (profile / 'places.sqlite').unlink()
        db = sqlite3.connect(profile / 'places.sqlite')
        db.execute('CREATE TABLE zen_workspaces(id INTEGER PRIMARY KEY, uuid TEXT, name TEXT, icon TEXT, container_id INTEGER, '
                   'position INTEGER, created_at INTEGER, theme_colors TEXT)')
        green = [{'c': [0, 255, 0], 'isPrimary': True}]
        themes = {4095: json.dumps(green + [{'pad': 'x' * 70000}]), 4094: json.dumps(green)}
        db.executemany('INSERT INTO zen_workspaces(uuid, name, position, created_at, theme_colors) VALUES (?,?,?,?,?)',
                       [(f'{{w{i}}}', f'W{i}', 5000 - i, i, themes.get(i)) for i in range(5000)])
        db.commit()
        db.close()
        summaries = self.sources()['zen']['profiles'][0]['spaces']
        self.assertEqual((len(summaries), summaries[0]['name'], summaries[0]['tabCount'], summaries[-1]['name']), (256, 'W4095', 1, 'W3840'))
        self.assertNotIn('color', summaries[0])
        self.assertEqual(summaries[1]['color'], '#00FF00')

    def test_left_out_spaces_keep_their_essentials_and_leave_no_empty_folders(self):
        spaces = [space(f'{{s{i}}}', f'Space {i}') for i in range(258)]
        tabs = [tab('https://essential.example/', 'Essential', '{s257}', essential=True, sync='e'),
                tab('https://loose.example/', 'Loose', '{s257}', pinned=True, sync='l', group='loose')]
        tabs.append(tab('https://nested.example/', 'Nested', '{s257}', pinned=True, sync='n', group='child'))
        tabs.append(tab('https://kept-pin.example/', 'Kept pin', '{s0}', pinned=True, sync='kp', group='kept'))
        tabs.append(tab('https://inner.example/', 'Inner', '{s257}', pinned=True, sync='i', group='inner'))
        tabs.append(tab('https://open-kept.example/', 'Open kept', '{s0}', sync='ok', group='late'))
        tabs.append(tab('https://open-gone.example/', 'Open gone', '{s257}', sync='og', group='kept'))
        folders = [zen_folder('loose', 'Loose folder'), zen_folder('root', 'Root'), zen_folder('child', 'Child', parent='root'),
                   zen_folder('kept', 'Kept'), zen_folder('empty', 'Empty', '{s0}'),
                   zen_folder('outer', 'Outer', '{s0}'), zen_folder('inner', 'Inner', parent='outer'), zen_folder('late', 'Late', '{s257}')]
        self.zen_profile({'windows': [{'spaces': spaces, 'tabs': tabs, 'folders': folders}]})
        result = self.read_zen(['spaces', 'pinnedTabs', 'tabs', 'favorites'])
        self.assertEqual(shape(result['spaces'][0]['pinned']), [('Kept', ['Kept pin']), ('Empty', [])])
        self.assertEqual([t['url'] for t in result['tabs']], ['https://open-kept.example/'])
        result['spaces'][0]['pinned'] = []
        self.assertEqual([t['url'] for t in result['favorites']], ['https://essential.example/'])
        self.assertEqual([n for s in result['spaces'] for n in s['pinned']], [])

    def test_the_flatpak_brings_its_sidebar_too(self):
        flatpak = self.home / '.var' / 'app' / 'app.zen_browser.zen' / '.zen'
        profile = flatpak / 'abcd.Work'
        profile.mkdir(parents=True)
        (flatpak / 'profiles.ini').write_text('[Profile0]\nName=Work\nIsRelative=1\nPath=abcd.Work\n')
        (profile / 'places.sqlite').write_bytes(b'')
        (profile / 'zen-sessions.jsonlz4').write_bytes(mozlz4(json.dumps(self.full_session())))
        source = self.sources()['zenFlatpak']
        self.assertEqual(source['sidebar'], 'zen')
        result = self.read_zen(['spaces', 'pinnedTabs', 'tabs', 'favorites'], browser='zenFlatpak')
        self.assertEqual(result['failed'], [])
        self.assertEqual([s['name'] for s in result['spaces']], [s['name'] for s in source['profiles'][0]['spaces']])
        self.assertTrue(result['favorites'])

    def test_space_ids_are_validated_with_count_and_length_caps(self):
        def check(value):
            path = self.root / 'ids.json'
            path.write_text(json.dumps(value))
            return self.json('space-ids', path)

        self.assertEqual(check(None), {'valid': True})
        self.assertEqual(check([WORK, WORK, HOME]), {'valid': True, 'ids': [WORK, HOME]})
        self.assertEqual(check([]), {'valid': True, 'ids': []})
        self.assertEqual(check('x'), {'valid': False})
        self.assertEqual(check([WORK, 3]), {'valid': False})
        self.assertEqual(check(['']), {'valid': False})
        self.assertEqual(check(['x' * 257]), {'valid': False})
        self.assertEqual(check(['x' * 256])['valid'], True)
        self.assertEqual(check([f'{{s{i}}}' for i in range(257)]), {'valid': False})


if __name__ == '__main__':
    unittest.main()
