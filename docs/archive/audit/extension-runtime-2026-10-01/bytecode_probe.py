#!/usr/bin/env python3
"""Inspect constant-pool references in translations; no extension execution."""
import json
import pathlib
import struct
import sys
import zipfile


def pool(body):
    count = struct.unpack_from(">H", body, 8)[0]
    entries = [None] * count
    offset, index = 10, 1
    while index < count:
        tag = body[offset]
        offset += 1
        if tag == 1:
            length = struct.unpack_from(">H", body, offset)[0]
            offset += 2
            entries[index] = (tag, body[offset:offset + length].decode("utf-8", errors="replace"))
            offset += length
        elif tag in (3, 4):
            offset += 4
        elif tag in (5, 6):
            offset += 8
            index += 1
        elif tag in (7, 8, 16, 19, 20):
            entries[index] = (tag, struct.unpack_from(">H", body, offset)[0])
            offset += 2
        elif tag in (9, 10, 11, 12, 17, 18):
            entries[index] = (tag, *struct.unpack_from(">HH", body, offset))
            offset += 4
        elif tag == 15:
            offset += 3
        else:
            raise ValueError(f"unknown constant-pool tag {tag}")
        index += 1
    return entries


def main():
    translations = pathlib.Path(sys.argv[1])
    host = pathlib.Path(sys.argv[2])
    with zipfile.ZipFile(host) as jar:
        host_classes = {p.removesuffix(".class") for p in jar.namelist() if p.endswith(".class")}
    results = []
    for path in sorted(translations.glob("*.jar")):
        with zipfile.ZipFile(path) as jar:
            own = {p.removesuffix(".class") for p in jar.namelist() if p.endswith(".class")}
            missing = set()
            methods = set()
            for name in jar.namelist():
                if not name.endswith(".class"):
                    continue
                constants = pool(jar.read(name))
                for entry in constants:
                    if not entry:
                        continue
                    if entry[0] == 7:
                        target = constants[entry[1]][1]
                        if target.startswith(("com/lagradost/cloudstream3/", "android/")) and target not in host_classes | own:
                            missing.add(target)
                    if entry[0] in (10, 11):
                        owner = constants[constants[entry[1]][1]][1]
                        member = constants[entry[2]]
                        if owner == "kotlin/Result":
                            methods.add(constants[member[1]][1] + constants[member[2]][1])
            results.append({"translated_artifact": path.name, "missing_host_class_references": sorted(missing),
                            "kotlin_result_method_references": sorted(methods)})
    output = {"host_jar": str(host), "scope": "Static constant-pool references; missing optional paths may not execute.", "results": results}
    pathlib.Path(__file__).with_name("bytecode-results.json").write_text(json.dumps(output, indent=2) + "\n")
    print(json.dumps(output, indent=2))


if __name__ == "__main__":
    main()
