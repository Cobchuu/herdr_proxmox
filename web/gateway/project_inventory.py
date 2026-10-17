"""Bounded inventory of a managed project: what is in it, before asking what it needs.

Discovery has to work for a repository nobody has described in advance, so the
first step is a cheap, deterministic census of *names*: no file contents, no
repository code, no network. Everything later — requirements, checks, readiness
— is derived from this, so it must stay bounded, and it must report what it
could not establish as clearly as what it could.

Three deliberate limits:

* Symlinks are never followed. A listing is not a security boundary on its own,
  but a link out of the projects root would attribute another directory's files
  to this project. Reading contents later uses the anchored-descriptor pattern
  in `project_explorer`, because a read *is* a boundary crossing.
* Ignored directories are a documented default, not a rule. Dependency trees and
  build output would otherwise dominate the census and recommend tools that only
  a lockfile's transitive dependencies use.
* An ambiguous extension is reported as ambiguous. `.m` is MATLAB or
  Objective-C, `.pl` is Perl or Prolog, `.v` is Verilog, V or Coq — and those
  need entirely different toolchains. Guessing one would be worse than saying
  nothing, because a wrong answer here becomes a wrong requirement later.

Coverage is part of the answer, not a footnote. A census says how many files it
saw, how many it classified, and how many it could not: "no languages found" and
"found files, understood none" are different facts, and only one of them is a
reason to stop looking.
"""
import os
import time
from pathlib import Path, PurePosixPath

# Dependency trees, build output, caches and VCS metadata. Vendor directories
# are ignored because their contents are somebody else's project.
IGNORED = frozenset((
    '.git', '.hg', '.svn', '.dart_tool', '.venv', 'venv', '.tox', '.nox',
    '__pycache__', 'node_modules', 'bower_components', 'vendor', 'Pods',
    'target', 'dist', 'out', 'build', '.next', '.nuxt', '.svelte-kit', '.output',
    'coverage', '.cache', '.gradle', '.terraform', '.mypy_cache', '.pytest_cache',
    '.ruff_cache', '.parcel-cache', '.turbo', 'DerivedData', '.bundle', 'obj',
))

MAX_PATHS = 50_000
MAX_SECONDS = 5.0
MAX_PER_DIRECTORY = 5_000
MAX_DEPTH = 64
EVIDENCE_LIMIT = 5
# Unknown paths are an inspectable coverage sample, bounded independently of
# per-language examples so small groups can be shown in full without sending
# tens of thousands of filenames in every analysis response.
UNKNOWN_EVIDENCE_LIMIT = 50

# Language recognition. A maintained database (GitHub Linguist's `languages.yml`)
# is the intended replacement: this table is the shape that data takes, kept
# small enough to review. Manifest-free projects are recognised from these
# extensions alone, which is why breadth here matters more than depth.
LANGUAGES = {
    'php': ('PHP', ('php', 'phtml', 'php3', 'php4', 'php5', 'phps')),
    'javascript': ('JavaScript', ('js', 'mjs', 'cjs', 'jsx')),
    'typescript': ('TypeScript', ('ts', 'tsx', 'mts', 'cts')),
    'python': ('Python', ('py', 'pyi', 'pyw')),
    'ruby': ('Ruby', ('rb', 'rake', 'gemspec', 'ru')),
    'go': ('Go', ('go',)),
    'rust': ('Rust', ('rs',)),
    'java': ('Java', ('java',)),
    'kotlin': ('Kotlin', ('kt', 'kts')),
    'scala': ('Scala', ('scala',)),
    'csharp': ('C#', ('cs', 'csx')),
    'fsharp': ('F#', ('fsx', 'fsi')),
    'vbnet': ('Visual Basic', ('vb',)),
    'c': ('C', ('c',)),
    'cpp': ('C++', ('cc', 'cpp', 'cxx', 'c++', 'hpp', 'hh', 'hxx', 'h++')),
    'objectivec': ('Objective-C', ('mm',)),
    'swift': ('Swift', ('swift',)),
    'matlab': ('MATLAB', ('mlx',)),
    'dart': ('Dart', ('dart',)),
    'shell': ('Shell', ('sh', 'bash', 'zsh', 'ksh', 'fish')),
    'powershell': ('PowerShell', ('ps1', 'psm1', 'psd1')),
    'perl': ('Perl', ('pm',)),
    'lua': ('Lua', ('lua',)),
    'julia': ('Julia', ('jl',)),
    'elixir': ('Elixir', ('ex', 'exs')),
    'erlang': ('Erlang', ('erl', 'hrl')),
    'haskell': ('Haskell', ('hs', 'lhs')),
    'clojure': ('Clojure', ('clj', 'cljs', 'cljc', 'edn')),
    'sql': ('SQL', ('sql',)),
    'html': ('HTML', ('html', 'htm', 'xhtml')),
    'css': ('CSS', ('css',)),
    'scss': ('SCSS', ('scss', 'sass')),
    'less': ('Less', ('less',)),
    'vue': ('Vue', ('vue',)),
    'svelte': ('Svelte', ('svelte',)),
    'astro': ('Astro', ('astro',)),
    'markdown': ('Markdown', ('md', 'markdown', 'mdx')),
    'yaml': ('YAML', ('yml', 'yaml')),
    'json': ('JSON', ('json', 'jsonc')),
    'toml': ('TOML', ('toml',)),
    'xml': ('XML', ('xml',)),
    'terraform': ('Terraform', ('tf', 'tfvars')),
    'dockerfile': ('Dockerfile', ('containerfile',)),
    'protobuf': ('Protocol Buffers', ('proto',)),
    'graphql': ('GraphQL', ('graphql', 'gql')),
}

# Extensions shared by unrelated ecosystems. Reported as ambiguity rather than
# resolved by preference: a wrong guess here becomes a wrong requirement later.
AMBIGUOUS = {
    'm': ('matlab', 'objectivec'),
    'pl': ('perl', 'prolog'),
    'v': ('verilog', 'coq'),
    'sc': ('scala', 'supercollider'),
    'fs': ('fsharp', 'glsl'),
    'ml': ('ocaml', 'standardml'),
    'r': ('r', 'rebol'),
    'cls': ('apex', 'tex', 'vbnet'),
    'h': ('c', 'cpp', 'objectivec'),
    'inc': ('php', 'pascal'),
    'pro': ('prolog', 'idl'),
}

# Sibling evidence that resolves an ambiguity, by extension or exact filename.
# Names only: this is the census being decisive from more than one file, not
# from reading any of them.
DISAMBIGUATED_BY = {
    'h': {'c': 'c', 'cpp': 'cpp', 'cc': 'cpp', 'cxx': 'cpp', 'hpp': 'cpp',
          'mm': 'objectivec', 'podfile': 'objectivec'},
    'm': {'mm': 'objectivec', 'swift': 'objectivec', 'podfile': 'objectivec',
          'mlx': 'matlab'},
    'pl': {'p6': 'perl', 'pm': 'perl', 't': 'perl'},
    'v': {'vsh': 'verilog', 'sv': 'verilog', 'vhd': 'verilog'},
    'sc': {'scala': 'scala', 'sbt': 'scala'},
    'fs': {'fsx': 'fsharp', 'fsi': 'fsharp'},
    'ml': {'mli': 'ocaml', 'mly': 'ocaml'},
    'cls': {'trigger': 'apex', 'tex': 'tex'},
}

# Names that identify a language where the extension cannot.
FILENAMES = {
    'makefile': 'make', 'gnumakefile': 'make', 'cmakelists.txt': 'cmake',
    'dockerfile': 'dockerfile', 'containerfile': 'dockerfile',
    'gemfile': 'ruby', 'rakefile': 'ruby', 'vagrantfile': 'ruby', 'berksfile': 'ruby',
    'justfile': 'just', 'procfile': 'shell', 'bashrc': 'shell', 'zshrc': 'shell',
    'pkgbuild': 'shell', 'meson.build': 'meson', 'sconstruct': 'python',
    'wscript': 'python', 'podfile': 'objectivec', 'build.gradle': 'gradle',
}

# Generated output that happens to carry a source extension. Excluded from the
# language census, because protobuf stubs and minified bundles would otherwise
# make a project look like a codebase it is not. Counted and reported instead.
GENERATED_SUFFIXES = (
    '.min.js', '.min.css', '.pb.go', '.pb.cc', '.pb.h', '.pb.swift', '.pb.java',
    '.grpc.go', '.g.dart', '.freezed.dart', '.g.cs', '.designer.cs',
    '.generated.cs', '.generated.go', '_generated.go', '_pb2.py', '_pb2_grpc.py',
    '.g.dart.js',
)

# Recognised manifests, reported but not yet parsed. This is the handoff to
# per-ecosystem requirement resolution: the inventory's job is to say which of
# them exist, so tier 1 never has to re-walk the tree.
MANIFESTS = (
    'package.json', 'package-lock.json', 'pnpm-lock.yaml', 'yarn.lock', 'bun.lockb',
    'tsconfig.json', '.nvmrc', '.node-version', 'angular.json', 'vite.config.ts',
    'vite.config.js', 'next.config.js', 'next.config.mjs', 'composer.json',
    'composer.lock', 'go.mod', 'go.sum', 'Cargo.toml', 'Cargo.lock',
    'rust-toolchain.toml', 'rust-toolchain', 'pyproject.toml',
    'setup.py', 'requirements.txt', 'Pipfile', 'poetry.lock', '.python-version',
    'Gemfile', 'Gemfile.lock', 'pom.xml', 'build.gradle', 'build.gradle.kts',
    'settings.gradle', 'settings.gradle.kts', 'gradlew', 'global.json',
    'Directory.Build.props', 'Directory.Packages.props', 'packages.lock.json',
    'pubspec.yaml', 'pubspec.lock', '.fvmrc', 'mix.exs', 'CMakeLists.txt',
    'meson.build', 'Makefile', '.terraform.lock.hcl', 'Chart.yaml',
)
# Project files whose name varies per project, so they are matched by suffix.
MANIFEST_SUFFIXES = ('.csproj', '.fsproj', '.vbproj', '.sln', '.slnx', '.esproj')
MANIFEST_NAMES = frozenset(name.lower() for name in MANIFESTS)


def is_manifest(name):
    """Whether a filename is a recognised project declaration."""
    lower = name.lower()
    return lower in MANIFEST_NAMES or lower.endswith(MANIFEST_SUFFIXES)


def _markers_of(path):
    return {path.name.lower(), path.suffix[1:].lower()} - {''}


def resolve_ambiguity(suffix, markers):
    """`(language, candidates)` for a shared extension, from the indicators present.

    Indicators that agree settle it. Indicators that disagree — a `.c` and a
    `.cpp` in the same tree — leave it ambiguous, because picking one arbitrarily
    is exactly the silent substitution this whole model exists to avoid.
    """
    implied = {language for marker, language in DISAMBIGUATED_BY.get(suffix, {}).items()
               if marker in markers}
    if len(implied) == 1:
        return implied.pop(), ()
    if implied:
        return None, tuple(sorted(implied))
    return None, tuple(AMBIGUOUS[suffix])


def directory_markers(paths):
    """Markers per directory, plus the whole-project set used as a fallback."""
    by_directory = {}
    for path in paths:
        by_directory.setdefault(path.parent.as_posix(), set()).update(_markers_of(path))
    project = set().union(*by_directory.values()) if by_directory else set()
    return by_directory, project


def classify_all(paths):
    """`(path, kind, value)` for every path, with ambiguity resolved where it occurs.

    A file is judged by the indicators in its own directory first, so a header
    beside an Objective-C implementation is Objective-C even when a C source
    exists elsewhere. The project-wide set is a fallback, because a project's
    languages are usually consistent across `include/` and `src/`.
    """
    by_directory, project = directory_markers(paths)
    return [(path, *classify(path, by_directory.get(path.parent.as_posix(), set()), project))
            for path in paths]


def classify(path, markers=(), fallback=()):
    """What one path evidences, as `(kind, value)`.

    `markers` are the extensions and filenames present beside it; `fallback` is
    the whole-project set, consulted only when the local ones settle nothing.
    """
    name = path.name.lower()
    if name.endswith(GENERATED_SUFFIXES):
        return 'generated', None
    if name in FILENAMES:
        return 'language', FILENAMES[name]
    if name.startswith('dockerfile.'):
        return 'language', 'dockerfile'
    if is_manifest(name):
        # Evidence about a toolchain, not source. Counting package.json as
        # "JSON" would rank configuration above the code it describes.
        return 'manifest', None
    suffix = path.suffix[1:].lower()
    if suffix in AMBIGUOUS:
        language, candidates = resolve_ambiguity(suffix, markers)
        if language is None and fallback:
            language, candidates = resolve_ambiguity(suffix, fallback)
        if language is None:
            return 'ambiguous', candidates or tuple(AMBIGUOUS[suffix])
        return 'language', language
    for language, (_, extensions) in LANGUAGES.items():
        if suffix in extensions:
            return 'language', language
    return 'unknown', None


def markers_seen(paths):
    """Extensions and filenames present in a scan, used to resolve ambiguity."""
    seen = set()
    for path in paths:
        seen.add(path.name.lower())
        suffix = path.suffix[1:].lower()
        if suffix:
            seen.add(suffix)
    return seen


def scan(root, budgets=None, include_paths=False):
    """A bounded census of a project, as names only.

    Returns the file count, the per-language evidence and the manifests present,
    with `truncated` set whenever a budget stopped the walk, and with whatever
    could not be established reported rather than omitted. A partial scan is
    reported as partial: "we did not finish" and "there is nothing else" are
    different answers, and only one of them can be acted on safely.

    `include_paths` adds the raw path list, which the requirement resolver needs
    to scope each component's files. It is off by default because the census is
    meant to stay cheap enough to run on demand.
    """
    root = Path(root)
    budgets = budgets or {}
    max_paths = budgets.get('max_paths', MAX_PATHS)
    deadline = time.monotonic() + budgets.get('max_seconds', MAX_SECONDS)
    state = dict(paths=[], truncated=False, skipped={}, directories=0, capped_directories=0)
    if not root.is_dir():
        return _result(state, include_paths)
    from project_access import open_project
    with open_project(root, Path('.')) as descriptor:
        _walk(descriptor, Path('.'), state, max_paths, deadline, 0)
    return _result(state, include_paths)


def _walk(directory, prefix, state, max_paths, deadline, depth):
    # `truncated` is a report about the answer, not an instruction to stop. A
    # directory that hit its own cap must not abandon the sibling directories
    # that would have been scanned otherwise.
    if depth > MAX_DEPTH:
        state['truncated'] = True
        return
    if len(state['paths']) >= max_paths or time.monotonic() > deadline:
        state['truncated'] = True
        return
    try:
        # Bounded during enumeration, not after: sorting an entire directory
        # first would materialize a million entries before the cap applied.
        entries = []
        with os.scandir(directory) as children:
            for entry in children:
                if len(entries) >= MAX_PER_DIRECTORY:
                    state['capped_directories'] += 1
                    state['truncated'] = True
                    break
                entries.append(entry)
        entries.sort(key=lambda entry: entry.name)
    except OSError:
        state['skipped']['unreadable'] = state['skipped'].get('unreadable', 0) + 1
        return
    state['directories'] += 1
    for entry in entries:
        if len(state['paths']) >= max_paths or time.monotonic() > deadline:
            state['truncated'] = True
            return
        relative = prefix / entry.name
        # A symlink is counted, never followed and never attributed to a source
        # language: it may point anywhere, including outside the projects root.
        if entry.is_symlink():
            state['skipped']['symlink'] = state['skipped'].get('symlink', 0) + 1
            continue
        try:
            is_directory = entry.is_dir(follow_symlinks=False)
        except OSError:
            state['skipped']['unreadable'] = state['skipped'].get('unreadable', 0) + 1
            continue
        if is_directory:
            if entry.name in IGNORED:
                state['skipped'][entry.name] = state['skipped'].get(entry.name, 0) + 1
                continue
            from project_access import open_directory
            try:
                with open_directory(directory, entry.name) as child:
                    _walk(child, relative, state, max_paths, deadline, depth + 1)
            except (OSError, ValueError):
                state['skipped']['unreadable'] = state['skipped'].get('unreadable', 0) + 1
        else:
            state['paths'].append(relative)


def from_paths(paths):
    """The same census, from a known file list such as a committed tree.

    A committed tree is enumerated by Git rather than walked, so there is no
    directory capping, nothing skipped and nothing unreadable: the list is the
    whole answer, up to the path budget.
    """
    listed = list(paths)
    state = dict(paths=[Path(*PurePosixPath(item).parts) for item in listed[:MAX_PATHS]],
                 truncated=len(listed) > MAX_PATHS, skipped={}, directories=0,
                 capped_directories=0)
    return _result(state, True)


def _result(state, include_paths=False):
    ambiguous = {}
    generated = unknown = 0
    unknown_evidence = []
    by_language = {}
    for path, kind, value in classify_all(state['paths']):
        if kind == 'language':
            entry = by_language.setdefault(value, dict(id=value, files=0, evidence=[]))
            entry['files'] += 1
            if len(entry['evidence']) < EVIDENCE_LIMIT:
                entry['evidence'].append(path.as_posix())
        elif kind == 'ambiguous':
            entry = ambiguous.setdefault(value, dict(candidates=list(value), files=0, evidence=[]))
            entry['files'] += 1
            if len(entry['evidence']) < EVIDENCE_LIMIT:
                entry['evidence'].append(path.as_posix())
        elif kind == 'generated':
            generated += 1
        elif kind == 'unknown':
            unknown += 1
            if len(unknown_evidence) < UNKNOWN_EVIDENCE_LIMIT:
                unknown_evidence.append(path.as_posix())
    labels = {name: label for name, (label, _) in LANGUAGES.items()}
    for entry in by_language.values():
        entry['label'] = labels.get(entry['id'], entry['id'])
    languages = sorted(by_language.values(), key=lambda item: (-item['files'], item['id']))
    # Component paths are kept, not just names: a workspace keeps one manifest
    # per package, and the next tier has to read each of them where it lives.
    manifests = sorted(path.as_posix() for path in state['paths'] if is_manifest(path.name))
    result = dict(files=len(state['paths']), directories=state['directories'],
                  capped_directories=state['capped_directories'],
                  truncated=state['truncated'], skipped=state['skipped'],
                  languages=languages,
                  ambiguous=sorted(ambiguous.values(), key=lambda item: (-item['files'], item['candidates'])),
                  generated=generated, unknown=unknown, unknown_evidence=unknown_evidence,
                  manifests=manifests)
    if include_paths:
        result['paths'] = [path.as_posix() for path in state['paths']]
    return result
