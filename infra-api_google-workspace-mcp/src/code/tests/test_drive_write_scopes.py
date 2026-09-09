"""
Regression guard for the Drive write scope.

Every Drive-mutating tool used to be declared with the drive.file scope. Under
domain-wide delegation the decorator's scope list is not a minimum that gets
checked against a broader consented token, it is the exact scope the service
account token is minted with (auth/google_auth.py -> from_service_account_file).
drive.file can only address files this application itself created, so every
mutating tool returned HTTP 404 "File not found" for any folder or file the
owner made by hand -- including the Drive root.

These tests read the decorators straight out of the source with ast, so a
newly added Drive write tool is covered without editing a list here.
"""

import ast
import pathlib

import pytest

CODE_ROOT = pathlib.Path(__file__).resolve().parent.parent

DRIVE_SCOPE = "https://www.googleapis.com/auth/drive"
DRIVE_FILE_SCOPE = "https://www.googleapis.com/auth/drive.file"

# Drive API verbs that address an existing file or folder by id, or attach a new
# file to an existing parent. Each one is unreachable under drive.file unless
# this application created the target itself.
MUTATING_VERBS = {"create", "update", "delete", "copy"}


def _tool_modules():
    return sorted(
        path
        for path in CODE_ROOT.glob("g*/*.py")
        if path.name.endswith("_tools.py")
    )


def _decorator_scopes(node):
    """Yield every (service_type, scope_name) this function's decorators request."""
    for decorator in node.decorator_list:
        if not isinstance(decorator, ast.Call):
            continue
        name = getattr(decorator.func, "id", None) or getattr(
            decorator.func, "attr", None
        )
        if name == "require_google_service":
            args = decorator.args
            if len(args) >= 2 and isinstance(args[0], ast.Constant):
                for scope in _scope_names(args[1]):
                    yield args[0].value, scope
        elif name == "require_multiple_services" and decorator.args:
            for entry in getattr(decorator.args[0], "elts", []):
                if not isinstance(entry, ast.Dict):
                    continue
                spec = {
                    key.value: value
                    for key, value in zip(entry.keys, entry.values)
                    if isinstance(key, ast.Constant)
                }
                service = spec.get("service_type")
                if isinstance(service, ast.Constant) and "scopes" in spec:
                    for scope in _scope_names(spec["scopes"]):
                        yield service.value, scope


def _scope_names(node):
    """Scope names as written -- a literal group name, or a bare constant name."""
    if isinstance(node, ast.Constant):
        return [node.value]
    if isinstance(node, ast.Name):
        return [node.id]
    if isinstance(node, (ast.List, ast.Tuple)):
        names = []
        for element in node.elts:
            names.extend(_scope_names(element))
        return names
    return []


def _mutates(node, module_functions, seen=None):
    """Does this function issue a mutating Drive call, directly or via a helper?

    Most tools are a docstring and a tail call into a module-level _..._impl
    helper, so a body-only scan reports create_drive_folder as read-only.
    """
    seen = seen if seen is not None else set()
    if node.name in seen:
        return False
    seen.add(node.name)

    for inner in ast.walk(node):
        if not isinstance(inner, ast.Call):
            continue
        if isinstance(inner.func, ast.Attribute):
            if inner.func.attr in MUTATING_VERBS:
                return True
        elif isinstance(inner.func, ast.Name):
            helper = module_functions.get(inner.func.id)
            if helper is not None and _mutates(helper, module_functions, seen):
                return True
    return False


def _drive_tools():
    """(module, function, scope names, mutates) for every Drive-backed tool."""
    found = []
    for path in _tool_modules():
        tree = ast.parse(path.read_text(), filename=str(path))
        functions = [
            node
            for node in ast.walk(tree)
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
        ]
        by_name = {node.name: node for node in functions}
        for node in functions:
            drive_scopes = [
                scope
                for service, scope in _decorator_scopes(node)
                if service == "drive"
            ]
            if drive_scopes:
                found.append(
                    (path.name, node.name, drive_scopes, _mutates(node, by_name))
                )
    return found


def test_drive_tools_are_discovered():
    """A parser that silently finds nothing would make every test below vacuous."""
    tools = _drive_tools()
    assert len(tools) >= 15, f"only found {len(tools)} Drive tools"
    assert any(mutates for _, _, _, mutates in tools)


@pytest.mark.parametrize(
    "module,func,scopes",
    [
        (module, func, tuple(scopes))
        for module, func, scopes, mutates in _drive_tools()
        if mutates
    ],
)
def test_mutating_drive_tools_do_not_use_drive_file(module, func, scopes):
    """drive.file cannot see a folder the owner created by hand -- it 404s."""
    assert "drive_file" not in scopes, (
        f"{module}:{func} mutates Drive but is declared with 'drive_file'. "
        "That scope only addresses files this application created, so the call "
        "returns HTTP 404 for any pre-existing file or folder. Use 'drive_write'."
    )


def test_drive_write_group_is_full_drive():
    """Pin the scope 'drive_write' resolves to, so a refactor cannot narrow it."""
    from auth.service_decorator import SCOPE_GROUPS

    assert SCOPE_GROUPS["drive_write"] == DRIVE_SCOPE
    assert SCOPE_GROUPS["drive_file"] == DRIVE_FILE_SCOPE


def test_unknown_scope_group_is_rejected():
    """'drive_full' and 'script_full' shipped as literal strings and never worked."""
    from auth.service_decorator import _resolve_scopes

    for typo in ("drive_full", "script_full"):
        with pytest.raises(ValueError, match="Unknown OAuth scope group"):
            _resolve_scopes(typo)

    assert _resolve_scopes("drive_write") == [DRIVE_SCOPE]
    assert _resolve_scopes(DRIVE_SCOPE) == [DRIVE_SCOPE]
