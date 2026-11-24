"""Format-argument checking for the string catalogs: positions, types and widths.

The parser keeps signedness and integer widths, checks dynamic width/precision
arguments, and rejects mixed numbering.
Plural forms use the source string's argument positions, never a new local queue.
"""
from dataclasses import dataclass
import re


class CatalogError(ValueError):
    pass


LOCALES = ("en", "cs", "de", "es", "fr", "it", "hu", "nl", "pl", "pt-BR",
           "sv", "th", "tr", "ru", "uk", "ja", "ko", "zh-Hans", "zh-Hant")
CATEGORIES = {"zero", "one", "two", "few", "many", "other"}
# CLDR cardinal categories, including fractional/million categories. Extra valid
# categories are retained. https://www.unicode.org/cldr/charts/49/supplemental/language_plural_rules.html
REQUIRED = {locale: {"one", "other"} for locale in LOCALES}
for _locale in ("cs", "pl", "ru", "uk"):
    REQUIRED[_locale] = {"one", "few", "many", "other"}
for _locale in ("es", "fr", "it", "pt-BR"):
    REQUIRED[_locale] = {"one", "many", "other"}
for _locale in ("ja", "ko", "th", "zh-Hans", "zh-Hant"):
    REQUIRED[_locale] = {"other"}

STRING_UNIT = "stringUnit"
TRANSLATED = "translated"
FORMAT_KEY = "NSStringLocalizedFormatKey"
SPEC_TYPE_KEY = "NSStringFormatSpecTypeKey"
VALUE_TYPE_KEY = "NSStringFormatValueTypeKey"
PLURAL_RULE_TYPE = "NSStringPluralRuleType"
DYNAMIC_ARGUMENT = ("signed", "32")  # a * width or precision argument

# re.ASCII keeps \d and \w to exactly [0-9] and [A-Za-z0-9_]. Flags may contain
# '0', so a width starts with [1-9]: each '0' after '%' can only be a flag. The
# split is the one the former [-+ #0']*[0-9]+ produced, without the overlap.
CONVERSION = re.compile(
    r"%(?:(?P<position>[1-9]\d*)\$)?(?P<flags>[-+ #0']*)"
    r"(?P<width>[1-9]\d*|\*(?:(?P<width_position>[1-9]\d*)\$)?)?"
    r"(?P<precision>\.(?:\d*|\*(?:(?P<precision_position>[1-9]\d*)\$)?))?"
    r"(?P<length>hh|ll|h|l|q|z|t|j|L)?(?P<conversion>[@dDiuUxXoOfFeEgGcCsSpaA])", re.ASCII)
TOKEN = re.compile(r"%(?:(?P<position>[1-9]\d*)\$)?#@(?P<name>[A-Za-z_]\w*)@", re.ASCII)
VALUE_TYPE = re.compile(r"(?:hh|ll|h|l|q|z|t|j|L)?[dDiuUxXoOfFeEgGaA]\Z")
# Something that looks like a conversion but is not a supported one. This accepts
# the same strings as %(?:[0-9]+\$|#@|\*|[-+ #0']*[0-9]*(?:\.[0-9]*)?[A-Za-z]):
# after the flags (which include '0') any digits start with [1-9], so the flag
# and digit runs never compete and matching is linear.
MALFORMED = re.compile(r"%(?:\d+\$|#@|\*|[-+ #0']*(?:[1-9]\d*)?(?:\.\d*)?[A-Za-z])", re.ASCII)
IDENTIFIER = re.compile(r"[A-Za-z_]\w*", re.ASCII)

INTEGER_CONVERSIONS = "diuoxXDOU"
FLOAT_CONVERSIONS = "fFeEgGaA"
CHARACTER_CONVERSIONS = "cCsS"
INTEGER_LENGTHS = ("", "hh", "h", "l", "ll", "q", "z", "t", "j")
WIDE_INTEGER_LENGTHS = ("l", "ll", "q", "z", "t", "j")
NARROW_INTEGER_WIDTHS = {"hh": "8", "h": "16"}


def text(value, place):
    if not isinstance(value, str):
        raise CatalogError(f"{place}: expected a string")
    if any(ord(ch) < 32 and ch not in "\t\r\n" or 0xD800 <= ord(ch) <= 0xDFFF for ch in value):
        raise CatalogError(f"{place}: unsupported control character or invalid Unicode")
    return value


def fields(value, allowed, place, required=()):
    if not isinstance(value, dict):
        raise CatalogError(f"{place}: expected an object")
    unknown = set(value) - set(allowed)
    missing = set(required) - set(value)
    if unknown or missing:
        raise CatalogError(f"{place}: unexpected fields {sorted(unknown)}, missing fields {sorted(missing)}")
    return value


def _integer_type(length, conversion):
    if length not in INTEGER_LENGTHS:
        raise CatalogError(f"unsupported integer format %{length}{conversion}")
    if conversion in "DOU" and length:
        raise CatalogError(f"ambiguous integer format %{length}{conversion}")
    # NSString's uppercase D/O/U remain 32-bit (unlike historical BSD
    # printf aliases). Only explicit long/size modifiers widen them here.
    width = "64" if length in WIDE_INTEGER_LENGTHS else NARROW_INTEGER_WIDTHS.get(length, "32")
    return ("signed" if conversion in "diD" else "unsigned", width)


def _float_type(length, conversion):
    if length not in ("", "l", "L"):
        raise CatalogError(f"unsupported floating format %{length}{conversion}")
    return ("float", "long-double" if length == "L" else "64")


def _character_type(length, conversion):
    if length:
        raise CatalogError(f"unsupported character format %{length}{conversion}")
    return ("character" if conversion in "cC" else "cstring", "16" if conversion in "CS" else "8")


def _other_type(length, conversion):
    if length:
        raise CatalogError(f"unsupported length modifier %{length}{conversion}")
    return ("object", "") if conversion == "@" else ("pointer", "64")


def argument_type(length, conversion):
    length = length or ""
    if conversion in INTEGER_CONVERSIONS:
        return _integer_type(length, conversion)
    if conversion in FLOAT_CONVERSIONS:
        return _float_type(length, conversion)
    if conversion in CHARACTER_CONVERSIONS:
        return _character_type(length, conversion)
    return _other_type(length, conversion)


@dataclass
class ParsedFormat:
    arguments: dict
    # Ordinary conversions and plural selectors, with their original positions.
    tokens: list
    positional: str
    explicit: bool


class _FormatParser:
    """One left-to-right pass over a format; each step consumes one piece."""

    def __init__(self, value, variables):
        self.value = value
        self.variables = variables
        self.arguments, self.tokens, self.output = {}, [], []
        self.modes = set()
        self.next_position = 1

    def add(self, raw_position, kind):
        if raw_position:
            position = int(raw_position)
            self.modes.add("explicit")
        else:
            position = self.next_position
            self.next_position += 1
            self.modes.add("implicit")
        if position > 1024:
            raise CatalogError("format argument position exceeds 1024")
        if position in self.arguments and self.arguments[position] != kind:
            raise CatalogError(f"argument {position} has conflicting format types")
        self.arguments[position] = kind
        return position

    def step(self, cursor):
        """Consume the piece at cursor and return the next cursor."""
        value = self.value
        if value[cursor] != "%":
            self.output.append(value[cursor])
            return cursor + 1
        if value.startswith("%%", cursor):
            self.output.append("%%")
            return cursor + 2
        selector = TOKEN.match(value, cursor)
        if selector:
            return self.selector(selector)
        match = CONVERSION.match(value, cursor)
        if match:
            return self.conversion(match)
        if MALFORMED.match(value, cursor):
            raise CatalogError(f"unsupported or malformed format near {value[cursor:cursor + 24]!r}")
        self.output.append("%")
        return cursor + 1

    def selector(self, selector):
        name = selector["name"]
        if name not in self.variables:
            raise CatalogError(f"plural token {name!r} has no variable")
        kind = value_type(self.variables[name])
        position = self.add(selector["position"], kind)
        self.tokens.append((position, kind, self.variables[name], name))
        self.output.append(f"%{position}$#@{name}@")
        return selector.end()

    def conversion(self, match):
        width, precision = match["width"] or "", match["precision"] or ""
        if width.startswith("*"):
            width = f"*{self.add(match['width_position'], DYNAMIC_ARGUMENT)}$"
        if precision.startswith(".*"):
            precision = f".*{self.add(match['precision_position'], DYNAMIC_ARGUMENT)}$"
        length, conversion = match["length"] or "", match["conversion"]
        kind = argument_type(length, conversion)
        position = self.add(match["position"], kind)
        self.tokens.append((position, kind, length + conversion, None))
        self.output.append(f"%{position}${match['flags']}{width}{precision}{length}{conversion}")
        return match.end()


def parse_format(value, variables=None):
    """Parse printf/Foundation arguments and produce a fully numbered equivalent.

    A bare literal percent is allowed; conversions introduced by a translation
    still enter its signature. Malformed numbered/plural/star/%n syntax is refused.
    """
    value = text(value, "format")
    parser = _FormatParser(value, variables or {})
    cursor = 0
    while cursor < len(value):
        cursor = parser.step(cursor)
    if len(parser.modes) > 1:
        raise CatalogError("do not mix positional and unnumbered format arguments")
    return ParsedFormat(parser.arguments, parser.tokens, "".join(parser.output), parser.modes == {"explicit"})


def value_type(value):
    if not isinstance(value, str) or not VALUE_TYPE.fullmatch(value):
        raise CatalogError(f"invalid numeric plural type {value!r}")
    match = CONVERSION.fullmatch("%" + value)
    return argument_type(match["length"], match["conversion"])


def specifiers(value):
    return sorted((position, *kind) for position, kind in parse_format(value).arguments.items())


def check_format(value, source, place, optional=()):
    actual, expected = parse_format(value), parse_format(source)
    if any(expected.arguments.get(p) != kind for p, kind in actual.arguments.items()) or set(expected.arguments) - set(actual.arguments) - set(optional):
        raise CatalogError(f"{place}: format arguments {actual.arguments} do not match source {expected.arguments}")
    return actual


def string_unit(unit, place):
    fields(unit, {"state", "value"}, place, {"state", "value"})
    if unit["state"] not in ("new", "needs_review", TRANSLATED):
        raise CatalogError(f"{place}: unknown string state {unit['state']!r}")
    return text(unit["value"], place)


def forms_object(forms, place):
    if not isinstance(forms, dict) or not forms or set(forms) - CATEGORIES or "other" not in forms:
        raise CatalogError(f"{place}: plural forms need 'other' and only valid CLDR categories")
    return forms


def plural_rule(value_type_specifier):
    """The start of one stringsdict plural variable; forms are added by category."""
    return {SPEC_TYPE_KEY: PLURAL_RULE_TYPE, VALUE_TYPE_KEY: value_type_specifier}


def _changes_arguments(arguments, expected):
    return any(expected.get(position) != kind for position, kind in arguments.items())


def _variable_types(variables, place):
    if not isinstance(variables, dict) or not variables:
        raise CatalogError(f"{place}: variables must be a nonempty object")
    types = {}
    for name, variable in variables.items():
        if not IDENTIFIER.fullmatch(name) or name == FORMAT_KEY:
            raise CatalogError(f"{place}: invalid variable name {name!r}")
        fields(variable, {"type", "forms"}, f"{place}.{name}", {"type", "forms"})
        value_type(variable["type"])
        types[name] = variable["type"]
    return types


def _outer_format(outer_format, types, expected, place):
    outer = parse_format(outer_format, types)
    positions = {}
    for position, kind, _, name in outer.tokens:
        if name:
            if name in positions and positions[name] != position:
                raise CatalogError(f"{place}: variable {name} has two argument positions")
            positions[name] = position
        if expected.get(position) != kind:
            raise CatalogError(f"{place}: outer format changes argument {position}'s type/width")
    if set(positions) != set(types):
        raise CatalogError(f"{place}: unused plural variable")
    if _changes_arguments(outer.arguments, expected):
        raise CatalogError(f"{place}: outer format changes width/precision arguments")
    return outer


def _plural_form(form, expected, place):
    parsed = parse_format(text(form, place))
    if not form.strip():
        raise CatalogError(f"{place}: empty plural form")
    if parsed.arguments and len(expected) > 1 and not parsed.explicit:
        raise CatalogError(f"{place}: use original positional arguments in a multi-argument plural")
    if _changes_arguments(parsed.arguments, expected):
        raise CatalogError(f"{place}: form changes argument positions/type/width")
    return parsed


def _plural_variable(variable, expected, locale, place):
    """Return (stringsdict item, complete, arguments present in every form)."""
    forms = forms_object(variable["forms"], place)
    complete = REQUIRED[locale].issubset(forms)
    item = plural_rule(variable["type"])
    always = set(expected)
    for category, form in forms.items():
        parsed = _plural_form(form, expected, f"{place}.{category}")
        # A variable may refer to other source arguments, but only its own
        # numeric selector may be absent from all forms.
        always.intersection_update(parsed.arguments)
        item[category] = parsed.positional
    return item, complete, always


def external_plural(source, spec, locale, place):
    """Return (stringsdict entry, complete). Per-locale JSON schema:

    {"%lld commits": {"format": "%1$#@count@", "variables": {
        "count": {"type": "lld", "forms": {
            "one": "%1$lld commit", "other": "%1$lld commits"}}}}}

    Forms may omit their selector's count. With multiple source arguments, use
    explicit original positions in forms. Non-count arguments must occur in the
    outer format or in every possible expansion. There is no executable content.
    """
    fields(spec, {"format", "variables"}, place, {"format", "variables"})
    variables = spec["variables"]
    types = _variable_types(variables, place)
    expected = parse_format(source).arguments
    outer = _outer_format(spec["format"], types, expected, place)
    covered = set(outer.arguments)
    result = {FORMAT_KEY: outer.positional}
    complete = True
    for name, variable in variables.items():
        item, variable_complete, always = _plural_variable(variable, expected, locale, f"{place}.{name}")
        complete = complete and variable_complete
        covered.update(always)
        result[name] = item
    if set(expected) != covered:
        raise CatalogError(f"{place}: some plural expansions omit non-count arguments {sorted(set(expected) - covered)}")
    return result, complete


def catalog_localization(source, localization, locale, place):
    """Compile flat units or one unambiguous numeric catalog plural.

    Device/width/nested/substitution variants are rejected explicitly rather than
    flattened. Use the typed external schema for multiple plural selectors.
    """
    fields(localization, {STRING_UNIT, "variations"}, place)
    if set(localization) == {STRING_UNIT}:
        value = string_unit(localization[STRING_UNIT], place)
        check_format(value, source, place)
        if source and not value.strip():
            raise CatalogError(f"{place}: empty translation")
        return value, None, locale == "en" or localization[STRING_UNIT]["state"] == TRANSLATED
    if set(localization) != {"variations"}:
        raise CatalogError(f"{place}: expected exactly one stringUnit or variations object")
    variations = fields(localization["variations"], {"plural"}, place, {"plural"})
    forms = forms_object(variations["plural"], place)
    parsed_source = parse_format(source)
    counts = {position: (kind, spec) for position, kind, spec, _ in parsed_source.tokens if kind[0] in ("signed", "unsigned", "float")}
    if len(counts) != 1:
        raise CatalogError(f"{place}: catalog plural needs exactly one numeric argument; use typed Plurals JSON")
    position, (_, specifier) = next(iter(counts.items()))
    item = plural_rule(specifier)
    complete = REQUIRED[locale].issubset(forms)
    for category, form in forms.items():
        fields(form, {STRING_UNIT}, f"{place}.{category}", {STRING_UNIT})
        value = string_unit(form[STRING_UNIT], f"{place}.{category}")
        if not value.strip():
            raise CatalogError(f"{place}.{category}: empty plural form")
        parsed = check_format(value, source, f"{place}.{category}", optional={position})
        item[category] = parsed.positional
        complete = complete and (locale == "en" or form[STRING_UNIT]["state"] == TRANSLATED)
    return None, {FORMAT_KEY: f"%{position}$#@count@", "count": item}, complete
