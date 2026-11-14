"""The conservation-floor check before attestation: DCL-3 (where the declarations are and what
fixes them), DCL-4 (the facts, each waivable with a reason), DCL-5 (`CHECK_FLOOR` and its
`CHECK_<fact>` and `ALWAYS` pseudo-rules) and DCL-7 (a time capsule is outside policy)."""

from __future__ import annotations

import base64
import copy
import gzip
import hashlib
import unittest
from typing import Any, Callable

from tools.conventions import floor, testdata
from tools.conventions.floor import DECLARATIONS_MIME, check_floor, floor_states, locator_network
from tools.conventions.testdata import DECL_FILE, canonical, sha

F1, F2 = "0x" + "11" * 32, "0x" + "22" * 32


def run(inp: dict) -> dict:
    return check_floor(inp["package"], inp["policy"], inp["contents"], inp["observed"])


def with_doc(inp: dict, change: Callable[[dict], None]) -> dict:
    """Change the declarations document and re-derive its bytes and media hash."""
    out = copy.deepcopy(inp)
    doc = testdata.jcs.parse(out["contents"][DECL_FILE])
    change(doc)
    data = canonical(doc)
    out["contents"][DECL_FILE] = data
    out["package"]["files"][DECL_FILE].update(sha256Hash=sha(data), length=len(data))
    out["package"]["media"][-1]["sha256Hash"] = sha(data)
    return out


def edit(inp: dict, change: Callable[[dict], None]) -> dict:
    out = copy.deepcopy(inp)
    change(out)
    return out


class ExamplesTest(unittest.TestCase):
    def test_still_image_example_meets_the_floor(self) -> None:
        """DCL-5: declarations.json against a matching package meets every applicable fact."""
        result = run(testdata.still_floor_input())
        self.assertTrue(result["ok"], result["refusals"])
        self.assertEqual(floor_states(result), {"storage": "met", "format": "met", "license": "met",
                                                "generative": "not_applicable", "display": "met"})

    def test_generative_example_meets_the_generative_fact(self) -> None:
        """DCL-4, DCL-5 CHECK_generative: a script primary with a VRF seed policy."""
        result = run(testdata.generative_floor_input())
        self.assertTrue(result["ok"], result["refusals"])
        self.assertEqual(result["facts"]["generative"]["state"], "met")

    def test_time_capsule_example_is_refused_by_the_v1_policy(self) -> None:
        """DCL-7 and DCL-5 ALWAYS: a time capsule is refused unless the policy allows it, and a
        waiver the policy does not list is refused."""
        result = run(testdata.time_capsule_floor_input())
        self.assertFalse(result["ok"])
        self.assertIn("time capsule outside policy (DCL-7)", result["refusals"])
        self.assertIn("waiver not allowed: storage", result["refusals"])

    def test_time_capsule_example_passes_a_policy_that_allows_it(self) -> None:
        """DCL-4: a waived fact with its reason shows as waived."""
        inp = edit(testdata.time_capsule_floor_input(),
                   lambda i: i["policy"].update(allowsTimeCapsule=True, waivable=["storage"]))
        result = run(inp)
        self.assertTrue(result["ok"], result["refusals"])
        self.assertEqual(result["facts"]["storage"]["state"], "waived")
        self.assertIn("Illustration of a waiver", result["facts"]["storage"]["reasons"][0])


class DeclarationsFileTest(unittest.TestCase):
    """DCL-3: one AUXILIARY file of the declarations MIME type, Identity, one chunk, canonical,
    schema-valid, bound to the content hash."""

    def test_no_declarations(self) -> None:
        """DCL-5: none listed is refused when the policy requires one; else every fact is unmet,
        except that a work that is not generative has `generative` not_applicable."""
        def drop(i: dict) -> None:
            i["package"]["media"].pop()
        refused = run(edit(testdata.still_floor_input(), drop))
        self.assertEqual(refused["refusals"], ["no declarations"])
        allowed = run(edit(testdata.still_floor_input(),
                           lambda i: (drop(i), i["policy"].update(requiresDeclarations=False))))
        self.assertTrue(allowed["ok"])
        self.assertEqual(floor_states(allowed), {"storage": "unmet", "format": "unmet", "license": "unmet",
                                                 "generative": "not_applicable", "display": "unmet"})
        self.assertIsNone(allowed["declarationsFileId"])
        generative = run(edit(testdata.generative_floor_input(),
                              lambda i: (drop(i), i["policy"].update(requiresDeclarations=False))))
        self.assertEqual(set(floor_states(generative).values()), {"unmet"})

    def test_two_declarations_are_ambiguous(self) -> None:
        def second(i: dict) -> None:
            other = "0x" + "99" * 32
            i["package"]["media"].append({"fileId": other, "sha256Hash": sha(b"x"), "role": "AUXILIARY"})
            i["package"]["files"][other] = dict(i["package"]["files"][DECL_FILE])
        self.assertEqual(run(edit(testdata.still_floor_input(), second))["refusals"],
                         ["ambiguous declarations"])

    def test_declarations_mime_only_counts_on_an_auxiliary_file(self) -> None:
        def preview(i: dict) -> None:
            i["package"]["media"][-1]["role"] = "PREVIEW"
        result = run(edit(testdata.still_floor_input(), preview))
        self.assertEqual(result["refusals"], ["no declarations"])

    def test_file_refusals(self) -> None:
        """DCL-5's `require` lines on the declarations file, one negative case each."""
        cases: dict[str, Callable[[dict], None]] = {
            "not stored as Identity": lambda i: i["package"]["files"][DECL_FILE].update(encoding="Gzip"),
            "longer than 24575": lambda i: i["package"]["files"][DECL_FILE].update(length=24576),
            "not complete": lambda i: i["package"]["files"][DECL_FILE].update(complete=False),
            "were not supplied": lambda i: i["contents"].clear(),
            "do not hash to the media entry": lambda i: i["package"]["media"][-1].update(sha256Hash="0x" + "00" * 32),
            "no fileInfo for AUXILIARY": lambda i: i["package"]["files"].pop(DECL_FILE),
        }
        for expected, change in cases.items():
            with self.subTest(expected):
                result = run(edit(testdata.still_floor_input(), change))
                self.assertFalse(result["ok"])
                self.assertTrue(any(expected in r for r in result["refusals"]), result["refusals"])

    def test_bytes_must_be_canonical_valid_and_bound(self) -> None:
        base = testdata.still_floor_input()
        doc = testdata.example("declarations.json")
        pretty = (testdata.EXAMPLES / "declarations.json").read_bytes()
        cases = {
            "not in RFC 8785 canonical form": pretty,
            "declarations.v1": canonical({**doc, "extra": 1}),
            "contentHash is not the item's": canonical({**doc, "contentHash": "0x" + "ab" * 32}),
            "not strict JSON": b'{"v":1,"v":1}',
        }
        for expected, data in cases.items():
            with self.subTest(expected):
                inp = edit(base, lambda i: (
                    i["contents"].__setitem__(DECL_FILE, data),
                    i["package"]["files"][DECL_FILE].update(sha256Hash=sha(data), length=len(data)),
                    i["package"]["media"][-1].update(sha256Hash=sha(data)),
                ))  # fmt: skip
                result = run(inp)
                self.assertFalse(result["ok"])
                self.assertTrue(any(expected in r for r in result["refusals"]), result["refusals"])


class FactTest(unittest.TestCase):
    """DCL-5's `CHECK_<fact>` rules, a negative case per `require`."""

    def assert_refused(self, inp: dict, fact: str, needle: str) -> None:
        result = run(inp)
        self.assertFalse(result["ok"])
        self.assertEqual(result["facts"][fact]["state"], "failed", result["facts"])
        self.assertTrue(any(needle in r for r in result["facts"][fact]["reasons"]), result["facts"][fact])

    def test_storage(self) -> None:
        """DCL-5 CHECK_storage."""
        base = testdata.still_floor_input()
        receipts = ["conservation", "storage", "files", 0, "receipts"]

        def at(doc: dict, path: list) -> Any:
            for key in path:
                doc = doc[key]
            return doc

        cases = [
            ("exactly the media files", with_doc(base, lambda d: d["conservation"]["storage"]["files"].pop())),
            ("sha256 is not the media entry's", with_doc(base, lambda d: at(d, receipts[:-1]).update(sha256="0x" + "00" * 32))),
            ("fewer than two receipts", with_doc(base, lambda d: at(d, receipts)[1].update(network="arweave", uri=at(d, receipts)[0]["uri"], provider=at(d, receipts)[0]["provider"]))),
            ("fewer than two receipts", with_doc(base, lambda d: at(d, receipts).pop())),
            ("does not match the address", with_doc(base, lambda d: at(d, receipts)[0].update(network="ipfs", provider="other"))),
            ("could not be fetched", edit(base, lambda i: i["observed"]["fetched"].__setitem__("ar://oPSkhDkQRE6xQF7RQgVgRkmoJKW7XueRtNdpwXEEnRc", None))),
            ("does not decode to the file's SHA-256", edit(base, lambda i: i["observed"]["fetched"].__setitem__("ar://oPSkhDkQRE6xQF7RQgVgRkmoJKW7XueRtNdpwXEEnRc", "0x" + "00" * 32))),
            ("observed hash that is not", edit(base, lambda i: i["observed"]["fetched"].__setitem__("ar://oPSkhDkQRE6xQF7RQgVgRkmoJKW7XueRtNdpwXEEnRc", "0xABC"))),
        ]  # fmt: skip
        for needle, inp in cases:
            with self.subTest(needle):
                self.assert_refused(inp, "storage", needle)

    def test_storage_two_receipts_same_network_distinct_providers_pass(self) -> None:
        """DCL-5: at least two receipts of distinct network or provider."""
        def same_network(d: dict) -> None:
            r = d["conservation"]["storage"]["files"][0]["receipts"]
            r[1] = dict(r[0], provider="second bundler")
        result = run(with_doc(testdata.still_floor_input(), same_network))
        self.assertTrue(result["ok"], result["refusals"])

    def test_storage_decodes_fetched_bytes_by_the_file_encoding(self) -> None:
        """DCL-5 CHECK_storage: sha256(decode(fetch(uri), encoding)) == the media SHA-256."""
        media = b"6529 works media bytes" * 50
        digest = sha(media)
        for encoding, stored in (("Identity", media), ("Gzip", gzip.compress(media, mtime=0)),
                                 ("Base64", base64.b64encode(media))):  # fmt: skip
            with self.subTest(encoding):
                doc = testdata.example("declarations.json")
                for f in doc["conservation"]["storage"]["files"]:
                    if f["fileId"] == F1:
                        f["sha256"] = digest
                inp = testdata.floor_input(doc, [(F1, digest, "PRIMARY", "image/png"),
                                                 (F2, doc["conservation"]["storage"]["files"][1]["sha256"], "PREVIEW", "image/webp")])  # fmt: skip
                inp["package"]["files"][F1].update(encoding=encoding, length=len(stored))
                inp["package"]["item"]["contentHash"] = doc["contentHash"]
                for r in doc["conservation"]["storage"]["files"][0]["receipts"]:
                    inp["observed"]["fetched"][r["uri"]] = stored
                result = run(inp)
                self.assertEqual(result["facts"]["storage"]["state"], "met", result["facts"]["storage"])
                bad = edit(inp, lambda i: [i["observed"]["fetched"].__setitem__(r["uri"], b"not it")
                                           for r in doc["conservation"]["storage"]["files"][0]["receipts"]])
                self.assertEqual(run(bad)["facts"]["storage"]["state"], "failed")

    def test_storage_receipt_forms(self) -> None:
        """DCL-4/DCL-5 CHECK_storage: a `decoded` copy hashes to the file's SHA-256 as fetched; a
        `stored` copy must be fileInfo.length bytes that decode to it."""
        media = b"6529 works media bytes" * 50
        stored = gzip.compress(media, mtime=0)
        digest = sha(media)
        doc = testdata.example("declarations.json")
        f1 = doc["conservation"]["storage"]["files"][0]
        f1["sha256"] = digest
        f1["receipts"][1]["form"] = "decoded"
        inp = testdata.floor_input(doc, [(F1, digest, "PRIMARY", "image/png"),
                                         (F2, doc["conservation"]["storage"]["files"][1]["sha256"], "PREVIEW", "image/webp")])  # fmt: skip
        inp["package"]["files"][F1].update(encoding="Gzip", length=len(stored))
        stored_uri, decoded_uri = f1["receipts"][0]["uri"], f1["receipts"][1]["uri"]
        inp["observed"]["fetched"].update({stored_uri: stored, decoded_uri: media})
        self.assertEqual(run(inp)["facts"]["storage"]["state"], "met", run(inp)["facts"]["storage"])
        swapped = edit(inp, lambda i: i["observed"]["fetched"].update({stored_uri: media, decoded_uri: stored}))
        reasons = run(swapped)["facts"]["storage"]["reasons"]
        self.assertTrue(any("not fileInfo.length bytes" in r for r in reasons), reasons)
        self.assertTrue(any(decoded_uri in r and "SHA-256" in r for r in reasons), reasons)

    def test_format(self) -> None:
        """DCL-5 CHECK_format."""
        base = testdata.still_floor_input()
        cases = [
            ("exactly the media files", with_doc(base, lambda d: d["conservation"]["format"]["files"].pop())),
            ("mimeType is not the content store's", with_doc(base, lambda d: d["conservation"]["format"]["files"][0].update(mimeType="image/jpeg"))),
            ("needs width and height", with_doc(base, lambda d: d["conservation"]["format"]["files"][0].pop("height"))),
            ("decoding gives other dimensions", edit(base, lambda i: i["observed"]["dimensions"].__setitem__(F1, {"width": 1, "height": 1}))),
            ("were not measured", edit(base, lambda i: i["observed"]["dimensions"].pop(F1))),
        ]  # fmt: skip
        for needle, inp in cases:
            with self.subTest(needle):
                self.assert_refused(inp, "format", needle)

    def test_format_time_based_media_needs_a_duration(self) -> None:
        def audio(d: dict) -> None:
            d["conservation"]["format"]["files"][1] = {"fileId": F2, "mimeType": "audio/flac"}
        inp = with_doc(testdata.still_floor_input(), audio)
        inp["package"]["files"][F2]["mimeType"] = "audio/flac"
        self.assert_refused(inp, "format", "durationSeconds")
        fixed = with_doc(inp, lambda d: d["conservation"]["format"]["files"][1].update(durationSeconds=12.5))
        self.assertEqual(run(fixed)["facts"]["format"]["state"], "met")

    def test_license(self) -> None:
        """DCL-5 CHECK_license: compared by license key (case-insensitive), text by sha256Of."""
        base = testdata.still_floor_input()
        same_key = with_doc(base, lambda d: d["conservation"]["license"].update(spdxId="cc0-1.0"))
        self.assertEqual(run(same_key)["facts"]["license"]["state"], "met")
        cases = [
            ("spdxId is not the item's", with_doc(base, lambda d: d["conservation"]["license"].update(spdxId="MIT"))),
            ("textSha256 is not sha256Of", with_doc(base, lambda d: d["conservation"]["license"].update(textSha256="0x" + "00" * 32))),
            ("no fileInfo for the license text", edit(base, lambda i: i["package"]["files"].pop(testdata.LICENSE_TEXT))),
        ]  # fmt: skip
        for needle, inp in cases:
            with self.subTest(needle):
                self.assert_refused(inp, "license", needle)

    def test_generative(self) -> None:
        """DCL-5 CHECK_generative."""
        base = testdata.generative_floor_input()
        dep = {"name": "p5", "version": "1.9.0", "fileId": "0x" + "88" * 32}
        with_dep = with_doc(base, lambda d: d["conservation"]["generative"]["dependencies"].append(dep))
        with_dep["package"]["item"]["recordDependencies"] = [{"name": "p5", "version": "1.9.0"}]  # [{name, version}]
        with_dep["observed"]["dependencies"] = {"p5@1.9.0": {"fileId": dep["fileId"], "deprecated": False}}
        self.assertEqual(run(with_dep)["facts"]["generative"]["state"], "met")
        cases = [
            ("is not Stream.defaultRenderer()", edit(base, lambda i: i["observed"].update(defaultRenderer="0x" + "12" * 20))),
            ("was not observed", edit(base, lambda i: i["observed"].pop("defaultRenderer"))),
            ("extcodehash", edit(base, lambda i: i["observed"].update(codeHash={}))),
            ("did not resolve", edit(with_dep, lambda i: i["observed"].update(dependencies={}))),
            ("or is deprecated", edit(with_dep, lambda i: i["observed"]["dependencies"]["p5@1.9.0"].update(deprecated=True))),
            ("resolves to another file", edit(with_dep, lambda i: i["observed"]["dependencies"]["p5@1.9.0"].update(fileId="0x" + "00" * 32))),
            ("not generative.dependencies, in order", edit(with_dep, lambda i: i["package"]["item"].update(recordDependencies=[]))),
            ("not generative.dependencies, in order", edit(with_dep, lambda i: i["package"]["item"].update(recordDependencies=[{"name": "p5", "version": "1.9.1"}]))),
            ("seedPolicy is not the item's", edit(base, lambda i: i["package"]["item"].update(seedPolicy="ARTIST"))),
        ]  # fmt: skip
        for needle, inp in cases:
            with self.subTest(needle):
                self.assert_refused(inp, "generative", needle)

    def test_what_makes_a_work_generative(self) -> None:
        """DCL-4/DCL-5 G: a script or HTML primary, a record declaring dependencies, or a seed
        policy other than NONE; then a missing generative fact is refused."""
        still = testdata.still_floor_input()
        for name, change in {
            "html primary": lambda i: i["package"]["files"][F1].update(mimeType="text/html"),
            "application/javascript primary": lambda i: i["package"]["files"][F1].update(mimeType="application/javascript"),
            "record declares dependencies": lambda i: i["package"]["item"].update(recordDependencies=[{"name": "p5", "version": "1.9.0"}]),
            "svg primary": lambda i: i["package"]["files"][F1].update(mimeType="image/svg+xml"),
            "text/ecmascript primary": lambda i: i["package"]["files"][F1].update(mimeType="text/ecmascript"),
            "application/ecmascript primary": lambda i: i["package"]["files"][F1].update(mimeType="application/ecmascript"),
            "seed policy ARTIST": lambda i: i["package"]["item"].update(seedPolicy="ARTIST"),
        }.items():  # fmt: skip
            with self.subTest(name):
                result = run(edit(still, change))
                self.assertIn("missing generative", result["refusals"])

    def test_empty_record_dependencies_declare_none(self) -> None:
        """DCL-4: "declares dependencies" means the member is present and non-empty."""
        for deps in ([], None):
            with self.subTest(deps=deps):
                result = run(edit(testdata.still_floor_input(), lambda i: i["package"]["item"].update(recordDependencies=deps)))
                self.assertTrue(result["ok"], result["refusals"])
                self.assertEqual(result["facts"]["generative"]["state"], "not_applicable")

    def test_display(self) -> None:
        """DCL-5 CHECK_display, and a waived display allowed by the policy."""
        waived = with_doc(testdata.still_floor_input(),
                          lambda d: d["conservation"].update(display={"waived": True, "reason": "Venue decides."}))
        self.assertEqual(run(waived)["refusals"], ["waiver not allowed: display"])
        waived["policy"]["waivable"] = ["display"]
        result = run(waived)
        self.assertTrue(result["ok"])
        self.assertEqual(result["facts"]["display"], {"state": "waived", "reasons": ["Venue decides."]})


class AlwaysTest(unittest.TestCase):
    """DCL-5 ALWAYS, applied whether or not facts are waived."""

    def test_refusals(self) -> None:
        base = testdata.still_floor_input()
        cases = [
            ("not a WorkPowers power", edit(base, lambda i: i["policy"].update(workPowers=["OTHER"]))),
            ("pairs are not distinct", with_doc(base, lambda d: d["custodians"].append(dict(d["custodians"][0], name="Again")))),
            ("a custodian address is zero", with_doc(base, lambda d: d["custodians"][0].update(address=testdata.ZERO))),
            ("names the work itself", edit(base, lambda i: i["package"].update(work={"chainId": 11155111, "contract": "0x02617dbdc0b0521124cb4c2a3ef602977e29bd91", "tokenId": "7"}))),
        ]  # fmt: skip
        for needle, inp in cases:
            with self.subTest(needle):
                result = run(inp)
                self.assertFalse(result["ok"])
                self.assertTrue(any(needle in r for r in result["refusals"]), result["refusals"])
                self.assertEqual(result["facts"]["storage"]["state"], "met")


    def test_work_powers_default_to_the_workpowers_names(self) -> None:
        """DCL-8: without an explicit list the names are ROYALTY_RATE and RELICENSE, in bit order."""
        self.assertEqual(floor.WORK_POWERS, ("ROYALTY_RATE", "RELICENSE"))
        for powers in (None, ["ROYALTY_RATE"]):
            with self.subTest(powers=powers):
                result = run(edit(testdata.still_floor_input(), lambda i: i["policy"].update(workPowers=powers)))
                self.assertTrue(result["ok"], result["refusals"])

    def test_custodian_may_hold_two_objects(self) -> None:
        """DCL-5 ALWAYS: distinct (address, objectId) pairs, so one custodian may hold two twins."""
        two = with_doc(testdata.still_floor_input(),
                       lambda d: d["custodians"].append(dict(d["custodians"][0], objectId="0x" + "01" * 32)))
        result = run(two)
        self.assertTrue(result["ok"], result["refusals"])

    def test_time_capsule_ciphertext_must_be_an_auxiliary_media_file(self) -> None:
        """DCL-7 and DCL-5 ALWAYS: the ciphertext file is one of the media, as AUXILIARY."""
        allowed = edit(testdata.time_capsule_floor_input(),
                       lambda i: i["policy"].update(allowsTimeCapsule=True, waivable=["storage"]))
        self.assertTrue(run(allowed)["ok"], run(allowed)["refusals"])
        needle = "ciphertext file is not an AUXILIARY media file"
        elsewhere = with_doc(allowed, lambda d: d["timeCapsule"].update(ciphertextFileId="0x" + "56" * 32))
        self.assertTrue(any(needle in r for r in run(elsewhere)["refusals"]))
        as_preview = edit(allowed, lambda i: i["package"]["media"][1].update(role="PREVIEW"))
        self.assertTrue(any(needle in r for r in run(as_preview)["refusals"]))


class HelpersTest(unittest.TestCase):
    def test_locator_network_is_ws18(self) -> None:
        """DCL-5 CHECK_storage: the receipt URI passes WorkRecords' locator shape (WS-18)."""
        good = {"ar://oPSkhDkQRE6xQF7RQgVgRkmoJKW7XueRtNdpwXEEnRc": "arweave",
                "ipfs://bafkreiaith34c3xuzolsbkq6nwopkreb4fthxkcw3vni7wlc3qf7vqou3i": "ipfs"}
        for uri, network in good.items():
            self.assertEqual(locator_network(uri), network)
        for uri in ("ar://oPSkhDkQRE6xQF7RQgVgRkmoJKW7XueRtNdpwXEEnRd", "ar://short",
                    "ipfs://QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG", "https://x", 7):
            self.assertIsNone(locator_network(uri))

    def test_license_key_matches_works_hashing(self) -> None:
        self.assertEqual(floor.license_key("CC0-1.0"), floor.license_key("cc0-1.0"))
        self.assertNotEqual(floor.license_key("CC0-1.0"), floor.license_key("CC-BY-4.0"))

    def test_dependency_label_is_the_registry_bytes32(self) -> None:
        """DCL-5 `label`: ASCII left-aligned, zero-padded; only the registry's spelling."""
        self.assertEqual(floor.dependency_label("p5.js"), "0x" + b"p5.js".hex() + "00" * 27)
        self.assertEqual(floor.dependency_label("a" * 32), "0x" + "61" * 32)
        for bad in ("", "P5", "a" * 33, "p5 js", 5):
            with self.subTest(bad=bad), self.assertRaises(floor.ToolError):
                floor.dependency_label(bad)

    def test_floor_result_is_the_published_document(self) -> None:
        """DCL-33: a passing check becomes a valid floor-result.v1 naming the item and file."""
        result = run(testdata.still_floor_input())
        doc = floor.floor_result(result, "0x" + "AB" * 32)
        self.assertEqual(doc, {"v": 1, "itemHash": "0x" + "ab" * 32, "declarationsFileId": DECL_FILE,
                               "facts": floor_states(result)})  # fmt: skip
        self.assertEqual(testdata.schema.validate(doc, "floor-result"), [])

    def test_floor_states_refuses_a_refused_check(self) -> None:
        with self.assertRaises(floor.ToolError):
            floor_states({"ok": False, "refusals": ["x"], "facts": {}})

    def test_constants(self) -> None:
        self.assertEqual(DECLARATIONS_MIME, "application/vnd.6529-works.declarations+json")
        self.assertEqual(floor.MAX_DECLARATIONS_BYTES, 24_575)
        self.assertEqual(hashlib.sha256(b"").hexdigest()[:4], "e3b0")


if __name__ == "__main__":
    unittest.main()
