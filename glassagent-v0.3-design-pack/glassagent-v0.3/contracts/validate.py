#!/usr/bin/env python3
"""校验契约 Schema、能力词表与示例。用法：python contracts/validate.py（需要 pip install jsonschema）。

三类示例：
  examples/valid/             必须通过 Schema 和语义检查
  examples/invalid/           必须在 Schema 阶段失败
  examples/semantic-invalid/  必须通过 Schema，但在语义检查（注册表静态检查的雏形）失败
"""
import json
import sys
from pathlib import Path

from jsonschema import Draft202012Validator

ROOT = Path(__file__).parent
SIDE = {"NONE": 0, "USER_OUTPUT": 1, "EXTERNAL": 2}


def load(p):
    return json.loads(Path(p).read_text(encoding="utf-8"))


def schema_errors(schema, doc):
    return [f"{'/'.join(map(str, e.absolute_path)) or '<root>'}: {e.message[:110]}"
            for e in Draft202012Validator(schema).iter_errors(doc)]


def vocab_checks(vocab):
    problems = []
    hw = {h["id"]: h for h in vocab["hardware"]}
    if len(hw) != len(vocab["hardware"]):
        problems.append("duplicate hardware id")
    caps = {}
    for c in vocab["brokerCapabilities"]:
        if c["id"] in caps:
            problems.append(f"duplicate capability {c['id']}")
        caps[c["id"]] = c
        req = c["requiresHardware"]
        refs = list(req["all"]) + [h for g in req["anyOf"] for h in g]
        for h in refs:
            if h not in hw:
                problems.append(f"{c['id']} references unknown hardware {h}")
    return hw, caps, problems


def manifest_semantic_errors(m, hw, caps):
    errs = []
    hwd = m["hardware"]
    required = set(hwd.get("required", []))
    optional = set(hwd.get("optional", []))
    any_groups = {frozenset(g) for g in hwd.get("anyOf", [])}
    used_hw = set(required) | set(optional) | {h for g in any_groups for h in g}
    for h in used_hw:
        if h not in hw:
            errs.append(f"unknown hardware {h}")
    worst = 0
    for cid in m["requiredCapabilities"]:
        cap = caps.get(cid)
        if cap is None:
            errs.append(f"unknown capability {cid}")
            continue
        if cap["status"] != "AVAILABLE":
            errs.append(f"capability {cid} is {cap['status']}, not available yet")
        for h in cap["requiresHardware"]["all"]:
            if h not in required:
                errs.append(f"{cid} needs hardware {h} but it is not declared in hardware.required")
        for g in cap["requiresHardware"]["anyOf"]:
            if frozenset(g) not in any_groups:
                errs.append(f"{cid} needs one of {g} but hardware.anyOf does not declare it")
        worst = max(worst, SIDE[cap["sideEffect"]])
    if worst > SIDE[m["maxSideEffect"]]:
        errs.append("maxSideEffect understates the side effects of requiredCapabilities")
    classes = set(m["privacy"]["dataClasses"])
    for h in used_hw:
        pc = hw.get(h, {}).get("privacyClass", "NORMAL")
        if pc != "NORMAL" and pc not in classes:
            errs.append(f"hardware {h} is {pc} but privacy.dataClasses does not include it")
    return errs


def main():
    sch = {n: load(ROOT / "schemas" / f"{n}.schema.json")
           for n in ["skill-manifest-v2", "device-envelope-v1", "capability-vocabulary-v1"]}
    for n, s in sch.items():
        Draft202012Validator.check_schema(s)
    vocab = load(ROOT / "vocab" / "capability-vocabulary-v1.json")
    failures = []
    ve = schema_errors(sch["capability-vocabulary-v1"], vocab)
    hw, caps, vp = vocab_checks(vocab)
    for p in ve + vp:
        failures.append(f"vocabulary: {p}")
    print(f"vocabulary: {len(hw)} hardware, {len(caps)} broker capabilities, "
          f"{'OK' if not (ve or vp) else 'PROBLEMS'}")

    for sub, expect in [("valid", "pass"), ("invalid", "schema-fail"), ("semantic-invalid", "semantic-fail")]:
        for f in sorted((ROOT / "examples" / sub).glob("*.json")):
            doc = load(f)
            kind = "skill-manifest-v2" if f.name.startswith("manifest-") else "device-envelope-v1"
            se = schema_errors(sch[kind], doc)
            sem = manifest_semantic_errors(doc, hw, caps) if (kind == "skill-manifest-v2" and not se) else []
            if expect == "pass":
                ok = not se and not sem
            elif expect == "schema-fail":
                ok = bool(se)
            else:
                ok = not se and bool(sem)
            detail = (se or sem or [""])[0]
            print(f"  [{'PASS' if ok else 'FAIL'}] {sub}/{f.name}" + (f"  <- {detail}" if detail else ""))
            if not ok:
                failures.append(f"{sub}/{f.name}: expected {expect}; schema={se[:2]} semantic={sem[:2]}")
    if failures:
        print("\nFAILED:\n" + "\n".join(failures))
        sys.exit(1)
    print("\nall contract checks passed")


if __name__ == "__main__":
    main()
