"""Mach-O dependency inspection shared by packaging and validation (arm64)."""
from pathlib import Path
import re
import subprocess

SYSTEM_PREFIXES = ('/System/Library/', '/usr/lib/')
MAGICS = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
          b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'}

def is_macho(path):
    if not path.is_file(): return False
    with path.open('rb') as f: return f.read(4) in MAGICS

def inspect(path):
    text = subprocess.check_output(['otool', '-arch', 'arm64', '-l', str(path)], text=True)
    deps, rpaths, identity = [], [], None
    for block in re.split(r'Load command \d+\n', text)[1:]:
        command = re.search(r'\bcmd (\S+)', block)
        if not command: continue
        command = command[1]
        if command == 'LC_RPATH':
            rpaths.append(re.search(r'\bpath (.*?) \(offset', block)[1])
        elif command in ('LC_LOAD_DYLIB', 'LC_LOAD_WEAK_DYLIB', 'LC_REEXPORT_DYLIB', 'LC_LOAD_UPWARD_DYLIB', 'LC_ID_DYLIB'):
            name = re.search(r'\bname (.*?) \(offset', block)[1]
            if command == 'LC_ID_DYLIB': identity = name
            else: deps.append(name)
    return deps, rpaths, identity

def graph(app):
    """Resolve every embedded executable, then traverse its recorded dependencies."""
    import plistlib
    app = app.resolve()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    roots = {p.resolve() for p in app.rglob('*') if is_macho(p)}
    # The app executable's rpaths are inherited by its dylibs. All our helpers
    # live in Contents/MacOS and use their own loader-relative dependencies.
    _, main_paths, _ = inspect(executable)
    def expand(raw, loader):
        return raw.replace('@executable_path', str(executable.parent)).replace('@loader_path', str(loader.parent))
    initial = [expand(p, executable) for p in main_paths]
    pending = [(p, initial) for p in roots]
    nodes = {}
    while pending:
        binary, inherited = pending.pop()
        binary = binary.resolve()
        if binary in nodes: continue
        deps, own, identity = inspect(binary)
        search = [expand(p, binary) for p in own] + inherited
        resolved = {}
        for dep in deps:
            if dep.startswith(SYSTEM_PREFIXES): continue
            candidates = [Path(p) / dep[7:] for p in search] if dep.startswith('@rpath/') else [Path(expand(dep, binary))]
            target = next((p.resolve() for p in candidates if p.is_file()), None)
            if target is None: raise RuntimeError(f'{binary.name}: unresolved {dep}')
            resolved[dep] = target
            pending.append((target, search))
        nodes[binary] = {'dependencies': resolved, 'rpaths': own, 'identity': identity}
    return nodes
