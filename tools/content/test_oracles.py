"""The oracle fixtures are current, and the oracles answer known cases.

`test/content/renderer/RendererOracles.t.sol` checks the contracts against the committed fixtures;
this keeps the fixtures equal to what `oracles.py` generates, so a change to either shows up.
"""

from __future__ import annotations

import unittest

from tools.content import oracles


class OracleFixturesTest(unittest.TestCase):
    def test_fixtures_are_current(self) -> None:
        for name in oracles.NAMES:
            with self.subTest(name=name):
                path = oracles.FIXTURES / f"{name}.json"
                self.assertTrue(path.exists(), f"missing {path}: run --write")
                self.assertEqual(
                    path.read_text(encoding="utf-8"),
                    oracles.render(name),
                    f"stale {path}: run python -m tools.content.oracles --write",
                )

    def test_trait_rule_known_answers(self) -> None:
        for name in ["Palette", "Year 2", "", "A'B 100% #1", "Artists", "a b c"]:
            self.assertTrue(oracles.trait_accepted(name), name)
        for name in [
            "Seed", "SEED", " seed", "seed ", "Artist ID", "ArtistID", "artist id", "Edition Of",
            "Dispute  statement", "d i s p u t e s t a t e m e n t", "Color  palette",
            "Artist ID", "Collection​", "Disputе statement", "Café",
            "Seed\u007f", "A" + oracles.BS + "u0041",
        ]:
            self.assertFalse(oracles.trait_accepted(name), name)

    def test_tokenizer_closes_at_the_first_script_end_tag(self) -> None:
        self.assertEqual(oracles.close_position(b"a</script>"), 1)
        self.assertEqual(oracles.close_position(b"a</SCRIPT x>"), 1)
        self.assertIsNone(oracles.close_position(b"a</scripts>"))
        # `<!--<script>` enters the double-escaped state: the first `</script>` does not close.
        self.assertEqual(oracles.close_position(b"<!--<script></script></script>"), 21)
        # The neutralized form closes at the renderer's own tag.
        safe = oracles.neutralize(b"<!--<script></script>")
        self.assertEqual(oracles.close_position(safe + oracles.SHELL_TAIL), len(safe))


if __name__ == "__main__":
    unittest.main()
