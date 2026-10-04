#!/usr/bin/env python3
"""
licence-inventory — #805/#827: one machine-readable licence inventory of
everything this repository builds from, and a CI gate that keeps it whole.
Repo-agnostic: the same file runs in cloud-u-android, cloud-infra and
cloud-u-containers; everything repo-specific lives in licenses/curated.json
and licenses/upstreams.json.

  refresh ROOT [--offline]   rebuild ROOT/licenses/inventory.json
  check   ROOT               exit 1 naming every subject with no inventory entry

SUBJECTS (what must have an entry; discovered from `git ls-files`, with
licenses/curated.json::scan_skip_prefixes excluded):

  dir:<top>        every top-level directory            -> curated.directories
  vendored:<dir>   every directory holding a LICENSE / COPYING / NOTICE file
                   (also prefixed: OPEN-SANS-LICENSE.txt)
                   that is not inside a module of licenses/upstreams.json
                   (nor inside a node_modules/ or another vendored dir's
                   upstream module)                    -> curated.directories
  asset:<path>     every tracked binary of a licence-bearing kind
                   (curated.asset_extensions: native libs, jars, fonts...)
  maven:<g>:<a>    build.gradle(.kts) / gradle/libs.versions.toml coordinates
  npm:<name>       package.json dependencies (in-tree package names are own
                   code and not subjects)
  cargo:<crate>    Cargo.toml [*dependencies] incl. [workspace.dependencies] and
                   target-specific tables; path deps, `workspace = true` and
                   in-tree crate names are own code and not subjects
  go:<module>      go.mod require lines
  pypi:<name>      requirements*.txt lines and pyproject.toml
                   [project].dependencies / optional-dependencies /
                   [tool.poetry.*dependencies] (normalised PEP 503 names;
                   in-tree project names are own code)
  flake:<input>    flake.nix inputs (github:owner/repo, git+https://host/x, ...;
                   ref/rev stripped; path: inputs are own code)
  docker:<image>   container base / runtime images: Dockerfile* FROM (stage
                   aliases and scratch skipped, ARG defaults substituted),
                   docker-compose*.yml `image:`, nix `imageName = "..."`, and
                   build.json upstream_image / base_image / builder_image /
                   from_image / containers.<name>.image. Tag and digest
                   stripped; docker.io/library/ normalised away.
  tf:<provider>    Terraform providers (.terraform.lock.hcl `provider "..."`)

Keys carry no version, so a version bump never fails the gate; a NEW
dependency, image, input, vendored directory, binary or top-level directory does.

ROOTFS SUMMARY (not gated): OS / tool packages installed INTO images by
Dockerfile RUN lines (apk add, apt(-get) install, dnf/yum/microdnf install,
pip install, npm install -g, cargo install, go install). Recorded under
"rootfs_packages" as package -> [Dockerfiles]. Their licences are the
distribution's per-package metadata and are NOT resolved here.

LICENCE RESOLUTION (refresh only; check never touches the network):
  curated first for every kind (curated.<kind>_licences, longest key prefix:
  maven_group_licences, npm_licences, cargo_licences, go_licences,
  pypi_licences, flake_licences, docker_licences, tf_licences), else:
  maven  POM <licenses> (then parent POM) from curated.maven_repos
  npm    registry.npmjs.org/<name>/latest `license`
  cargo  crates.io /api/v1/crates/<name> newest version `license`
  pypi   pypi.org/pypi/<name>/json license_expression | license | classifiers
  go, flake, docker, tf  no machine-readable registry licence -> curated only
  asset  curated.assets, else the licence of the deepest curated directory or
         upstream module containing it.
Anything unresolved is recorded as NOASSERTION with the reason - never guessed.

TRANSITIVE DEPENDENCIES are NOT resolved (that needs a Gradle / npm / cargo /
pip / nix resolution the shared runners do not run for an audit). Each package
entry says so ("transitive": "not resolved"). Not legal advice.

EXIT  0 ok - 1 missing entries - 2 usage
"""
import concurrent.futures as cf, json, os, re, subprocess, sys, tomllib, urllib.request
import xml.etree.ElementTree as ET

CONFIG_RE = re.compile(r"^\s*(implementation|api|compileOnly|runtimeOnly|kapt|ksp|annotationProcessor|"
                       r"coreLibraryDesugaring|classpath|lintChecks|detektPlugins|"
                       r"(?:test|androidTest|debug|release|testFixtures|[a-z]+)(?:Implementation|Api|CompileOnly|RuntimeOnly))\b")
COORD_RE = re.compile(r"[\"']([A-Za-z0-9_.\-]+\.[A-Za-z0-9_.\-]+):([A-Za-z0-9_.\-]+)(?::([^\"'\s@]+))?(?:@\w+)?[\"']")
LIC_NAMES = re.compile(r"(^|/)(?-i:[A-Z0-9]+[-_])*(LICEN[CS]E|COPYING|NOTICE)(\.(md|txt|rst|html)|-(MIT|APACHE|COMMERCIAL|GPL|BSD|LGPL|MPL)[^/]*)?$", re.I)
PKG_KINDS = ("maven", "npm", "cargo", "go", "pypi", "flake", "docker", "tf")
SPDX = {  # licence names as POMs / registries write them -> SPDX
    "the apache software license, version 2.0": "Apache-2.0", "apache license, version 2.0": "Apache-2.0",
    "apache 2.0": "Apache-2.0", "apache-2.0": "Apache-2.0", "the apache license, version 2.0": "Apache-2.0",
    "apache license 2.0": "Apache-2.0", "apache 2": "Apache-2.0", "apache license version 2.0": "Apache-2.0",
    "apache software license": "Apache-2.0", "apache": "Apache-2.0", "apache2": "Apache-2.0",
    "mit license": "MIT", "the mit license": "MIT", "mit": "MIT", "the mit license (mit)": "MIT",
    "bsd-3-clause": "BSD-3-Clause", "new bsd license": "BSD-3-Clause", "the bsd license": "BSD-3-Clause",
    "bsd 3-clause license": "BSD-3-Clause", "bsd-2-clause": "BSD-2-Clause", "bsd license": "BSD-3-Clause",
    "bsd": "BSD-3-Clause", "3-clause bsd license": "BSD-3-Clause",
    "eclipse public license - v 1.0": "EPL-1.0", "eclipse public license 1.0": "EPL-1.0",
    "eclipse public license - v 2.0": "EPL-2.0", "eclipse public license v2.0": "EPL-2.0",
    "gnu lesser general public license": "LGPL-2.1-or-later", "mozilla public license 2.0": "MPL-2.0",
    "mpl 2.0": "MPL-2.0", "mpl-2.0": "MPL-2.0", "isc": "ISC", "isc license": "ISC", "0bsd": "0BSD",
    "unlicense": "Unlicense", "cc0-1.0": "CC0-1.0",
    "android software development kit license": "LicenseRef-Android-SDK",
    "simplified bsd license": "BSD-2-Clause", 'bsd 2-clause "simplified" license': "BSD-2-Clause",
    "the 3-clause bsd license": "BSD-3-Clause", "the bsd 3-clause license": "BSD-3-Clause",
    "revised bsd": "BSD-3-Clause", "public domain": "LicenseRef-PublicDomain",
    "apache 2.0 license": "Apache-2.0", "psfl": "PSF-2.0", "psf": "PSF-2.0", "psf license": "PSF-2.0", "python software foundation license": "PSF-2.0",
    "play core software development kit terms of service": "LicenseRef-Google-Play-Core-SDK-Terms",
}
CLASSIFIER = {  # PyPI trove classifier tail -> SPDX
    "MIT License": "MIT", "Apache Software License": "Apache-2.0", "BSD License": "BSD-3-Clause",
    "ISC License (ISCL)": "ISC", "Mozilla Public License 2.0 (MPL 2.0)": "MPL-2.0",
    "Python Software Foundation License": "PSF-2.0",
    "GNU General Public License v3 (GPLv3)": "GPL-3.0-only",
    "GNU Lesser General Public License v3 (LGPLv3)": "LGPL-3.0-only",
    "GNU Affero General Public License v3": "AGPL-3.0-only", "The Unlicense (Unlicense)": "Unlicense",
}
UA = {"User-Agent": "licence-inventory/1.0 (+#827)"}


def git_files(root):
    out = subprocess.run(["git", "ls-files", "-z"], cwd=root, check=True, capture_output=True).stdout
    return [f for f in out.decode().split("\0") if f]


def load(root, p):
    with open(os.path.join(root, p)) as h:
        return json.load(h)


def read(root, f):
    try:
        with open(os.path.join(root, f), errors="replace") as h:
            return h.read()
    except OSError:  # a dangling symlink is tracked but unreadable
        return ""


def deepest(prefixes, path):
    best = None
    for p in prefixes:
        if (path == p or path.startswith(p.rstrip("/") + "/")) and (best is None or len(p) > len(best)):
            best = p
    return best


def pep503(n):
    return re.sub(r"[-_.]+", "-", n).lower()


def norm_image(ref):
    """'docker.io/library/node:24-alpine@sha256:..' -> 'node'. None when unusable."""
    r = ref.strip().strip("'\"")
    if not r or "$" in r or r.lower() == "scratch" or " " in r:
        return None
    r = r.split("@", 1)[0]
    last = r.rsplit("/", 1)
    if ":" in last[-1]:
        last[-1] = last[-1].split(":", 1)[0]
    r = "/".join(last).lower()
    for p in ("docker.io/", "index.docker.io/", "registry-1.docker.io/"):
        if r.startswith(p):
            r = r[len(p):]
    if r.startswith("library/"):
        r = r[len("library/"):]
    if not re.match(r"^[a-z0-9][a-z0-9._/:\-]*$", r):
        return None
    return r


def norm_flake(url):
    u = url.strip()
    if u.startswith(("path:", "/", ".", "self")):
        return None
    u = u.split("?", 1)[0]
    m = re.match(r"^(github|gitlab|sourcehut):([^/]+)/([^/]+)", u)
    if m:
        return f"{m.group(1)}:{m.group(2).lower()}/{m.group(3).lower()}"
    u = re.sub(r"^(git\+|tarball\+|file\+)", "", u)
    u = re.sub(r"\.git$", "", u.rstrip("/"))
    u = re.sub(r"^https?://", "", u)
    m = re.match(r"^(github\.com|gitlab\.com)/([^/]+)/([^/]+)", u)
    if m:
        return f"{m.group(1).split('.')[0]}:{m.group(2).lower()}/{m.group(3).lower()}"
    return u.lower() or None


# ── discovery ────────────────────────────────────────────────────────────────

def discover(root):
    cur = load(root, "licenses/curated.json")
    ups = load(root, "licenses/upstreams.json")["modules"]
    skip = tuple(cur.get("scan_skip_prefixes", []))
    files = [f for f in git_files(root) if not f.startswith(skip)]
    up_paths = [m["path"] for m in ups]
    subj, rootfs = {}, {}

    def add(key, **kw):
        e = subj.setdefault(key, {"declared_in": []})
        for k, v in kw.items():
            if k == "declared_in":
                if v not in e["declared_in"]:
                    e["declared_in"].append(v)
            elif v and not e.get(k):
                e[k] = v

    for f in files:
        if "/" in f:
            add("dir:" + f.split("/", 1)[0], declared_in="(tree)")
        if LIC_NAMES.search(f) and "/" in f:
            d = os.path.dirname(f)
            if not deepest(up_paths, d) and "/node_modules/" not in f:
                add("vendored:" + d, declared_in=f)
        if os.path.splitext(f)[1].lower() in cur.get("asset_extensions", []):
            add("asset:" + f, declared_in=f)

    # names defined in-tree are own code, never third-party subjects
    internal = {"npm": set(), "cargo": set(), "pypi": set()}
    parsed = {}
    for f in files:
        base = os.path.basename(f)
        if base == "package.json" and "/node_modules/" not in f:
            try:
                d = json.loads(read(root, f))
            except ValueError:
                continue
            parsed[f] = d
            if isinstance(d, dict) and d.get("name"):
                internal["npm"].add(d["name"])
        elif base in ("Cargo.toml", "pyproject.toml"):
            try:
                d = tomllib.loads(read(root, f))
            except Exception:
                continue
            parsed[f] = d
            if base == "Cargo.toml" and (d.get("package") or {}).get("name"):
                internal["cargo"].add(d["package"]["name"])
            if base == "pyproject.toml":
                n = (d.get("project") or {}).get("name") or ((d.get("tool") or {}).get("poetry") or {}).get("name")
                if n:
                    internal["pypi"].add(pep503(n))

    for f in files:
        base = os.path.basename(f)
        if base in ("build.gradle", "build.gradle.kts"):
            for line in read(root, f).splitlines():
                m = CONFIG_RE.match(line)
                if not m:
                    continue
                cfg = m.group(1)
                scope = "test" if cfg.lower().startswith(("test", "androidtest")) else (
                    "build" if cfg in ("classpath", "lintChecks", "detektPlugins") else "shipped")
                for g, a, v in COORD_RE.findall(line):
                    add(f"maven:{g}:{a}", declared_in=f, version=v or "", scope=scope)
        elif base == "libs.versions.toml":
            try:
                t = tomllib.loads(read(root, f))
            except Exception:
                continue
            vers = t.get("versions", {})
            for _, spec in (t.get("libraries") or {}).items():
                if isinstance(spec, str):
                    parts = spec.split(":")
                    g, a, v = parts[0], parts[1], (parts[2] if len(parts) > 2 else "")
                else:
                    if "module" in spec:
                        g, a = spec["module"].split(":")[:2]
                    else:
                        g, a = spec.get("group", ""), spec.get("name", "")
                    v = spec.get("version", "")
                    if isinstance(v, dict):
                        v = vers.get(v.get("ref", ""), "") if "ref" in v else v.get("strictly", v.get("require", ""))
                    if isinstance(v, dict):
                        v = v.get("strictly", v.get("require", ""))
                if g and a:
                    add(f"maven:{g}:{a}", declared_in=f, version=str(v or ""), scope="catalog")
        elif base == "package.json" and isinstance(parsed.get(f), dict):
            d = parsed[f]
            for k in ("dependencies", "devDependencies", "peerDependencies", "optionalDependencies"):
                for n, spec in (d.get(k) or {}).items():
                    if n in internal["npm"] or str(spec).startswith(("workspace:", "file:", "link:", "portal:")):
                        continue
                    add("npm:" + n, declared_in=f, version=str(spec),
                        scope="dev" if k == "devDependencies" else "shipped")
        elif base == "Cargo.toml" and f in parsed:
            cargo(parsed[f], f, internal["cargo"], add)
        elif base == "go.mod":
            body = read(root, f)
            for blk in re.findall(r"^require\s*\((.*?)^\)", body, re.M | re.S) + \
                    re.findall(r"^require\s+(\S+\s+\S+)", body, re.M):
                for line in blk.splitlines():
                    p = line.split("//", 1)[0].split()
                    if len(p) >= 2:
                        add("go:" + p[0], declared_in=f, version=p[1],
                            scope="indirect" if "// indirect" in line else "shipped")
        elif re.match(r"^requirements[\w.\-]*\.txt$", base):
            for line in read(root, f).splitlines():
                n = py_req(line)
                if n and n not in internal["pypi"]:
                    add("pypi:" + n, declared_in=f, version=line.strip(), scope="shipped")
        elif base == "pyproject.toml" and f in parsed:
            d = parsed[f]
            reqs = list((d.get("project") or {}).get("dependencies") or [])
            for v in ((d.get("project") or {}).get("optional-dependencies") or {}).values():
                reqs += v
            for g in ((d.get("dependency-groups") or {}).values()):
                reqs += [x for x in g if isinstance(x, str)]
            poetry = (d.get("tool") or {}).get("poetry") or {}
            names = [n for n in (poetry.get("dependencies") or {}) if n.lower() != "python"]
            for grp in (poetry.get("group") or {}).values():
                names += list((grp.get("dependencies") or {}))
            for r in reqs:
                n = py_req(r)
                if n and n not in internal["pypi"]:
                    add("pypi:" + n, declared_in=f, version=r, scope="shipped")
            for n in names:
                if pep503(n) not in internal["pypi"]:
                    add("pypi:" + pep503(n), declared_in=f, scope="shipped")
        elif base == "flake.nix":
            body = read(root, f)
            m = re.search(r"\binputs\s*=\s*\{(.*?)\n\s*\};?\s*\n\s*outputs", body, re.S)
            region = m.group(1) if m else body.split("outputs", 1)[0]
            urls = re.findall(r"\burl\s*=\s*\"([^\"]+)\"", region)
            for u in urls:
                k = norm_flake(u)
                if k:
                    add("flake:" + k, declared_in=f, version=u)
        elif base.endswith(".terraform.lock.hcl") or base == ".terraform.lock.hcl":
            for p, v in re.findall(r'provider\s+"([^"]+)"\s*\{\s*version\s*=\s*"([^"]*)"', read(root, f)):
                add("tf:" + p.lower(), declared_in=f, version=v)

        # container images
        if re.match(r"^(Dockerfile|Containerfile)([.\-][\w.\-]*)?$", base) or base.endswith(".Dockerfile"):
            dockerfile(read(root, f), f, add, rootfs)
        elif re.match(r"^(docker-)?compose[\w.\-]*\.ya?ml$", base):
            for img in re.findall(r"^\s*image:\s*['\"]?([^'\"\s#]+)", read(root, f), re.M):
                k = norm_image(re.sub(r"\$\{[^:}]+:-([^}]+)\}", r"\1", img))
                if k:
                    add("docker:" + k, declared_in=f, version=img, scope="runtime")
        if f.endswith(".nix"):
            for img in re.findall(r"\bimageName\s*=\s*\"([^\"]+)\"", read(root, f)):
                k = norm_image(img)
                if k:
                    add("docker:" + k, declared_in=f, version=img, scope="base")
        if base == "build.json":
            try:
                bj = json.loads(read(root, f))
            except ValueError:
                bj = None
            if isinstance(bj, dict):
                for img, scope in build_json_images(bj):
                    k = norm_image(img)
                    if k:
                        add("docker:" + k, declared_in=f, version=img, scope=scope)
    return cur, ups, subj, rootfs


def cargo(d, f, internal, add):
    tables = []
    for k in ("dependencies", "dev-dependencies", "build-dependencies"):
        tables.append((k, d.get(k) or {}))
    tables.append(("workspace.dependencies", (d.get("workspace") or {}).get("dependencies") or {}))
    for t in (d.get("target") or {}).values():
        for k in ("dependencies", "dev-dependencies", "build-dependencies"):
            tables.append((k, (t or {}).get(k) or {}))
    for k, tab in tables:
        for n, spec in tab.items():
            if isinstance(spec, dict):
                if spec.get("path") or spec.get("workspace"):
                    continue
                name = spec.get("package", n)
                ver = spec.get("version") or spec.get("git", "")
            else:
                name, ver = n, str(spec)
            if name in internal:
                continue
            add("cargo:" + name, declared_in=f, version=str(ver),
                scope="dev" if k.startswith("dev") else ("build" if k.startswith("build") else "shipped"),
                **({"source": spec["git"]} if isinstance(spec, dict) and spec.get("git") else {}))


def py_req(line):
    s = line.split("#", 1)[0].strip()
    if not s or s.startswith(("-", "git+", "http:", "https:", "file:", ".", "/")):
        return None
    m = re.match(r"^([A-Za-z0-9][A-Za-z0-9._\-]*)", s)
    return pep503(m.group(1)) if m else None


def dockerfile(body, f, add, rootfs):
    args, stages = {}, set()
    body = re.sub(r"\\\r?\n", " ", body)
    for line in body.splitlines():
        s = line.strip()
        m = re.match(r"^ARG\s+(\w+)=(\S+)", s, re.I)
        if m:
            args.setdefault(m.group(1), m.group(2).strip("'\""))
            continue
        m = re.match(r"^FROM\s+(?:--\S+\s+)*(\S+)(?:\s+AS\s+(\S+))?", s, re.I)
        if m:
            ref = re.sub(r"\$\{?(\w+)(?::-([^}]*))?\}?",
                         lambda x: args.get(x.group(1), x.group(2) or x.group(0)), m.group(1))
            if ref.lower() not in stages:
                k = norm_image(ref)
                if k:
                    add("docker:" + k, declared_in=f, version=ref, scope="base")
            if m.group(2):
                stages.add(m.group(2).lower())
            continue
        if re.match(r"^RUN\b", s, re.I):
            for seg in re.split(r"&&|;|\|\|", s[3:]):
                pkgs(seg.strip(), f, rootfs)


PM = [
    ("apk", r"^apk\s+(?:--\S+\s+)*add\b(.*)"),
    ("apt", r"^(?:DEBIAN_FRONTEND=\S+\s+)?apt(?:-get)?\s+(?:-\S+\s+)*install\b(.*)"),
    ("dnf", r"^(?:dnf|yum|microdnf)\s+(?:-\S+\s+)*install\b(.*)"),
    ("pip", r"^(?:python3?\s+-m\s+)?(?:pip3?|uv\s+pip)\s+install\b(.*)"),
    ("npm-global", r"^npm\s+(?:i|install)\s+(?:.*\s)?(?:-g|--global)\b(.*)"),
    ("cargo", r"^cargo\s+install\b(.*)"),
    ("go", r"^go\s+install\b(.*)"),
]


def pkgs(cmd, f, rootfs):
    cmd = re.sub(r"^(?:sudo\s+|set\s+-\S+\s*;?\s*)+", "", cmd)
    for pm, rx in PM:
        m = re.match(rx, cmd)
        if not m:
            continue
        for tok in m.group(1).split():
            if tok.startswith(("-", "$", "/", ".", "<", ">", "&", "|", "'", '"')) or "=" == tok[:1] or tok in ("\\",):
                continue
            if tok.endswith((".txt", ".whl", ".tar.gz", ".toml")) or (pm == "pip" and tok.startswith(("git+", "http"))):
                continue
            name = re.split(r"[=<>@~!]", tok, 1)[0] if pm in ("apk", "apt", "dnf", "pip") else tok.split("@")[0]
            if pm in ("cargo", "go"):
                name = tok.split("@")[0]
            if not re.match(r"^[A-Za-z0-9][A-Za-z0-9._+:/\-]*$", name or ""):
                continue
            rootfs.setdefault(pm, {}).setdefault(name, [])
            if f not in rootfs[pm][name]:
                rootfs[pm][name].append(f)
        return


def build_json_images(bj):
    out = []

    def walk(o, path):
        if isinstance(o, dict):
            for k, v in o.items():
                if k.startswith("_"):
                    continue
                p = path + (k,)
                if isinstance(v, str):
                    if k in ("upstream_image", "from_image"):
                        out.append((v, "base"))
                    elif k in ("base_image", "builder_image"):
                        out.append((v, "base" if k == "base_image" else "build"))
                    elif k == "image" and len(p) >= 3 and p[-3] == "containers":
                        out.append((v, "runtime"))
                else:
                    walk(v, p)
        elif isinstance(o, list):
            for v in o:
                walk(v, path)
    walk(bj, ())
    return out


# ── resolution (refresh only) ────────────────────────────────────────────────

def fetch(url, timeout=20):
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout) as r:
            return r.read()
    except Exception:
        return None


def spdx(name):
    n = (name or "").strip()
    return SPDX.get(n.lower(), n) if n else ""


def pom_licences(repos, g, a, v, depth=0):
    for repo in repos:
        b = fetch(f"{repo}/{g.replace('.', '/')}/{a}/{v}/{a}-{v}.pom")
        if not b:
            continue
        try:
            x = ET.fromstring(b)
        except ET.ParseError:
            return []
        ns = {"m": x.tag[1:].split("}")[0]} if x.tag.startswith("{") else {"m": ""}
        q = (lambda p: x.findall(p, ns)) if ns["m"] else (lambda p: x.findall(p.replace("m:", "")))
        names = [e.text for e in q("./m:licenses/m:license/m:name") if e.text]
        if names:
            return [spdx(n) for n in names]
        par = q("./m:parent")
        if par and depth < 2:
            pe = par[0]
            f = (lambda t: pe.find("m:" + t, ns)) if ns["m"] else (lambda t: pe.find(t))
            if None not in (f("groupId"), f("artifactId"), f("version")):
                return pom_licences(repos, f("groupId").text, f("artifactId").text, f("version").text, depth + 1)
        return []
    return None


def latest(repos, g, a):
    for repo in repos:
        b = fetch(f"{repo}/{g.replace('.', '/')}/{a}/maven-metadata.xml")
        if b:
            m = re.search(rb"<release>([^<]+)</release>", b) or re.search(rb"<latest>([^<]+)</latest>", b)
            if m:
                return m.group(1).decode()
    return ""


def curated_rule(cur, kind, name):
    table = "maven_group_licences" if kind == "maven" else f"{kind}_licences"
    rules = cur.get(table, {})
    if kind == "maven":
        g, a = name.split(":", 1)
        hit = max((p for p in rules if g == p or g.startswith(p + ".") or name == p), key=len, default=None)
    else:
        hit = max((p for p in rules if name == p or (p.endswith(("/", "*", "-")) and name.startswith(p.rstrip("*")))),
                  key=len, default=None)
    if hit is None:
        return None
    r = rules[hit]
    return {"licence": r["licence"], "licence_source": f"licenses/curated.json::{table}[{hit}]",
            **({"note": r["note"]} if r.get("note") else {})}


def resolve_maven(cur, name, e):
    g, a = name.split(":", 1)
    v = e.get("version", "")
    if not re.match(r"^[0-9][A-Za-z0-9.\-+]*$", v):
        lv = latest(cur.get("maven_repos", []), g, a)
        if not lv:
            return {"licence": "NOASSERTION", "licence_source": f"version '{v}' not resolvable without Gradle and no maven-metadata.xml found"}
        why = f"POM of latest release {lv} (declared version '{v or 'from BOM'}' needs Gradle to resolve)"
        v = lv
    else:
        why = f"POM {v}"
    lic = pom_licences(cur.get("maven_repos", []), g, a, v)
    if lic is None:
        return {"licence": "NOASSERTION", "licence_source": f"no POM found for {g}:{a}:{v} in curated.maven_repos"}
    if not lic:
        return {"licence": "NOASSERTION", "licence_source": why + " declares no <licenses>"}
    return {"licence": " AND ".join(dict.fromkeys(lic)), "licence_source": why}


def resolve_npm(name):
    b = fetch("https://registry.npmjs.org/" + name.replace("/", "%2F") + "/latest")
    if not b:
        return {"licence": "NOASSERTION", "licence_source": "registry.npmjs.org: not found (private or unpublished)"}
    try:
        d = json.loads(b)
    except ValueError:
        return {"licence": "NOASSERTION", "licence_source": "registry.npmjs.org: unparseable"}
    lic = d.get("license")
    if isinstance(lic, dict):
        lic = lic.get("type")
    return {"licence": lic or "NOASSERTION", "licence_source": f"registry.npmjs.org latest ({d.get('version', '?')})"}


def resolve_cargo(name):
    b = fetch(f"https://crates.io/api/v1/crates/{name}")
    if not b:
        return {"licence": "NOASSERTION", "licence_source": "crates.io: not found (git-only or private crate)"}
    try:
        d = json.loads(b)
    except ValueError:
        return {"licence": "NOASSERTION", "licence_source": "crates.io: unparseable"}
    vs = d.get("versions") or []
    v = next((x for x in vs if x.get("num") == (d.get("crate") or {}).get("max_stable_version")), vs[0] if vs else {})
    lic = (v.get("license") or "").replace("/", " OR ")
    return {"licence": lic or "NOASSERTION", "licence_source": f"crates.io {v.get('num', '?')}"}


def resolve_pypi(name):
    b = fetch(f"https://pypi.org/pypi/{name}/json")
    if not b:
        return {"licence": "NOASSERTION", "licence_source": "pypi.org: not found"}
    try:
        info = json.loads(b)["info"]
    except (ValueError, KeyError):
        return {"licence": "NOASSERTION", "licence_source": "pypi.org: unparseable"}
    src = f"pypi.org {info.get('version', '?')}"
    if info.get("license_expression"):
        return {"licence": info["license_expression"], "licence_source": src + " license_expression"}
    lic = (info.get("license") or "").strip()
    if lic and len(lic) < 60 and "\n" not in lic:
        return {"licence": spdx(lic), "licence_source": src + " license"}
    cls = [CLASSIFIER.get(c.split(" :: ")[-1]) for c in info.get("classifiers") or [] if c.startswith("License ::")]
    cls = [c for c in cls if c]
    if cls:
        return {"licence": " OR ".join(dict.fromkeys(cls)), "licence_source": src + " classifiers"}
    return {"licence": "NOASSERTION", "licence_source": src + ": no licence metadata (or full licence text only)"}


NO_REGISTRY = {
    "go": "proxy.golang.org publishes no licence metadata; add to licenses/curated.json::go_licences",
    "flake": "flake inputs carry no licence metadata; add to licenses/curated.json::flake_licences",
    "docker": "registries publish no reliable licence metadata for images; add to licenses/curated.json::docker_licences",
    "tf": "registry.terraform.io publishes no licence metadata; add to licenses/curated.json::tf_licences",
}


def refresh(root, offline):
    cur, ups, subj, rootfs = discover(root)
    dirs = cur.get("directories", {})
    up_by_path = {m["path"]: m for m in ups}
    old = {}
    p = os.path.join(root, "licenses/inventory.json")
    if os.path.exists(p):
        old = json.load(open(p)).get("entries", {})

    def one(item):
        k, e = item
        kind, name = k.split(":", 1)
        out = {"kind": kind, **e}
        if kind in ("dir", "vendored"):
            d = dirs.get(name)
            out.update({"licence": d["licence"], "licence_source": "licenses/curated.json::directories",
                        **({"note": d["note"]} if d.get("note") else {})} if d else
                       {"licence": "NOASSERTION", "licence_source": "MISSING from licenses/curated.json::directories"})
        elif kind == "asset":
            a = cur.get("assets", {}).get(name)
            if a:
                out.update(a)
                out.setdefault("licence_source", "licenses/curated.json::assets")
            else:
                dp = deepest(list(dirs) + list(up_by_path), name)
                lic = (up_by_path[dp]["licence"] if dp in up_by_path else dirs[dp]["licence"]) if dp else "NOASSERTION"
                out.update({"licence": lic, "licence_source": f"inherits {dp}" if dp else "no containing entry"})
        else:
            r = curated_rule(cur, kind, name)
            if r:
                out.update(r)
            elif offline or kind in NO_REGISTRY:
                prev = old.get(k, {})
                why = NO_REGISTRY.get(kind, "offline refresh: not resolved")
                keep = prev.get("licence") and not prev.get("licence_source", "").startswith("licenses/curated.json")
                out.update({"licence": prev["licence"] if keep else "NOASSERTION",
                            "licence_source": prev["licence_source"] if keep else why})
            elif kind == "maven":
                out.update(resolve_maven(cur, name, e))
            elif kind == "npm":
                out.update(resolve_npm(name))
            elif kind == "cargo":
                out.update(resolve_cargo(name) if not e.get("source") else
                           {"licence": "NOASSERTION", "licence_source": f"git dependency {e['source']}: no registry metadata"})
            elif kind == "pypi":
                out.update(resolve_pypi(name))
            if kind not in ("docker", "flake", "tf"):
                out["transitive"] = "not resolved (needs a package-manager resolution; see script docstring)"
        dp = deepest(list(up_by_path), out["declared_in"][0]) if out.get("declared_in") else None
        if dp:
            out["within_upstream_module"] = up_by_path[dp]["id"]
        return k, out

    with cf.ThreadPoolExecutor(16) as ex:
        entries = dict(sorted(ex.map(one, subj.items())))
    summary = {}
    for k, e in entries.items():
        summary.setdefault(e["kind"], {}).setdefault(e["licence"], 0)
        summary[e["kind"]][e["licence"]] += 1
    script = os.path.relpath(os.path.abspath(sys.argv[0]), root)
    inv = {
        "_doc": f"Generated by {script} refresh from the tree, licenses/curated.json and "
                "licenses/upstreams.json. `check` (CI: licence-inventory-guard.yml) fails when the tree has a "
                "subject with no entry here. Transitive dependencies are not resolved. Not legal advice.",
        "summary": {k: dict(sorted(v.items(), key=lambda x: (-x[1], x[0]))) for k, v in sorted(summary.items())},
        "upstream_modules": {m["id"]: {"path": m["path"], "upstream": m["upstream"], "licence": m["licence"]}
                             for m in ups},
        "rootfs_packages": {
            "_doc": "Packages installed INTO images by Dockerfile RUN lines (package -> Dockerfiles). Not gated; "
                    "licences are each distribution's per-package metadata and are not resolved here.",
            "counts": {pm: len(v) for pm, v in sorted(rootfs.items())},
            **{pm: dict(sorted(v.items())) for pm, v in sorted(rootfs.items())},
        },
        "entries": entries,
    }
    with open(p, "w") as h:
        json.dump(inv, h, indent=1, ensure_ascii=False)
        h.write("\n")
    print(f"inventory: {len(entries)} entries", file=sys.stderr)
    return 0


def check(root):
    _, _, subj, _ = discover(root)
    p = os.path.join(root, "licenses/inventory.json")
    inv = json.load(open(p)).get("entries", {}) if os.path.exists(p) else {}
    missing = sorted(k for k in subj if k not in inv)
    bad = sorted(k for k, e in inv.items() if e.get("kind") in ("dir", "vendored") and
                 e.get("licence") == "NOASSERTION" and k in subj)
    for k in missing:
        print(f"MISSING  {k}  (declared in {subj[k]['declared_in'][0]})")
    for k in bad:
        print(f"NO-LICENCE  {k}  (licenses/curated.json::directories has no entry)")
    if missing or bad:
        script = os.path.relpath(os.path.abspath(sys.argv[0]), root)
        print(f"\n{len(missing)} subject(s) without an inventory entry, {len(bad)} directory(ies) without a licence.\n"
              "Add the directory to licenses/curated.json (or the upstream to licenses/upstreams.json), then run\n"
              f"  python3 {script} refresh .\n"
              "and commit licenses/inventory.json.", file=sys.stderr)
        return 1
    print(f"licence inventory: {len(subj)} subjects, all covered")
    return 0


def main(argv):
    if len(argv) < 3 or argv[1] not in ("refresh", "check"):
        print(__doc__, file=sys.stderr)
        return 2
    root = os.path.abspath(argv[2])
    return refresh(root, "--offline" in argv) if argv[1] == "refresh" else check(root)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
