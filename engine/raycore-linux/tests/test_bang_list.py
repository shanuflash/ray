import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src'
LINUX = SOURCE / 'ray/linux'
REPO = ROOT.parents[1]


class BangListTests(unittest.TestCase):
    def test_the_policy_bounds_the_etag_the_reply_and_the_fetches_in_flight(self):
        with tempfile.TemporaryDirectory(prefix='ray-bang-list-') as directory:
            binary = Path(directory) / 'bang-list'
            subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++20', '-Wall', '-Wextra', '-Werror', '-g',
                            '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I', str(SOURCE),
                            str(ROOT / 'tests/bang_list_policy_test.cc'), '-o', str(binary)],
                           check=True, text=True, timeout=180)
            result = subprocess.run([str(binary)], text=True, timeout=60, capture_output=True,
                                    env={**os.environ, 'UBSAN_OPTIONS': 'halt_on_error=1'})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout, 'ok\n')

    def test_the_url_limit_and_reply_are_the_macs(self):
        mac = (REPO / 'packages/shell/ios/BangListFetch.swift').read_text()
        policy = (LINUX / 'ac_linux_bang_list_policy.h').read_text()
        self.assertIn('URL(string: "https://services.helium.imput.net/bangs.json")!', mac)
        self.assertIn('kListUrl = "https://services.helium.imput.net/bangs.json"', policy)
        self.assertIn('static let maxBytes = 5_000_000', mac)
        self.assertIn("kMaxBytes = 5'000'000", policy)
        self.assertIn('etag.count <= 200', mac)
        self.assertIn('kMaxEtagBytes = 200', policy)
        self.assertIn('promise.reject("ERR_BANG_LIST"', (REPO / 'packages/shell/ios/ShellModule.swift').read_text())
        self.assertIn('kErrorCode[] = "ERR_BANG_LIST"', policy)
        shared = (REPO / 'packages/shell/src/documents.ts').read_text()
        self.assertIn('export type BangListReply = { status: number; etag: string | null; contentType: string | null; body: string | null; bytes: number };', shared)
        glue = (LINUX / 'ac_linux_bang_list.cc').read_text()
        for key in ('"status"', '"etag"', '"contentType"', '"body"', '"bytes"'):
            self.assertEqual(glue.count(f'.Set({key},'), 1)

    def test_the_fetch_goes_only_to_the_list_without_cookies_cache_or_redirects(self):
        glue = (LINUX / 'ac_linux_bang_list.cc').read_text()
        self.assertEqual(glue.count('GURL('), 1)
        load = glue[glue.index('void Load('):glue.index('void OnLoaded(')]
        for line in ('request->url = GURL(bang_list::kListUrl);', 'request->method = "GET";',
                     'request->credentials_mode = network::mojom::CredentialsMode::kOmit;',
                     'request->redirect_mode = network::mojom::RedirectMode::kError;',
                     'request->load_flags = net::LOAD_DISABLE_CACHE;',
                     'if (bang_list::EtagSent(etag)) request->headers.SetHeader(net::HttpRequestHeaders::kIfNoneMatch, etag);',
                     'loader_->SetTimeoutDuration(base::Seconds(bang_list::kTimeoutSeconds));'):
            self.assertIn(line, load)
        self.assertIn('bang_list::kMaxBytes);', load)
        self.assertIn('manager->GetSharedURLLoaderFactory()', glue)
        self.assertIn('cookies_allowed: NO', glue)
        fetch = glue[glue.index('void FetchLinuxBangList('):]
        self.assertLess(fetch.index('if (BackgroundInstance())'), fetch.index('SystemLoaderFactory()'))
        self.assertLess(fetch.index('bang_list::Admits('), fetch.index('SystemLoaderFactory()'))
        loaded = glue[glue.index('void OnLoaded('):glue.index('Done done_;')]
        self.assertLess(loaded.index('Done done = std::move(done_);'), loaded.index('std::erase_if(Running()'))
        self.assertNotIn('done_', loaded[loaded.index('std::erase_if(Running()'):])
        self.assertNotIn('loader_', loaded[loaded.index('std::erase_if(Running()'):])

    def test_the_host_advertises_and_routes_the_call(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        self.assertIn('capabilities.Append("RayShell.fetchBangList");', host)
        self.assertIn('if (method == ray::linux_bang_list::kCall) return raycore::FetchLinuxBangList(values, std::move(done));', host)
        self.assertIn('kCall[] = "RayShell.fetchBangList"', (LINUX / 'ac_linux_bang_list_policy.h').read_text())
        build = (LINUX / 'BUILD.gn').read_text()
        for name in ('ac_linux_bang_list.cc', 'ac_linux_bang_list.h', 'ac_linux_bang_list_policy.h'):
            self.assertIn(f'"{name}"', build)
        self.assertIn('["RayShell.fetchBangList", 75000],', (LINUX / 'bootstrap.js').read_text())
        self.assertIn('kTimeoutSeconds = 60;', (LINUX / 'ac_linux_bang_list_policy.h').read_text())
        modules = (REPO / 'apps/linux/src/hostModules.ts').read_text()
        self.assertIn('if (name === "RayShell" && !hostSupports(`${name}.${method}`, host)) {', modules)


if __name__ == '__main__':
    unittest.main()
