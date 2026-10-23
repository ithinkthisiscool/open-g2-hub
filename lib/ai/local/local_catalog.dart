/// The curated on-device models (downloaded on demand, never bundled in the APK) and the
/// RAM-based recommendation.
///
/// Every file is pinned to an exact Hugging Face commit, and its SHA-256 is the one Hugging
/// Face publishes for that LFS object (`lfs.oid` in the repo tree API); downloads are rejected
/// unless they match. Only permissively licensed models are listed (Apache-2.0 / MIT).
///
/// LLMs run on llama.cpp (llamadart). Q4_0 is used on purpose: llama.cpp repacks Q4_0 at load
/// time into the ARM dot-product / i8mm layouts, which makes it the fastest 4-bit format on
/// phone CPUs. Speech models run on sherpa-onnx (Whisper, int8).
library;

enum LocalKind { llm, stt }

class ModelFile {
  const ModelFile(this.name, this.url, {required this.sha256, required this.sizeBytes});
  final String name;
  final String url;

  /// Lower-case hex; empty = unknown (custom models only: computed at import and stored).
  final String sha256;
  final int sizeBytes;

  Map<String, Object?> toJson() => {'name': name, 'url': url, 'sha256': sha256, 'size': sizeBytes};
  factory ModelFile.fromJson(Map<String, Object?> j) => ModelFile(
        (j['name'] ?? '').toString(),
        (j['url'] ?? '').toString(),
        sha256: (j['sha256'] ?? '').toString().toLowerCase(),
        sizeBytes: (j['size'] as num?)?.toInt() ?? 0,
      );
}

class LocalModelSpec {
  const LocalModelSpec({
    required this.id,
    required this.kind,
    required this.label,
    required this.licence,
    required this.files,
    required this.minRamBytes,
    this.licenceUrl = '',
    this.pageUrl = '',
    this.params = '',
    this.summary = '',
    this.speed = '',
    this.toolsCapable = false,
    this.custom = false,
    this.languages,
  });

  final String id;
  final LocalKind kind;
  final String label;
  final String licence;
  final String licenceUrl;
  final String pageUrl;
  final String params;
  final String summary;

  /// Expected generation speed on phones (estimate, shown in the UI).
  final String speed;
  final List<ModelFile> files;

  /// Total device RAM (MemTotal) below which the model is refused.
  final int minRamBytes;

  /// Big enough that grammar-constrained tool calls are worth offering (still experimental).
  final bool toolsCapable;
  final bool custom;

  /// Whisper language codes (null = any).
  final Set<String>? languages;

  int get sizeBytes => files.fold(0, (a, f) => a + f.sizeBytes);

  /// The file llama.cpp loads (LLMs have exactly one).
  ModelFile get main => files.first;

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.name,
        'label': label,
        'licence': licence,
        'licence_url': licenceUrl,
        'page_url': pageUrl,
        'params': params,
        'summary': summary,
        'files': [for (final f in files) f.toJson()],
        'min_ram': minRamBytes,
        'tools': toolsCapable,
      };

  factory LocalModelSpec.fromJson(Map<String, Object?> j) => LocalModelSpec(
        id: (j['id'] ?? '').toString(),
        kind: LocalKind.values.asNameMap()[j['kind']] ?? LocalKind.llm,
        label: (j['label'] ?? 'Custom model').toString(),
        licence: (j['licence'] ?? 'unknown (custom)').toString(),
        licenceUrl: (j['licence_url'] ?? '').toString(),
        pageUrl: (j['page_url'] ?? '').toString(),
        params: (j['params'] ?? '').toString(),
        summary: (j['summary'] ?? '').toString(),
        files: [for (final f in (j['files'] as List? ?? const [])) if (f is Map) ModelFile.fromJson(f.cast<String, Object?>())],
        minRamBytes: (j['min_ram'] as num?)?.toInt() ?? 0,
        toolsCapable: j['tools'] == true,
        custom: true,
      );
}

const int _gib = 1 << 30;
const int _mib = 1 << 20;

String _hf(String repo, String rev, String file) => 'https://huggingface.co/$repo/resolve/$rev/$file';

const String _qwenLicence = 'https://www.apache.org/licenses/LICENSE-2.0';

/// Curated chat models (llama.cpp GGUF). Apache-2.0 / MIT only.
final List<LocalModelSpec> llmCatalog = [
  LocalModelSpec(
    id: 'qwen3.5-0.8b-q4_0',
    kind: LocalKind.llm,
    label: 'Qwen3.5 0.8B',
    params: '0.8B · Q4_0',
    licence: 'Apache-2.0',
    licenceUrl: _qwenLicence,
    pageUrl: 'https://huggingface.co/Qwen/Qwen3.5-0.8B',
    summary: 'Smallest and fastest. Fine for short answers and simple translation; makes factual slips.',
    speed: 'about 20–60 tokens/s',
    minRamBytes: 3 * _gib,
    files: [
      ModelFile('Qwen3.5-0.8B-Q4_0.gguf',
          _hf('unsloth/Qwen3.5-0.8B-GGUF', '6ab461498e2023f6e3c1baea90a8f0fe38ab64d0', 'Qwen3.5-0.8B-Q4_0.gguf'),
          sha256: '444406ddd926550c724ec18d5120a9d40ded44908a063b0e66e9a7e5464c652c', sizeBytes: 507154688),
    ],
  ),
  LocalModelSpec(
    id: 'qwen3.5-2b-q4_0',
    kind: LocalKind.llm,
    label: 'Qwen3.5 2B',
    params: '2B · Q4_0',
    licence: 'Apache-2.0',
    licenceUrl: _qwenLicence,
    pageUrl: 'https://huggingface.co/Qwen/Qwen3.5-2B',
    summary: 'Good balance for 6 GB phones: better answers and translation, still quick.',
    speed: 'about 10–25 tokens/s',
    minRamBytes: 4 * _gib,
    toolsCapable: true,
    files: [
      ModelFile('Qwen3.5-2B-Q4_0.gguf',
          _hf('unsloth/Qwen3.5-2B-GGUF', 'f6d5376be1edb4d416d56da11e5397a961aca8ae', 'Qwen3.5-2B-Q4_0.gguf'),
          sha256: 'cd70221bebaee0503e0f6717e174250cd7825aa88438b3aabec9ad55731d9bb1', sizeBytes: 1214873856),
    ],
  ),
  LocalModelSpec(
    id: 'qwen3.5-4b-q4_0',
    kind: LocalKind.llm,
    label: 'Qwen3.5 4B',
    params: '4B · Q4_0',
    licence: 'Apache-2.0',
    licenceUrl: _qwenLicence,
    pageUrl: 'https://huggingface.co/Qwen/Qwen3.5-4B',
    summary: 'Best quality here, for 8 GB+ phones. Slower and warmer.',
    speed: 'about 5–12 tokens/s',
    minRamBytes: 6 * _gib,
    toolsCapable: true,
    files: [
      ModelFile('Qwen3.5-4B-Q4_0.gguf',
          _hf('unsloth/Qwen3.5-4B-GGUF', 'e87f176479d0855a907a41277aca2f8ee7a09523', 'Qwen3.5-4B-Q4_0.gguf'),
          sha256: '298fcb5fe7a77ccc79745ae24751560c5ac56874caff4bb39b1f2055bd72b8bb', sizeBytes: 2583221408),
    ],
  ),
  LocalModelSpec(
    id: 'phi-4-mini-q4_k_m',
    kind: LocalKind.llm,
    label: 'Phi-4-mini',
    params: '3.8B · Q4_K_M',
    licence: 'MIT',
    licenceUrl: 'https://huggingface.co/microsoft/Phi-4-mini-instruct/blob/main/LICENSE',
    pageUrl: 'https://huggingface.co/microsoft/Phi-4-mini-instruct',
    summary: 'Microsoft\'s small model (MIT). Strong in English; an alternative to Qwen3.5 4B.',
    speed: 'about 5–12 tokens/s',
    minRamBytes: 6 * _gib,
    toolsCapable: true,
    files: [
      ModelFile('Phi-4-mini-instruct-Q4_K_M.gguf',
          _hf('unsloth/Phi-4-mini-instruct-GGUF', '78eb92a46fc37e6b524df991ed9aca9bc6aa7b80', 'Phi-4-mini-instruct-Q4_K_M.gguf'),
          sha256: '88c00229914083cd112853aab84ed51b87bdf6b9ce42f532d8c85c7c63b1730a', sizeBytes: 2491874272),
    ],
  ),
];

const String _whisperTokensSha = 'b34b360dbb493e781e479794586d661700670d65564001f23024971d1f2fa126';
const String _tinyRev = '65176e2deb88badc814a94058666cadccc29b61c';
const String _baseRev = 'bb53ee204431c90d314c1cc08d28d23e5b7927cc';

/// Offline speech recognition models (sherpa-onnx, Whisper int8, multilingual, MIT).
final List<LocalModelSpec> sttCatalog = [
  LocalModelSpec(
    id: 'whisper-base-int8',
    kind: LocalKind.stt,
    label: 'Whisper base',
    params: '74M · int8',
    licence: 'MIT',
    licenceUrl: 'https://github.com/openai/whisper/blob/main/LICENSE',
    pageUrl: 'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-base',
    summary: 'Recommended. 99 languages; good accuracy for short commands.',
    speed: 'a 5 s question in about 1–2 s',
    minRamBytes: 2 * _gib,
    files: [
      ModelFile('base-encoder.int8.onnx', _hf('csukuangfj/sherpa-onnx-whisper-base', _baseRev, 'base-encoder.int8.onnx'),
          sha256: '0b8fb1304b6109976038efff5ace81720e00386f3ff6b54ee8c75291ca0a1e11', sizeBytes: 29120534),
      ModelFile('base-decoder.int8.onnx', _hf('csukuangfj/sherpa-onnx-whisper-base', _baseRev, 'base-decoder.int8.onnx'),
          sha256: '9759d217388a01b3a4c7c15533201067b48ae819c4daafc8624e64b9409dc02d', sizeBytes: 130672026),
      ModelFile('base-tokens.txt', _hf('csukuangfj/sherpa-onnx-whisper-base', _baseRev, 'base-tokens.txt'),
          sha256: _whisperTokensSha, sizeBytes: 816730),
    ],
  ),
  LocalModelSpec(
    id: 'whisper-tiny-int8',
    kind: LocalKind.stt,
    label: 'Whisper tiny',
    params: '39M · int8',
    licence: 'MIT',
    licenceUrl: 'https://github.com/openai/whisper/blob/main/LICENSE',
    pageUrl: 'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-tiny',
    summary: 'Smallest and fastest; less accurate, especially outside English.',
    speed: 'a 5 s question in under 1 s',
    minRamBytes: 2 * _gib,
    files: [
      ModelFile('tiny-encoder.int8.onnx', _hf('csukuangfj/sherpa-onnx-whisper-tiny', _tinyRev, 'tiny-encoder.int8.onnx'),
          sha256: 'd24fb083ae3b1041fc24e97971d60e280c9342201fbb67b0ab428a8b4a51a434', sizeBytes: 12937772),
      ModelFile('tiny-decoder.int8.onnx', _hf('csukuangfj/sherpa-onnx-whisper-tiny', _tinyRev, 'tiny-decoder.int8.onnx'),
          sha256: 'd2fece8dd42771f1df975c6c0445770d0c292bf7547c2cae04a6c0cc57540925', sizeBytes: 89855401),
      ModelFile('tiny-tokens.txt', _hf('csukuangfj/sherpa-onnx-whisper-tiny', _tinyRev, 'tiny-tokens.txt'),
          sha256: _whisperTokensSha, sizeBytes: 816730),
    ],
  ),
];

LocalModelSpec? catalogById(String id) =>
    [...llmCatalog, ...sttCatalog].where((m) => m.id == id).firstOrNull;

/// The chat model to suggest for a phone with [ramBytes] of RAM (MemTotal; null = unknown).
/// Phones report less than their marketed size (an "8 GB" phone shows about 7.3 GiB):
///   < 5 GiB  (3–4 GB phones)  → Qwen3.5 0.8B
///   < 7 GiB  (6 GB phones)    → Qwen3.5 2B
///   ≥ 7 GiB  (8 GB and more)  → Qwen3.5 4B
LocalModelSpec recommendLlm(int? ramBytes) {
  String id;
  if (ramBytes == null || ramBytes < 5 * _gib) {
    id = 'qwen3.5-0.8b-q4_0';
  } else if (ramBytes < 7 * _gib) {
    id = 'qwen3.5-2b-q4_0';
  } else {
    id = 'qwen3.5-4b-q4_0';
  }
  return llmCatalog.firstWhere((m) => m.id == id);
}

LocalModelSpec recommendStt(int? ramBytes) =>
    sttCatalog.firstWhere((m) => m.id == (ramBytes != null && ramBytes < 3 * _gib ? 'whisper-tiny-int8' : 'whisper-base-int8'));

String formatBytes(int b) => b >= _gib
    ? '${(b / _gib).toStringAsFixed(1)} GB'
    : b >= _mib
        ? '${(b / _mib).round()} MB'
        : '${(b / 1024).round()} KB';
