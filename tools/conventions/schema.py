"""A structural validator for the convention JSON Schemas, standard library only.

It interprets the committed schemas in `docs/spec/schemas/` directly, so it enforces exactly what
they say, and it implements only the Draft 2020-12 keywords those schemas use: `type`, `const`,
`enum`, `pattern`, `minLength`, `maxLength`, `minimum`, `maximum`, `exclusiveMinimum`,
`minItems`, `maxItems`, `uniqueItems`, `items`, `required`, `properties`,
`additionalProperties`, `unevaluatedProperties`, `allOf`, `anyOf`, `oneOf`, `not`, `if`/`then`/
`else`, `$ref` (within a schema and across schemas by `$id`) and `format`, asserted, for the one
value `uint256`. A schema that uses any other keyword or format, anywhere in it, makes the
validator raise `SchemaError` when the schemas load instead of silently ignoring it, so it fails
closed when the schemas grow; a schema file that cannot be read or parsed raises it too.

Instances are JSON values as `json.loads` returns them. JSON equality is used for `const`,
`enum` and `uniqueItems`: `true` is not `1`, and `1` equals `1.0`. Patterns are ECMA-262
expressions; `$` is matched as the end of the string (Python's `$` would also match before a
final newline) and `\\d`/`\\w` are ASCII, as in ECMAScript without the `u` flag.
"""

from __future__ import annotations

import json
import re
from functools import lru_cache
from pathlib import Path
from typing import Any, Iterable

from tools.content.errors import ToolError

SCHEMA_DIR = Path(__file__).resolve().parents[2] / "docs" / "spec" / "schemas"
ID_PREFIX = "urn:6529-works:schema:"

_ANNOTATIONS = {"$schema", "$id", "$defs", "$comment", "title", "description", "examples", "default"}
_KEYWORDS = {
    "type", "const", "enum", "pattern", "minLength", "maxLength", "minimum", "maximum",
    "exclusiveMinimum", "minItems", "maxItems", "uniqueItems", "items", "required", "properties",
    "additionalProperties", "unevaluatedProperties", "allOf", "anyOf", "oneOf", "not", "if", "then",
    "else", "$ref", "format",
}  # fmt: skip
#: The `format` values this validator asserts; any other value is refused at load. `uint256` is
#: a decimal string from 0 to 2**256 - 1 (DCL-1): the common schema's pattern bounds the digits
#: and this check bounds the value, which a pattern can say only at great length.
_FORMATS = {"uint256"}
UINT256_MAX = 2**256 - 1
#: Keywords whose value is one subschema, and those whose value is a list or a map of them.
_SUBSCHEMA = ("items", "additionalProperties", "unevaluatedProperties", "not", "if", "then", "else")
_SUBSCHEMA_LISTS = ("allOf", "anyOf", "oneOf")
_SUBSCHEMA_MAPS = ("properties", "$defs")


class SchemaError(ToolError):
    """A schema uses a keyword this validator does not implement, or a `$ref` does not resolve."""


def _check_keywords(schema: Any, where: str) -> None:
    """Refuse, at load, any keyword or `format` this validator does not implement, wherever it
    sits: under `$defs`, `properties`, `items`, the conditionals and the combinators alike, so a
    subschema no instance happens to reach still fails closed."""
    if isinstance(schema, bool):
        return
    if not isinstance(schema, dict):
        raise SchemaError(f"a schema is an object or a boolean, at {where}")
    unknown = set(schema) - _KEYWORDS - _ANNOTATIONS
    if unknown:
        raise SchemaError(f"unsupported schema keyword(s) {sorted(unknown)} at {where}")
    if "format" in schema and schema["format"] not in _FORMATS:
        raise SchemaError(f"unsupported format {schema['format']!r} at {where}")
    for key in _SUBSCHEMA:
        if key in schema:
            _check_keywords(schema[key], f"{where}/{key}")
    for key in _SUBSCHEMA_LISTS:
        if key in schema:
            if not isinstance(schema[key], list):
                raise SchemaError(f"{key} is a list of schemas, at {where}")
            for i, sub in enumerate(schema[key]):
                _check_keywords(sub, f"{where}/{key}/{i}")
    for key in _SUBSCHEMA_MAPS:
        if key in schema:
            if not isinstance(schema[key], dict):
                raise SchemaError(f"{key} is an object of schemas, at {where}")
            for name, sub in schema[key].items():
                _check_keywords(sub, f"{where}/{key}/{name}")


def schema_id(name: str) -> str:
    """The `$id` of a convention schema by its short name, e.g. `declarations`."""
    return f"{ID_PREFIX}{name}:v1"


def json_equal(a: Any, b: Any) -> bool:
    """JSON value equality: booleans are not numbers, and numbers compare by value."""
    if isinstance(a, bool) or isinstance(b, bool):
        return isinstance(a, bool) and isinstance(b, bool) and a == b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return a == b
    if isinstance(a, str) or isinstance(b, str) or a is None or b is None:
        return type(a) is type(b) and a == b
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(json_equal(x, y) for x, y in zip(a, b))
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(json_equal(a[k], b[k]) for k in a)
    return False


def _type_ok(value: Any, name: str) -> bool:
    if name == "null":
        return value is None
    if name == "boolean":
        return isinstance(value, bool)
    if name == "string":
        return isinstance(value, str)
    if name == "array":
        return isinstance(value, list)
    if name == "object":
        return isinstance(value, dict)
    if isinstance(value, bool):
        return False
    if name == "number":
        return isinstance(value, (int, float))
    if name == "integer":
        return isinstance(value, int) or (isinstance(value, float) and value.is_integer())
    raise SchemaError(f"unknown type {name!r}")


@lru_cache(maxsize=None)
def _regex(pattern: str) -> re.Pattern[str]:
    """Translate an ECMA-262 pattern: an unescaped `$` outside a class is the end of input."""
    out: list[str] = []
    in_class = False
    i = 0
    while i < len(pattern):
        ch = pattern[i]
        if ch == "\\" and i + 1 < len(pattern):
            out.append(pattern[i : i + 2])
            i += 2
            continue
        if ch == "[" and not in_class:
            in_class = True
        elif ch == "]" and in_class:
            in_class = False
        elif ch == "$" and not in_class:
            ch = r"\Z"
        out.append(ch)
        i += 1
    return re.compile("".join(out), re.ASCII)


def _uint256_ok(value: str) -> bool:
    """A decimal string without a leading zero whose value fits uint256 (`format: uint256`)."""
    if re.fullmatch(r"0|[1-9][0-9]{0,77}", value, re.ASCII) is None:
        return False
    return int(value) <= UINT256_MAX


def _pointer(path: str, key: str | int) -> str:
    text = str(key).replace("~", "~0").replace("/", "~1")
    return f"{path}/{text}"


class Validator:
    """Validates instances against a set of schemas keyed by `$id`."""

    def __init__(self, schemas: Iterable[dict]) -> None:
        self._schemas: dict[str, dict] = {}
        for schema in schemas:
            if not isinstance(schema, dict):
                raise SchemaError("a schema document is a JSON object")
            sid = schema.get("$id")
            if not isinstance(sid, str):
                raise SchemaError("every schema needs a string $id")
            _check_keywords(schema, sid)
            self._schemas[sid] = schema

    @classmethod
    def from_directory(cls, directory: Path = SCHEMA_DIR) -> "Validator":
        paths = sorted(Path(directory).glob("*.schema.json"))
        if not paths:
            raise SchemaError(f"no *.schema.json under {directory}")
        schemas = []
        for p in paths:
            try:
                schemas.append(json.loads(p.read_text(encoding="utf-8")))
            except OSError as exc:
                raise SchemaError(f"cannot read the schema {p.name}: {exc.strerror or exc}") from None
            except ValueError as exc:  # JSONDecodeError and UnicodeDecodeError
                raise SchemaError(f"the schema {p.name} is not UTF-8 JSON: {exc}") from None
            except RecursionError:
                raise SchemaError(f"the schema {p.name} nests too deeply") from None
            if not isinstance(schemas[-1], dict):
                raise SchemaError(f"the schema {p.name} is not a JSON object")
        return cls(schemas)

    @property
    def ids(self) -> list[str]:
        return sorted(self._schemas)

    def errors(self, instance: Any, sid: str) -> list[str]:
        """Every violation, as `<JSON pointer>: <message>`; empty when the instance is valid."""
        root = self._schemas.get(sid)
        if root is None:
            raise SchemaError(f"no schema with $id {sid}")
        errors, _ = self._validate(instance, root, root, "")
        return errors

    def is_valid(self, instance: Any, sid: str) -> bool:
        return not self.errors(instance, sid)

    # --- internals ---

    def _resolve(self, ref: str, root: dict) -> tuple[dict | bool, dict]:
        base, _, fragment = ref.partition("#")
        target_root = root if base == "" else self._schemas.get(base)
        if target_root is None:
            raise SchemaError(f"unresolvable $ref {ref}")
        node: Any = target_root
        if fragment:
            if not fragment.startswith("/"):
                raise SchemaError(f"unsupported $ref fragment {ref}")
            for part in fragment[1:].split("/"):
                part = part.replace("~1", "/").replace("~0", "~")
                if not isinstance(node, dict) or part not in node:
                    raise SchemaError(f"unresolvable $ref {ref}")
                node = node[part]
        return node, target_root

    def _validate(
        self, value: Any, schema: dict | bool, root: dict, path: str
    ) -> tuple[list[str], set[str]]:
        """(errors, names of the object members this schema evaluated)."""
        if schema is True:
            return [], set()
        if schema is False:
            return [f"{path or '/'}: no value is allowed here"], set()
        if not isinstance(schema, dict):
            raise SchemaError(f"a schema is an object or a boolean, at {path or '/'}")
        unknown = set(schema) - _KEYWORDS - _ANNOTATIONS
        if unknown:
            raise SchemaError(f"unsupported schema keyword(s) {sorted(unknown)} at {path or '/'}")
        where = path or "/"
        errors: list[str] = []
        evaluated: set[str] = set()

        def sub(s: Any, v: Any = value, p: str = path) -> tuple[list[str], set[str]]:
            return self._validate(v, s, root, p)

        if "$ref" in schema:
            target, target_root = self._resolve(schema["$ref"], root)
            errs, ev = self._validate(value, target, target_root, path)
            errors += errs
            evaluated |= ev
        if "type" in schema:
            names = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
            if not any(_type_ok(value, n) for n in names):
                errors.append(f"{where}: expected {' or '.join(names)}")
                return errors, evaluated  # the other keywords would only repeat the problem
        if "const" in schema and not json_equal(value, schema["const"]):
            errors.append(f"{where}: must be {json.dumps(schema['const'])}")
        if "enum" in schema and not any(json_equal(value, e) for e in schema["enum"]):
            errors.append(f"{where}: must be one of {json.dumps(schema['enum'])}")
        if isinstance(value, str):
            if "minLength" in schema and len(value) < schema["minLength"]:
                errors.append(f"{where}: shorter than {schema['minLength']} characters")
            if "maxLength" in schema and len(value) > schema["maxLength"]:
                errors.append(f"{where}: longer than {schema['maxLength']} characters")
            if "pattern" in schema and not _regex(schema["pattern"]).search(value):
                errors.append(f"{where}: does not match {schema['pattern']}")
            if schema.get("format") == "uint256" and not _uint256_ok(value):
                errors.append(f"{where}: not a uint256 decimal from 0 to 2**256 - 1")
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            if "minimum" in schema and value < schema["minimum"]:
                errors.append(f"{where}: below the minimum {schema['minimum']}")
            if "maximum" in schema and value > schema["maximum"]:
                errors.append(f"{where}: above the maximum {schema['maximum']}")
            if "exclusiveMinimum" in schema and value <= schema["exclusiveMinimum"]:
                errors.append(f"{where}: must be above {schema['exclusiveMinimum']}")
        if isinstance(value, list):
            if "minItems" in schema and len(value) < schema["minItems"]:
                errors.append(f"{where}: fewer than {schema['minItems']} items")
            if "maxItems" in schema and len(value) > schema["maxItems"]:
                errors.append(f"{where}: more than {schema['maxItems']} items")
            if schema.get("uniqueItems"):
                for i in range(len(value)):
                    if any(json_equal(value[i], value[j]) for j in range(i)):
                        errors.append(f"{where}: item {i} repeats an earlier item")
            if "items" in schema:
                for i, item in enumerate(value):
                    errors += sub(schema["items"], item, _pointer(path, i))[0]
        if isinstance(value, dict):
            for name in schema.get("required", []):
                if name not in value:
                    errors.append(f"{where}: missing required member {name!r}")
            properties = schema.get("properties", {})
            for name, member in value.items():
                if name in properties:
                    errors += sub(properties[name], member, _pointer(path, name))[0]
                    evaluated.add(name)
            if "additionalProperties" in schema:
                for name, member in value.items():
                    if name not in properties:
                        errs, _ = sub(schema["additionalProperties"], member, _pointer(path, name))
                        if schema["additionalProperties"] is False:
                            errs = [f"{_pointer(path, name)}: member not allowed"]
                        errors += errs
                        evaluated.add(name)
        for s in schema.get("allOf", []):
            errs, ev = sub(s)
            errors += errs
            evaluated |= ev
        if "anyOf" in schema:
            passing = [sub(s) for s in schema["anyOf"]]
            passing = [ev for errs, ev in passing if not errs]
            if not passing:
                errors.append(f"{where}: matches none of anyOf")
            for ev in passing:
                evaluated |= ev
        if "oneOf" in schema:
            results = [sub(s) for s in schema["oneOf"]]
            passing = [ev for errs, ev in results if not errs]
            if len(passing) != 1:
                errors.append(f"{where}: matches {len(passing)} of oneOf, not exactly one")
            else:
                evaluated |= passing[0]
        if "not" in schema and not sub(schema["not"])[0]:
            errors.append(f"{where}: matches a schema it must not match")
        if "if" in schema:
            if_errs, if_ev = sub(schema["if"])
            if not if_errs:
                evaluated |= if_ev
                if "then" in schema:
                    errs, ev = sub(schema["then"])
                    errors += errs
                    evaluated |= ev
            elif "else" in schema:
                errs, ev = sub(schema["else"])
                errors += errs
                evaluated |= ev
        if isinstance(value, dict) and "unevaluatedProperties" in schema:
            for name, member in value.items():
                if name not in evaluated:
                    if schema["unevaluatedProperties"] is False:
                        errors.append(f"{_pointer(path, name)}: member not allowed")
                    else:
                        errors += sub(schema["unevaluatedProperties"], member, _pointer(path, name))[0]
        return errors, evaluated


@lru_cache(maxsize=1)
def default_validator() -> Validator:
    """The validator over the committed schemas."""
    return Validator.from_directory()


def validate(instance: Any, name: str) -> list[str]:
    """Errors of `instance` against the committed convention schema `name` (e.g. `promise-card`)."""
    return default_validator().errors(instance, schema_id(name))
