#!/usr/bin/env python3
"""Retrieve selected HC records or validate the portable skill package.

Requires Python 3.9+ and PyYAML. No network access or file writes.
"""

import argparse
import hashlib
import re
import subprocess
from pathlib import Path

try:
    import yaml
except ImportError as exc:
    raise SystemExit("PyYAML is required for this helper; direct YAML reading also works.") from exc


LABELS = {
    "factual", "explanatory", "diagnostic", "causal", "prediction", "decision",
    "design", "optimization", "research", "strategy", "negotiation",
    "complex_system", "quantitative", "communication", "ethical",
}


class UniqueLoader(yaml.SafeLoader):
    """Reject duplicate mapping keys instead of silently replacing records."""


def unique_mapping(loader, node):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node)
        if key in result:
            raise ValueError(f"Duplicate YAML key: {key}")
        result[key] = loader.construct_object(value_node)
    return result


UniqueLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping
)


def read_yaml(path):
    with path.open(encoding="utf-8") as stream:
        return yaml.load(stream, Loader=UniqueLoader)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def flatten(registry):
    operators = {}
    for group, records in registry["groups"].items():
        for name, record in records.items():
            require(name not in operators, f"Operator repeated across groups: {name}")
            operators[name] = {"category": group, **record}
    return operators


def validate(root, registry, operators):
    examples_doc = read_yaml(root / "hc_examples.yaml")
    require(registry["schema_version"] == 1, "Unsupported registry version")
    require(examples_doc["schema_version"] == 1, "Unsupported examples version")
    require(registry["baseline"] in registry["sources"], "Unknown baseline")
    sources = registry["sources"]
    objectives = registry["source_objectives"]
    examples = examples_doc["examples"]
    for name, source in sources.items():
        require(source["url"].startswith("https://"), f"Invalid source URL: {name}")
        require(re.fullmatch(r"[0-9a-f]{64}", source["sha256"]), f"Invalid digest: {name}")
        require(source["document"] and source["version"], f"Missing source identity: {name}")
    for name, objective in objectives.items():
        require(objective["document"] in sources, f"Unknown objective source: {name}")
        require(objective["location"] and objective["summary"], f"Incomplete objective: {name}")
    official_names = set()
    aliases = set()
    fields = {
        "implementation_name", "official_name", "type", "runtime_role",
        "competency", "aliases", "purpose", "use_when", "triggers",
        "avoid_when", "questions", "operation", "expected_output",
        "anti_patterns", "related_hcs", "example_refs",
    }
    for name, record in operators.items():
        require(fields <= record.keys(), f"Missing fields: {name}")
        require(re.fullmatch(r"[a-z][a-z0-9_]*", name), f"Invalid identifier: {name}")
        require(record["implementation_name"] == name, f"Mismatched identifier: {name}")
        require(record["type"] in {"habit", "concept", "derived"}, f"Invalid type: {name}")
        require(record["runtime_role"] in {"check", "tool"}, f"Invalid runtime role: {name}")
        require(record["competency"] in {
            "thinking_critically", "thinking_creatively", "communicating_effectively",
            "interacting_effectively",
        }, f"Unknown competency: {name}")
        require(set(record["use_when"]) <= LABELS, f"Unknown routing label: {name}")
        for field in ["use_when", "triggers", "avoid_when", "questions", "operation",
                      "expected_output", "anti_patterns"]:
            values = record[field]
            require(isinstance(values, list) and values, f"Empty operation field: {name}.{field}")
            require(all(isinstance(x, str) and x.strip() for x in values), f"Invalid values: {name}.{field}")
        require(len(record["operation"]) >= 2, f"No concrete operation: {name}")
        if record["type"] == "derived":
            require(record["official_name"] is None, f"Derived operator claims an official name: {name}")
            require("source" not in record, f"Derived operator needs explicit derivation: {name}")
            require(record.get("derived_from"), f"Missing derivation: {name}")
            require(set(record["derived_from"]) <= objectives.keys(), f"Broken derivation: {name}")
            require("supporting_objectives" not in record,
                    f"Use derived_from for derived operator: {name}")
        else:
            tag = record["official_name"]
            require(isinstance(tag, str) and re.fullmatch(r"#[a-z]+", tag), f"Invalid official label: {name}")
            require(tag not in official_names, f"Repeated official label: {tag}")
            official_names.add(tag)
            require(record["source"]["document"] in sources, f"Unknown HC source: {name}")
            require(re.fullmatch(r"p\. \d+", record["source"]["location"]), f"Missing page: {name}")
            require("derived_from" not in record, f"Ambiguous official classification: {name}")
            if "supporting_objectives" in record:
                require(record["supporting_objectives"], f"Empty supporting objectives: {name}")
                require(set(record["supporting_objectives"]) <= objectives.keys(),
                        f"Broken supporting objective: {name}")
        if "derivation_note" in record:
            require(isinstance(record["derivation_note"], str) and record["derivation_note"].strip(),
                    f"Empty derivation note: {name}")
        for alias in record["aliases"]:
            require(alias not in aliases and alias not in operators, f"Ambiguous alias: {alias}")
            require(not alias.startswith("#"), f"Unverified official alias: {alias}")
            aliases.add(alias)
        require(set(record["related_hcs"]) <= operators.keys(), f"Broken related HC: {name}")
        require(name not in record["related_hcs"], f"Self-reference: {name}")
        require(set(record["example_refs"]) <= examples.keys(), f"Broken example: {name}")
        for example in record["example_refs"]:
            require("bad_answer" not in examples[example], f"Positive reference targets bad example: {name}")
            require(name in examples[example]["selected"], f"Example selection omits {name}: {example}")
    for name, example in examples.items():
        require(set(example["classifications"]) <= LABELS, f"Unknown example class: {name}")
        require(set(example["selected"]) <= operators.keys(), f"Unknown example operator: {name}")
        require(example["context"] and example["prompt"], f"Incomplete example: {name}")
        if "bad_answer" in example:
            require(example["failure"] and example["repair"], f"Unexplained bad example: {name}")
            require(example["related_example"] in examples, f"Missing repaired example: {name}")
        else:
            require(example["artifacts"] and example["answer"] and example["would_change_if"],
                    f"Missing analytical output: {name}")
            for operator in example["selected"]:
                require(name in operators[operator]["example_refs"],
                        f"Missing example back-reference: {operator}/{name}")
    entry = (root / "SKILL.md").read_text(encoding="utf-8")
    match = re.match(r"---\n(.*?)\n---", entry, re.DOTALL)
    require(match is not None, "Missing skill frontmatter")
    metadata = yaml.load(match[1], Loader=UniqueLoader)
    require(metadata["name"] == root.name, "Skill name does not match directory")
    require(metadata["description"], "Missing activation description")
    routes = re.findall(r"^\|\s*([a-z_]+)\s*\|([^|]+)\|$", entry, re.MULTILINE)
    require(len(routes) == len(LABELS) and {label for label, _ in routes} == LABELS,
            "Router must cover each problem label once")
    for label, candidates in routes:
        for name in re.findall(r"`([a-z][a-z0-9_]*)`", candidates):
            require(name in operators, f"Unknown router operator: {name}")
            require(label in operators[name]["use_when"], f"Router/use_when mismatch: {label}/{name}")
    routing = re.search(r"## 2\..*?(?=## 4\.)", entry, re.DOTALL)
    require(routing, "Missing routing and selection sections")
    routing_text = re.sub(r"```.*?```", "", routing[0], flags=re.DOTALL)
    known_cues = operators.keys() | registry["groups"].keys() | {"python", "list"}
    for cue in re.findall(r"`([a-z][a-z0-9_]*)`", routing_text):
        require(cue in known_cues, f"Unknown routing or selection cue: {cue}")
    for target in re.findall(r"\]\(([^)]+)\)", entry):
        if not target.startswith("https://"):
            require((root / target.split("#")[0]).exists(), f"Broken skill link: {target}")
    official = sum(record["type"] != "derived" for record in operators.values())
    print(f"PASS: {official} official HCs, {len(operators) - official} derived operators, "
          f"{len(examples)} examples; schema, provenance, aliases, and links valid.")


def source_page(pages_by_source, document, page, owner):
    pages = pages_by_source[document]
    require(1 <= page <= len(pages) and pages[page - 1].strip(),
            f"Source page outside document: {owner} (p. {page})")
    return pages[page - 1]


def verify_sources(source_dir, registry, operators):
    pages_by_source = {}
    for document, source in registry["sources"].items():
        path = source_dir / {"intro2017": "intro.pdf", "dlo2017": "achievement.pdf"}[document]
        require(hashlib.sha256(path.read_bytes()).hexdigest() == source["sha256"],
                f"Source changed: {document}; review before updating the snapshot")
        text = subprocess.check_output(
            ["pdftotext", "-enc", "UTF-8", "-layout", str(path), "-"], encoding="utf-8"
        )
        pages_by_source[document] = text.rstrip("\f\n").split("\f")
    for name, record in operators.items():
        if record["type"] == "derived":
            continue
        source = record["source"]
        page = int(source["location"].split()[-1])
        content = source_page(pages_by_source, source["document"], page, name)
        tag = record["official_name"]
        tail = content.split(tag, 1)
        require(len(tail) == 2, f"Official label absent on stated page: {name}")
        kind = "H" if record["type"] == "habit" else "C"
        first_kind = re.search(r"\(([HC])\)", tail[1])
        require(first_kind and first_kind[1] == kind, f"Wrong official H/C type: {name}")
    for name, objective in registry["source_objectives"].items():
        match = re.fullmatch(r"p\. (\d+), (.*), bullets (\d+)(?:-(\d+))?", objective["location"])
        require(match, f"Invalid source location: {name}")
        page, section, first, last = match.groups()
        content = source_page(pages_by_source, objective["document"], int(page), name)
        require(section in content, f"Section absent on stated page: {name}")
        tail = content.split(section, 1)[1]
        # Count only the contiguous bullet block; wrapped lines are indented.
        block = re.split(r"\n\n\s*[A-Z]", tail, maxsplit=1)[0]
        count = len(re.findall(r"^\s*[\u2022]\s", block, re.MULTILINE))
        require(1 <= int(first) <= int(last or first) <= count,
                f"Objective bullet range outside section: {name} ({count} bullets)")
    print("PASS: source digests, all official labels and H/C types, and objective locations verified.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["list", "show", "check"])
    parser.add_argument("names", nargs="*")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--source-dir", type=Path, help="check local intro.pdf and achievement.pdf with Poppler")
    args = parser.parse_args()
    args.root = args.root.resolve()
    registry = read_yaml(args.root / "hc_registry.yaml")
    operators = flatten(registry)
    if args.command == "list":
        for group, records in registry["groups"].items():
            print(f"{group}: " + ", ".join(records))
    elif args.command == "show":
        if not args.names:
            parser.error("show requires one or more implementation names")
        lookup = {name: name for name in operators}
        for name, record in operators.items():
            for alias in record["aliases"]:
                require(alias not in lookup, f"Ambiguous alias: {alias}")
                lookup[alias] = name
        unknown = set(args.names) - lookup.keys()
        if unknown:
            parser.error("Unknown operator(s): " + ", ".join(sorted(unknown)))
        names = dict.fromkeys(lookup[name] for name in args.names)
        selected = {name: operators[name] for name in names}
        objectives = {
            ref for record in selected.values()
            for ref in record.get("derived_from", []) + record.get("supporting_objectives", [])
        }
        sources = {registry["source_objectives"][ref]["document"] for ref in objectives}
        sources.update(record["source"]["document"] for record in selected.values() if "source" in record)
        print(yaml.safe_dump({
            "sources": {name: registry["sources"][name] for name in sorted(sources)},
            "source_objectives": {ref: registry["source_objectives"][ref] for ref in sorted(objectives)},
            "operators": selected,
        }, sort_keys=False), end="")
    else:
        validate(args.root, registry, operators)
        if args.source_dir:
            verify_sources(args.source_dir, registry, operators)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, yaml.YAMLError, subprocess.CalledProcessError) as exc:
        raise SystemExit(f"FAIL: {exc}") from exc
