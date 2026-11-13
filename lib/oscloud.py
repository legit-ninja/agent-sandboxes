#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Samaritan's Purse
"""Extract named OpenStack clouds into a self-contained clouds.yaml.

Host-side helper for `sandbox run --os-cloud`. Reads a clouds.yaml (and a
matching secure.yaml next to it), keeps only the named clouds, copies any
cacert/cert/key files, rewrites those paths to the in-pod mount, and refuses
auth types that need an interactive or federated login.

Emits JSON to stdout (unless --write-dir is set, in which case files are
written there and a small metadata JSON is printed). Never prints secret
values. Cloud names only appear as identifiers.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
from pathlib import Path
from typing import Any

CLOUD_NAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_.-]{0,62}$")

# Auth plugins that need a browser, a prompt, a hardware token, or a host-side
# helper we cannot carry into the pod. Password, token, and application
# credentials are allowed (including the v3-prefixed names).
_REFUSE_AUTH_MARKERS = (
    "oidc",
    "totp",
    "kerberos",
    "saml",
    "oauth",
    "fedkerb",
    "multifactor",
    "adfs",
    "exec",
    "device",
    "authorizationcode",
    "authcode",
)

# Keys whose values, if they are filesystem paths, must ride with the entry.
_PATH_KEYS = ("cacert", "cert", "key")


class OsCloudError(Exception):
    """User-facing extraction error (printed without a traceback)."""


def load_yaml(text: str, source: str) -> Any:
    """Load YAML. Prefer PyYAML; fall back to a small subset parser."""
    try:
        import yaml  # type: ignore
    except ImportError:
        yaml = None
    if yaml is not None:
        try:
            data = yaml.safe_load(text)
        except yaml.YAMLError as e:
            raise OsCloudError(f"could not parse {source}: {e}") from e
        return data if data is not None else {}
    try:
        return _simple_yaml_load(text)
    except ValueError as e:
        raise OsCloudError(
            f"could not parse {source}: {e}. "
            "Install PyYAML (python3 -m pip install pyyaml) for full YAML support."
        ) from e


def _simple_yaml_load(text: str) -> Any:
    """Subset loader for typical clouds.yaml: block maps, lists, scalars.

    Refuses anchors, aliases, tags, and merge keys — those need a real parser.
    """
    if not text.strip():
        return {}
    # JSON is valid YAML; try it first (our own output is JSON).
    stripped = text.lstrip()
    if stripped[:1] in "{[":
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            pass
    if re.search(r"(^|\s)[&*!]|(^|\s)<<:", text, re.M):
        raise ValueError("anchors, aliases, tags, or merge keys are not supported without PyYAML")
    lines = text.splitlines()
    # Drop a leading ---
    while lines and (not lines[0].strip() or lines[0].strip() in ("---", "...")):
        lines.pop(0)
    val, _ = _parse_block(lines, 0, 0)
    return val if val is not None else {}


def _indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def _parse_block(lines: list[str], i: int, min_indent: int) -> tuple[Any, int]:
    # Skip blanks and comments
    while i < len(lines) and (not lines[i].strip() or lines[i].lstrip().startswith("#")):
        i += 1
    if i >= len(lines):
        return {}, i
    line = lines[i]
    if line.strip().startswith("- "):
        return _parse_list(lines, i, _indent_of(line))
    return _parse_map(lines, i, min_indent)


def _parse_map(lines: list[str], i: int, min_indent: int) -> tuple[dict, int]:
    out: dict[str, Any] = {}
    map_indent = None
    while i < len(lines):
        raw = lines[i]
        if not raw.strip() or raw.lstrip().startswith("#"):
            i += 1
            continue
        ind = _indent_of(raw)
        if map_indent is None:
            if ind < min_indent:
                break
            map_indent = ind
        if ind < map_indent:
            break
        if ind > map_indent:
            raise ValueError(f"unexpected indent at line {i + 1}")
        body = raw[ind:]
        if body.startswith("- "):
            raise ValueError(f"list item where a mapping key was expected (line {i + 1})")
        if ":" not in body:
            raise ValueError(f"expected 'key:' at line {i + 1}")
        key, _, rest = body.partition(":")
        key = _unquote(key.strip())
        rest = rest.strip()
        if rest.split("#", 1)[0].strip() == "" or rest.startswith("#"):
            # Nested value on following lines, or empty.
            nxt = i + 1
            while nxt < len(lines) and (not lines[nxt].strip() or lines[nxt].lstrip().startswith("#")):
                nxt += 1
            if nxt < len(lines) and _indent_of(lines[nxt]) > map_indent:
                val, i = _parse_block(lines, nxt, map_indent + 1)
            else:
                val = None
                i += 1
        else:
            val = _parse_scalar(rest.split(" #", 1)[0].rstrip())
            i += 1
        out[key] = val
    return out, i


def _parse_list(lines: list[str], i: int, list_indent: int) -> tuple[list, int]:
    out: list[Any] = []
    while i < len(lines):
        raw = lines[i]
        if not raw.strip() or raw.lstrip().startswith("#"):
            i += 1
            continue
        ind = _indent_of(raw)
        if ind < list_indent:
            break
        body = raw[ind:]
        if not body.startswith("- "):
            break
        rest = body[2:].strip()
        if rest == "" or rest.startswith("#"):
            nxt = i + 1
            while nxt < len(lines) and (not lines[nxt].strip() or lines[nxt].lstrip().startswith("#")):
                nxt += 1
            if nxt < len(lines) and _indent_of(lines[nxt]) > list_indent:
                val, i = _parse_block(lines, nxt, list_indent + 1)
            else:
                val = None
                i += 1
        elif rest.startswith("{") or ":" in rest and not rest.startswith(("'", '"')):
            # Inline map on the same line as `- key: val` (possibly more keys below).
            if rest.startswith("{"):
                val = _parse_scalar(rest)
                i += 1
            else:
                # Treat the rest as a one-line mapping start by wrapping.
                fake = " " * (ind + 2) + rest
                sub, i2 = _parse_map([fake] + lines[i + 1 :], 0, ind + 1)
                # i2 is relative to [fake]+rest; convert.
                consumed = max(i2 - 1, 0)
                i = i + 1 + consumed
                val = sub
        else:
            val = _parse_scalar(rest.split(" #", 1)[0].rstrip())
            i += 1
        out.append(val)
    return out, i


def _unquote(s: str) -> str:
    if len(s) >= 2 and s[0] == s[-1] and s[0] in ("'", '"'):
        if s[0] == "'":
            return s[1:-1].replace("''", "'")
        return bytes(s[1:-1], "utf-8").decode("unicode_escape")
    return s


def _parse_scalar(s: str) -> Any:
    s = s.strip()
    if s in ("", "~", "null", "Null", "NULL"):
        return None
    if s in ("true", "True", "TRUE", "yes", "Yes", "on"):
        return True
    if s in ("false", "False", "FALSE", "no", "No", "off"):
        return False
    if (s.startswith("'") and s.endswith("'")) or (s.startswith('"') and s.endswith('"')):
        return _unquote(s)
    if re.fullmatch(r"-?\d+", s):
        try:
            return int(s)
        except ValueError:
            return s
    if re.fullmatch(r"-?\d+\.\d+", s):
        try:
            return float(s)
        except ValueError:
            return s
    return s


def deep_merge(base: Any, over: Any) -> Any:
    if isinstance(base, dict) and isinstance(over, dict):
        out = dict(base)
        for k, v in over.items():
            out[k] = deep_merge(out[k], v) if k in out else v
        return out
    return over


def validate_cloud_name(name: str) -> str:
    if not CLOUD_NAME_RE.match(name or ""):
        raise OsCloudError(
            f"invalid --os-cloud name {name!r}: use a letter, then letters, digits, '_', '.' or '-' (max 63)."
        )
    return name


def refuse_auth(cloud: str, entry: dict) -> None:
    auth_type = entry.get("auth_type") or (entry.get("auth") or {}).get("auth_type") or ""
    if not isinstance(auth_type, str):
        auth_type = str(auth_type)
    norm = auth_type.lower().replace("-", "").replace("_", "")
    for marker in _REFUSE_AUTH_MARKERS:
        if marker.replace("_", "").replace("-", "") in norm:
            raise OsCloudError(
                f"cloud {cloud!r} uses auth_type {auth_type!r}, which needs an interactive, "
                "federated, or host-side login that cannot be carried into the sandbox. "
                "Use a password, token, or application-credential entry "
                "(docs/how-to/tier3-infra-credentials.md)."
            )
    # Walk for an exec-style helper.
    def _walk(obj: Any) -> None:
        if isinstance(obj, dict):
            for k, v in obj.items():
                if str(k).lower() in ("exec", "command", "process"):
                    raise OsCloudError(
                        f"cloud {cloud!r} has an {k!r} field that cannot be carried into the sandbox. "
                        "Use a self-contained password, token, or application-credential entry."
                    )
                _walk(v)
        elif isinstance(obj, list):
            for v in obj:
                _walk(v)

    _walk(entry)


def _auth_url(entry: dict) -> str:
    auth = entry.get("auth") if isinstance(entry.get("auth"), dict) else {}
    url = auth.get("auth_url") or entry.get("auth_url") or ""
    if not isinstance(url, str) or not url.strip():
        return ""
    return url.strip()


def _collect_paths(entry: dict) -> list[tuple[list[str], str]]:
    """(key_path, host_path) for cacert/cert/key, and verify when it is a path."""
    found: list[tuple[list[str], str]] = []

    def walk(obj: Any, path: list[str]) -> None:
        if not isinstance(obj, dict):
            return
        for k, v in obj.items():
            here = path + [str(k)]
            if str(k) in _PATH_KEYS and isinstance(v, str) and v.strip():
                found.append((here, v.strip()))
            elif str(k) == "verify" and isinstance(v, str) and v.strip() and v.strip().lower() not in (
                "true",
                "false",
                "yes",
                "no",
            ):
                found.append((here, v.strip()))
            elif isinstance(v, dict):
                walk(v, here)

    walk(entry, [])
    return found


def _set_path(entry: dict, key_path: list[str], value: str) -> None:
    cur = entry
    for k in key_path[:-1]:
        cur = cur[k]
    cur[key_path[-1]] = value


def _resolve_host_path(raw: str, relative_to: Path) -> Path:
    expanded = Path(os.path.expanduser(raw))
    if not expanded.is_absolute():
        expanded = (relative_to / expanded).resolve()
    return expanded


def extract(
    clouds_file: Path,
    names: list[str],
    secure_file: Path | None,
    mount_dir: str,
    write_dir: Path | None,
) -> dict[str, Any]:
    raw = clouds_file.read_text(encoding="utf-8", errors="replace")
    data = load_yaml(raw, str(clouds_file))
    if not isinstance(data, dict):
        raise OsCloudError(f"{clouds_file} is not a YAML mapping")
    clouds = data.get("clouds")
    if not isinstance(clouds, dict) or not clouds:
        raise OsCloudError(f"no 'clouds:' mapping in {clouds_file}")

    secure_clouds: dict = {}
    if secure_file is not None and secure_file.is_file():
        sdata = load_yaml(
            secure_file.read_text(encoding="utf-8", errors="replace"),
            str(secure_file),
        )
        if isinstance(sdata, dict) and isinstance(sdata.get("clouds"), dict):
            secure_clouds = sdata["clouds"]

    available = list(clouds.keys())
    extracted: dict[str, Any] = {}
    auth_urls: list[str] = []
    carried: list[dict[str, str]] = []
    file_counter = 0

    for name in names:
        validate_cloud_name(name)
        # Match case-insensitively, keep the original key spelling from the file.
        key = next((k for k in clouds if str(k) == name), None)
        if key is None:
            key = next((k for k in clouds if str(k).lower() == name.lower()), None)
        if key is None:
            shown = ", ".join(str(k) for k in available) or "(none)"
            raise OsCloudError(
                f"cloud {name!r} not found in {clouds_file}. Clouds in that file: {shown}."
            )
        entry = clouds[key]
        if not isinstance(entry, dict):
            raise OsCloudError(f"cloud {name!r} is not a mapping")
        entry = dict(entry)  # shallow; deep_merge copies nested
        sec = secure_clouds.get(key)
        if sec is None:
            sec = next((secure_clouds[k] for k in secure_clouds if str(k).lower() == str(key).lower()), None)
        if isinstance(sec, dict):
            entry = deep_merge(entry, sec)
        if entry.get("profile") and not _auth_url(entry):
            raise OsCloudError(
                f"cloud {name!r} uses a vendor profile ({entry.get('profile')!r}) with no auth_url; "
                "that profile cannot be resolved into a self-contained entry. "
                "Put a full auth_url (and credentials) in clouds.yaml or secure.yaml."
            )
        refuse_auth(name, entry)
        url = _auth_url(entry)
        if not url:
            raise OsCloudError(
                f"cloud {name!r} has no auth.auth_url; a self-contained entry needs one."
            )
        if not url.lower().startswith(("https://", "http://")):
            raise OsCloudError(
                f"cloud {name!r} auth_url {url!r} is not an http(s) URL."
            )
        auth_urls.append(url)

        for key_path, host_raw in _collect_paths(entry):
            host_path = _resolve_host_path(host_raw, clouds_file.parent)
            if not host_path.is_file():
                raise OsCloudError(
                    f"cloud {name!r} {'.'.join(key_path)} points at {host_raw}, which is not a readable file."
                )
            ext = host_path.suffix if host_path.suffix else ".pem"
            fname = f"{key_path[-1]}-{file_counter}{ext}"
            file_counter += 1
            pod_path = f"{mount_dir.rstrip('/')}/{fname}"
            _set_path(entry, key_path, pod_path)
            carried.append({"name": fname, "src": str(host_path)})

        extracted[str(key)] = entry

    payload = {"clouds": extracted}
    meta = {
        "clouds": [str(k) for k in extracted],
        "auth_urls": auth_urls,
        "files": [{"name": f["name"]} for f in carried],  # no host paths in metadata we might log
        "os_cloud": next(iter(extracted)) if len(extracted) == 1 else "",
        "clouds_yaml": json.dumps(payload, indent=2, sort_keys=True) + "\n",
        "file_srcs": carried,  # used only when writing; stripped for stdout if needed
    }

    if write_dir is not None:
        write_dir.mkdir(parents=True, exist_ok=True)
        os.chmod(write_dir, 0o700)
        (write_dir / "clouds.yaml").write_text(meta["clouds_yaml"], encoding="utf-8")
        os.chmod(write_dir / "clouds.yaml", 0o600)
        for f in carried:
            dest = write_dir / f["name"]
            shutil.copyfile(f["src"], dest)
            os.chmod(dest, 0o600)
        public = {k: meta[k] for k in ("clouds", "auth_urls", "files", "os_cloud")}
        (write_dir / "meta.json").write_text(json.dumps(public, indent=2) + "\n", encoding="utf-8")
        return public

    public = {k: meta[k] for k in ("clouds", "auth_urls", "files", "os_cloud", "clouds_yaml")}
    return public


def find_clouds_file(explicit: str | None, cwd: str, home: str, env_file: str | None) -> Path:
    if explicit:
        p = Path(os.path.expanduser(explicit))
        if not p.is_file():
            raise OsCloudError(f"--os-clouds-file {explicit} does not exist or is not a file.")
        return p
    candidates = []
    if env_file:
        candidates.append(Path(os.path.expanduser(env_file)))
    candidates.append(Path(cwd) / "clouds.yaml")
    candidates.append(Path(home) / ".config" / "openstack" / "clouds.yaml")
    candidates.append(Path("/etc/openstack/clouds.yaml"))
    for p in candidates:
        try:
            if p.is_file():
                return p
        except OSError:
            continue
    raise OsCloudError(
        "no clouds.yaml found. Pass --os-clouds-file <PATH>, or place one at "
        "$OS_CLIENT_CONFIG_FILE, ./clouds.yaml, ~/.config/openstack/clouds.yaml, "
        "or /etc/openstack/clouds.yaml."
    )


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Extract named OpenStack clouds for a sandbox.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("find", help="print the clouds.yaml path that would be used")
    f.add_argument("--os-clouds-file", default="")
    f.add_argument("--cwd", default=os.getcwd())
    f.add_argument("--home", default=str(Path.home()))
    e = sub.add_parser("extract", help="extract named clouds")
    e.add_argument("names", nargs="+")
    e.add_argument("--os-clouds-file", default="")
    e.add_argument("--cwd", default=os.getcwd())
    e.add_argument("--home", default=str(Path.home()))
    e.add_argument("--mount-dir", default="/home/agent/.config/openstack")
    e.add_argument("--write-dir", default="")
    args = ap.parse_args(argv)
    try:
        env_file = os.environ.get("OS_CLIENT_CONFIG_FILE") or None
        if args.cmd == "find":
            path = find_clouds_file(args.os_clouds_file or None, args.cwd, args.home, env_file)
            print(str(path))
            return 0
        path = find_clouds_file(args.os_clouds_file or None, args.cwd, args.home, env_file)
        secure = path.parent / "secure.yaml"
        result = extract(
            path,
            list(args.names),
            secure if secure.is_file() else None,
            args.mount_dir,
            Path(args.write_dir) if args.write_dir else None,
        )
        json.dump({k: result[k] for k in result if k != "file_srcs"}, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return 0
    except OsCloudError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1
    except OSError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
