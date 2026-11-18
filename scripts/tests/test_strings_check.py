"""Format parsing and plural checks in scripts/strings_check.py."""
import sys
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import strings_check  # noqa: E402
from strings_check import CatalogError, MALFORMED, parse_format  # noqa: E402

# What the former, backtracking pattern accepted and rejected; the linear rewrite must agree on every one.
FORMER_MATCHES = ['%05.2k', '%12$', '%1$', '%#@', '%*', '%0000k', "%-+ #0'9.9n", '%.k', '%9n', '% k', "%'k"]
FORMER_REJECTS = ['%', '%0', '%00', '%-0', '%0-5', '%05', '%05.2', '%9', '%٣n', '%１$', '%0.٣k']
COMMITS = "%lld commits"
COUNT_FORMAT = "%1$#@count@"


class RegexTests(unittest.TestCase):
    def test_malformed_matches_the_former_pattern(self):
        for sample in FORMER_MATCHES:
            with self.subTest(sample=sample):
                self.assertIsNotNone(MALFORMED.match(sample))
        for sample in FORMER_REJECTS:
            with self.subTest(sample=sample):
                self.assertIsNone(MALFORMED.match(sample))

    def test_malformed_is_linear_on_long_flag_runs(self):
        adversary = "%" + "0" * 50000 + "."
        started = time.perf_counter()
        self.assertIsNone(MALFORMED.match(adversary))
        self.assertLess(time.perf_counter() - started, 0.5)

    def test_digits_and_names_stay_ascii(self):
        self.assertIsNone(strings_check.TOKEN.match("%١$#@count@"))
        self.assertIsNone(strings_check.TOKEN.match("%#@coént@"))
        self.assertIsNone(strings_check.IDENTIFIER.fullmatch("n٣"))
        self.assertIsNone(strings_check.CONVERSION.match("%١d"))

    def test_zero_after_percent_is_a_flag(self):
        match = strings_check.CONVERSION.match("%-005.2lld")
        self.assertEqual((match["flags"], match["width"], match["precision"]), ("-00", "5", ".2"))
        match = strings_check.CONVERSION.match("%00d")
        self.assertEqual((match["flags"], match["width"]), ("00", None))


class ParseFormatTests(unittest.TestCase):
    def test_numbers_implicit_arguments(self):
        parsed = parse_format("%@ has %*.*lld%% %")
        self.assertEqual(parsed.positional, "%1$@ has %4$*2$.*3$lld%% %")
        self.assertEqual(parsed.arguments, {1: ("object", ""), 2: ("signed", "32"), 3: ("signed", "32"), 4: ("signed", "64")})
        self.assertFalse(parsed.explicit)

    def test_selector_uses_variable_type(self):
        parsed = parse_format(COUNT_FORMAT, {"count": "lld"})
        self.assertEqual(parsed.tokens, [(1, ("signed", "64"), "lld", "count")])
        self.assertTrue(parsed.explicit)

    def test_rejections(self):
        for value, message in [("%1$@ %@", "do not mix"), ("%k", "malformed"), ("%1025$@", "exceeds 1024"),
                               ("%1$@ %1$d", "conflicting"), ("%#@n@", "has no variable"), ("%hhs", "character"),
                               ("%lD", "ambiguous"), ("%hf", "floating"), ("%Lp", "length modifier"), ("%Ld", "integer")]:
            with self.subTest(value=value), self.assertRaisesRegex(CatalogError, message):
                parse_format(value)

    def test_argument_types(self):
        cases = {("", "D"): ("signed", "32"), ("hh", "u"): ("unsigned", "8"), ("h", "x"): ("unsigned", "16"),
                 ("q", "d"): ("signed", "64"), ("L", "f"): ("float", "long-double"), ("", "C"): ("character", "16"),
                 ("", "s"): ("cstring", "8"), ("", "@"): ("object", ""), (None, "p"): ("pointer", "64")}
        for (length, conversion), kind in cases.items():
            with self.subTest(length=length, conversion=conversion):
                self.assertEqual(strings_check.argument_type(length, conversion), kind)


class PluralTests(unittest.TestCase):
    def spec(self, forms, outer=COUNT_FORMAT):
        return {"format": outer, "variables": {"count": {"type": "lld", "forms": forms}}}

    def test_external_plural(self):
        entry, complete = strings_check.external_plural(
            COMMITS, self.spec({"one": "%lld commit", "other": COMMITS}), "en", "P")
        self.assertTrue(complete)
        self.assertEqual(entry, {strings_check.FORMAT_KEY: COUNT_FORMAT, "count": {
            strings_check.SPEC_TYPE_KEY: strings_check.PLURAL_RULE_TYPE, strings_check.VALUE_TYPE_KEY: "lld",
            "one": "%1$lld commit", "other": "%1$lld commits"}})
        _, complete = strings_check.external_plural(COMMITS, self.spec({"other": COMMITS}), "pl", "P")
        self.assertFalse(complete)

    def test_external_plural_rejections(self):
        source = "%1$lld of %2$@"
        cases = [(self.spec({"other": ""}), "empty plural form"),
                 (self.spec({"other": "%lld %@"}), "original positional"),
                 (self.spec({"other": "%1$d"}), "form changes"),
                 (self.spec({"other": "%1$lld"}), "omit non-count"),
                 (self.spec({"other": "x"}, "%1$#@count@ %1$#@count@ %3$@"), "outer format changes argument 3"),
                 ({"format": COUNT_FORMAT, "variables": {}}, "nonempty"),
                 ({"format": COUNT_FORMAT, "variables": {"1x": {"type": "d", "forms": {}}}}, "invalid variable name"),
                 ({"format": "%2$@", "variables": {"count": {"type": "lld", "forms": {"other": "x"}}}}, "unused")]
        for spec, message in cases:
            with self.subTest(message=message), self.assertRaisesRegex(CatalogError, message):
                strings_check.external_plural(source, spec, "en", "P")

    def test_catalog_plural(self):
        localization = {"variations": {"plural": {
            "one": {"stringUnit": {"state": "translated", "value": "one commit"}},
            "other": {"stringUnit": {"state": "new", "value": COMMITS}}}}}
        flat, plural, complete = strings_check.catalog_localization(COMMITS, localization, "de", "C")
        self.assertIsNone(flat)
        self.assertFalse(complete)
        self.assertEqual(plural[strings_check.FORMAT_KEY], COUNT_FORMAT)
        self.assertEqual(plural["count"]["one"], "one commit")


if __name__ == "__main__":
    unittest.main()
