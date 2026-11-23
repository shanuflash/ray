import gzip
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src'
LINUX = SOURCE / 'ray/linux'
REPO = ROOT.parents[1]


class ReportCoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which(os.environ.get('CXX', 'c++'))
        if compiler is None:
            raise unittest.SkipTest('C++ compiler is unavailable')
        cls.directory = tempfile.TemporaryDirectory(prefix='ray-report-')
        root = Path(cls.directory.name)
        shim = root / 'include/third_party/zlib'
        shim.mkdir(parents=True)
        (shim / 'zlib.h').write_text('#include <zlib.h>\n')
        cls.binary = root / 'report-core'
        compiled = subprocess.run([compiler, '-std=c++20', '-Wall', '-Wextra', '-Werror', '-g',
                                   '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
                                   '-I', str(root / 'include'), '-I', str(SOURCE),
                                   str(ROOT / 'tests/report_core_test.cc'), str(LINUX / 'ac_linux_report_core.cc'),
                                   '-lz', '-o', str(cls.binary)], capture_output=True, text=True, timeout=300)
        if compiled.returncode != 0:
            if 'zlib.h' in compiled.stderr or 'cannot find -lz' in compiled.stderr:
                raise unittest.SkipTest('zlib development files are unavailable')
            raise AssertionError(compiled.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def run_binary(self, *args):
        result = subprocess.run([str(self.binary), *[str(arg) for arg in args]], capture_output=True, text=True, timeout=120,
                                env={**os.environ, 'UBSAN_OPTIONS': 'halt_on_error=1'})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def test_paths_urls_headers_caps_and_replies(self):
        self.assertEqual(self.run_binary(), 'ok\n')

    def test_gzip_writes_a_stream_gunzip_reads_back_for_empty_small_and_multi_chunk_input(self):
        scratch = Path(self.directory.name)
        samples = {'empty': b'', 'small': 'héllo, report\n'.encode(), 'chunks': os.urandom(200_000) + b'a' * 300_000}
        for name, data in samples.items():
            with self.subTest(name=name):
                source = scratch / f'{name}.bin'
                destination = scratch / f'{name}.gz'
                source.write_bytes(data)
                written = int(self.run_binary('gzip', source, destination))
                self.assertEqual(written, destination.stat().st_size)
                self.assertEqual(gzip.decompress(destination.read_bytes()), data)

    def test_the_caps_names_ids_and_json_limit_are_the_feedback_services(self):
        core = (LINUX / 'ac_linux_report_core.cc').read_text()
        header = (LINUX / 'ac_linux_report_core.h').read_text()
        validate = (REPO / 'infra/feedback/lib/validate.mjs').read_text()
        self.assertIn('export const MAX_JSON_BYTES = 128 * 1024;', validate)
        self.assertIn('kJsonMaxBytes = 128 * 1024;', header)
        for name, cap in (('recording.mp4', 100), ('trace.json.gz', 50), ('local-events.jsonl.gz', 10)):
            self.assertIn(f'if (name === "{name}") return {{', validate)
            self.assertRegex(validate, re.escape(f'if (name === "{name}")') + r'[^\n]*cap: ' + str(cap) + r' \* MIB')
            self.assertIn(f'if (name == "{name}") return {cap} * kMiB;', core)
        self.assertIn(r'/^crash-[1-9][0-9]?\.ips$/', validate)
        self.assertIn(r'/^attachment-[1-9][0-9]?\.[a-z0-9]{1,8}$/', validate)
        self.assertIn('export const ID_PATTERN = /^FB-[2-9A-HJ-NP-Z]{4,5}$/;', (REPO / 'infra/feedback/lib/ids.mjs').read_text())
        actions = (REPO / 'apps/browser/src/state/report/actions.ts').read_text()
        self.assertIn('export const FEEDBACK_URL = "https://github.com/shanuflash/ray/api/feedback";', actions)
        self.assertIn('kEndpoint[] = "https://github.com/shanuflash/ray/api/feedback";', header)
        self.assertIn('export const INGEST_KEY_HEADER = "X-Ray-Key";', (REPO / 'packages/core/src/ingestKeys.ts').read_text())

    def test_the_mac_uploader_gives_the_reply_shape_and_limits(self):
        uploader = (REPO / 'packages/shell/ios/ReportUploader.swift').read_text()
        header = (LINUX / 'ac_linux_report_core.h').read_text()
        self.assertIn('upload.body.prefix(4096)', uploader)
        self.assertIn('kUploadReplyMaxBytes = 4096;', header)
        self.assertIn('configuration.timeoutIntervalForResource = 15 * 60', uploader)
        self.assertIn('kUploadTimeoutSeconds = 15 * 60;', header)
        self.assertIn('error.map { cancelled ? "cancelled" : $0.localizedDescription }', uploader)
        files = (REPO / 'packages/shell/ios/ReportFiles.swift').read_text()
        self.assertIn('deflateInit2_(&stream, 6, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY', files)
        self.assertIn('deflateInit2(&stream, 6, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY)', (LINUX / 'ac_linux_report_core.cc').read_text())
        self.assertIn('DocumentStore.url("Report Drafts")', files)
        self.assertIn('kDraftsFolder[] = "Report Drafts";', header)


class ReportHostTests(unittest.TestCase):
    def setUp(self):
        self.service = (LINUX / 'ac_linux_report.cc').read_text()
        self.host = (LINUX / 'ac_linux_host.cc').read_text()

    def body(self, start, end):
        return self.service[self.service.index(start):self.service.index(end)]

    def test_every_path_is_checked_as_given_and_again_once_symlinks_are_resolved(self):
        existing = self.body('std::optional<base::FilePath> ExistingDraftPath(', 'std::optional<base::FilePath> NewDraftPath(')
        self.assertLess(existing.index('if (!report::InsideDrafts(drafts.value(), path)) return std::nullopt;'),
                        existing.index('RealPath(base::FilePath(path))'))
        self.assertIn('!report::InsideDrafts(real_drafts->value(), real->value())', existing)
        fresh = self.body('std::optional<base::FilePath> NewDraftPath(', 'std::optional<std::string> CreateDraft(')
        self.assertLess(fresh.index('if (!report::InsideDrafts(drafts.value(), path)) return std::nullopt;'),
                        fresh.index('RealPath(given.DirName())'))
        self.assertIn('if (!report::InsideDrafts(real_drafts->value(), real.value()) || base::IsLink(real)) return std::nullopt;', fresh)
        remove = self.body('bool RemovePath(', 'double GzipInto(')
        self.assertLess(remove.index('if (!report::InsideDrafts(drafts.value(), path)) return false;'),
                        remove.index('RealPath(given.DirName())'))
        self.assertLess(remove.index('if (!report::InsideDrafts(real_drafts->value(), real.value())) return false;'),
                        remove.index('return base::DeletePathRecursively(real);'))
        self.assertIn('ExistingDraftPath(DraftsFolder(documents), path)', self.body('double FileSize(', 'bool RemovePath('))
        gzip_file = self.body('double GzipFile(', 'double GzipText(')
        self.assertIn('ExistingDraftPath(drafts, source)', gzip_file)
        self.assertIn('NewDraftPath(drafts, destination)', gzip_file)
        self.assertIn('NewDraftPath(DraftsFolder(documents), destination)', self.body('double GzipText(', 'struct UploadFile {'))
        self.assertIn('ExistingDraftPath(DraftsFolder(documents), path)', self.body('UploadFile FindUploadFile(', 'scoped_refptr<network::SharedURLLoaderFactory> SystemLoaderFactory()'))
        self.assertIn('base::FilePath real = base::MakeAbsoluteFilePath(path);', self.service)
        for banned in ('GetTempDir', 'CreateTemporaryFile', 'PathService', 'NormalizeFilePath'):
            self.assertNotIn(banned, self.service)

    def test_a_draft_is_a_private_uuid_folder_under_the_profiles_documents(self):
        draft = self.body('std::optional<std::string> CreateDraft(', 'double FileSize(')
        self.assertIn('documents.AppendASCII(report::kDraftsFolder)', self.service)
        self.assertIn('drafts.AppendASCII(base::Uuid::GenerateRandomV4().AsLowercaseString())', draft)
        self.assertEqual(draft.count('base::SetPosixFilePermissions('), 2)
        self.assertEqual(draft.count('0700'), 2)

    def test_a_json_post_reaches_only_create_and_complete_with_allowed_headers_and_a_bounded_body(self):
        post = self.body('void StartPost(', 'void StartUpload(')
        classify = post.index('report::ClassifyUrl(report::kEndpoint, args[0].GetString())')
        target = post.index('request.target != report::Target::kCreate && request.target != report::Target::kComplete')
        headers = post.index('report::AllowedHeaders(request.target, *given)')
        size = post.index('args[1].GetString().size() > report::kJsonMaxBytes')
        background = post.index('if (BackgroundInstance())')
        send = post.index('transfer->Post(')
        self.assertTrue(classify < target < headers < size < background < send)
        self.assertNotIn('GURL', post)

    def test_a_file_upload_reaches_only_a_report_file_url_with_put_and_a_file_inside_the_draft(self):
        upload = self.body('void StartUpload(', 'void ReplyWithBytes(')
        target = upload.index('request.target != report::Target::kFile || !report::MethodAllowed(request.target, args[2].GetString())')
        headers = upload.index('report::AllowedHeaders(request.target, *given)')
        background = upload.index('if (BackgroundInstance())')
        find = upload.index('base::BindOnce(&FindUploadFile, documents, args[4].GetString())')
        size = upload.index('if (!report::UploadSizeAllowed(request, file.bytes)) {')
        send = upload.index('transfer->Put(factory.get(), url, headers, file.path);')
        self.assertTrue(target < headers < background < find < size < send)

    def test_requests_carry_no_credentials_follow_no_redirect_and_answer_the_macs_shape(self):
        create = self.body('  void Create(', '  void Start(')
        for line in ('request->credentials_mode = network::mojom::CredentialsMode::kOmit;',
                     'request->redirect_mode = network::mojom::RedirectMode::kError;',
                     'request->load_flags = net::LOAD_DISABLE_CACHE;',
                     'loader_->SetAllowHttpErrorResults(true);', 'loader_->SetAllowPartialResults(true);'):
            self.assertIn(line, create)
        self.assertIn('request->url = GURL(url);', create)
        self.assertEqual(self.service.count('GURL('), 1)
        reply = self.body('base::Value Reply(', 'void Refuse(')
        for field in ('.Set("status", status)', '.Set("body", std::move(body))', '.Set("error", error ? base::Value(std::move(*error)) : base::Value())'):
            self.assertIn(field, reply)
        loaded = self.body('  void OnLoaded(', '  const int caller_;')
        self.assertIn('report::ReplyText(body ? *body : std::string(), reply_limit_)', loaded)
        self.assertIn('Reply(0, std::string(), net::ErrorToString(error))', loaded)
        progress = self.body('  void OnProgress(', '  void OnLoaded(')
        self.assertIn('.Set("type", "upload").Set("id", id_)', progress)
        self.assertIn('if (done_) std::move(done_).Run(true, Reply(0, std::string(), "cancelled"));', self.service)
        self.assertIn('| { type: "upload"; id: string; sent: number; total: number }', (REPO / 'packages/shell/src/report.ts').read_text())
        self.assertIn('export type UploadReply = { status: number; body: string; error?: string | null };', (REPO / 'packages/shell/src/report.ts').read_text())

    def test_the_host_routes_report_calls_with_its_documents_and_cancels_a_closed_windows_transfers(self):
        route = self.host[self.host.index('if (raycore::LinuxReportInvokes(method)) {'):]
        route = route[:route.index('if (raycore::LinuxNotificationsInvokes(method)) {')]
        self.assertIn('profile() ? DocumentDirectory(profile()) : base::FilePath(), id_,', route)
        self.assertIn('if (host) host->Event("RayReport", ray::linux_report::kEvent, std::move(event));', route)
        closing = self.host[self.host.index('ShellHostView::~ShellHostView() {'):]
        self.assertIn('raycore::LinuxReportCallerGone(id_);', closing[:closing.index('DropPlayer();')])
        self.assertIn('  if (!is_utility()) {\n    for (const char* capability : ray::linux_report::kReportCapabilities) capabilities.Append(capability);\n  }', self.host)
        header = (LINUX / 'ac_linux_report_core.h').read_text()
        self.assertIn('kReportCapabilities[] = {"report.files", "report.send"};', header)
        calls = header[header.index('kReportCalls[] = {'):]
        calls = calls[:calls.index('};')]
        for method in ('draftDirectory', 'fileSize', 'removeFile', 'gzipFile', 'gzipText', 'upload', 'post', 'cancelUploads'):
            self.assertIn(f'"RayReport.{method}"', calls)
            self.assertIn(f'"RayReport.{method}"', self.service)
        for refused in ('startRecording', 'stopRecording', 'cancelRecording', 'isRecording', 'recordingThumbnail'):
            self.assertNotIn(refused, calls)
            self.assertNotIn(refused, self.service)
        self.assertIn('std::ranges::any_of(report::kReportCalls,', self.service)

    def test_the_shell_keeps_its_own_answers_until_it_opts_in(self):
        fallbacks = (REPO / 'apps/linux/src/appModuleFallbacks.ts').read_text()
        self.assertIn('if (hostSupports(`${name}.${method}`, host)) return undefined;', fallbacks)
        header = (LINUX / 'ac_linux_report_core.h').read_text()
        advertised = header[header.index('kReportCapabilities[] = {'):header.index('};')]
        self.assertNotIn('RayReport.', advertised)
        build = (LINUX / 'BUILD.gn').read_text()
        for name in ('"ac_linux_report.cc"', '"ac_linux_report.h"', '"ac_linux_report_core.cc"', '"ac_linux_report_core.h"', '"//third_party/zlib"'):
            self.assertIn(name, build)


if __name__ == '__main__':
    unittest.main()
