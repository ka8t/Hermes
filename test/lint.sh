#!/usr/bin/env bash
# Static validation: syntax and structure only, no network access, no
# containers started. Safe to run anywhere, including CI.
#
#   ./test/lint.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0

echo "== bash syntax =="
while IFS= read -r -d '' f; do
  if bash -n "$f" 2>/tmp/lint_err; then
    echo "ok   $f"
  else
    echo "FAIL $f"
    cat /tmp/lint_err
    fail=1
  fi
done < <(find . -name "*.sh" -not -path "./.git/*" -print0)

echo
echo "== YAML syntax (docker-compose*.yml, *.yaml.example*) =="
python3 <<'PY' || fail=1
import glob, sys, yaml

# Compose Specification merge tags (!reset, !override) let one compose
# file cancel/replace a value from another when used with `docker
# compose -f a.yml -f b.yml` -- valid syntax for their actual consumer
# (Docker Compose), used by the GPU overlays (docker-compose.gpu-*.yml,
# see docs/ARCHITECTURE.md's 2026-09-15 llama-swap removal), but not
# understood by plain PyYAML's SafeLoader, which would otherwise reject
# every such file outright. Registered as a pass-through constructor so
# the underlying value still gets real syntax validation -- this is
# about accepting the tag, not skipping the file.
class ComposeLoader(yaml.SafeLoader):
    pass

def _construct_compose_merge_tag(loader, node):
    if isinstance(node, yaml.ScalarNode):
        return loader.construct_scalar(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node)
    if isinstance(node, yaml.MappingNode):
        return loader.construct_mapping(node)
    return None

ComposeLoader.add_constructor("!reset", _construct_compose_merge_tag)
ComposeLoader.add_constructor("!override", _construct_compose_merge_tag)

bad = False
patterns = ["**/docker-compose*.yml", "**/*.yaml.example", "**/*.yaml.example.*"]
seen = set()
for pattern in patterns:
    for f in glob.glob(pattern, recursive=True):
        if f in seen or "/.git/" in f:
            continue
        seen.add(f)
        try:
            with open(f) as fh:
                yaml.load(fh, Loader=ComposeLoader)
            print(f"ok   {f}")
        except Exception as e:
            print(f"FAIL {f}: {e}")
            bad = True
sys.exit(1 if bad else 0)
PY

echo
echo "== every models.yaml.example has a matching config.yaml.example model.default =="
python3 <<'PY' || fail=1
import glob, re, sys

bad = False
for models_file in glob.glob("*/config/models.yaml.example"):
    platform_dir = models_file.split("/config/")[0]
    config_file = f"{platform_dir}/config/config.yaml.example"
    models_text = open(models_file).read()
    config_text = open(config_file).read()

    model_ids = re.findall(r'^\s{2}"([^"]+)":', models_text, re.MULTILINE)
    default_match = re.search(r"^\s*default:\s*(\S+)", config_text, re.MULTILINE)
    default_id = default_match.group(1) if default_match else None

    if not model_ids:
        print(f"FAIL {models_file}: no model IDs found")
        bad = True
        continue
    if default_id not in model_ids:
        print(f"FAIL {config_file}: model.default '{default_id}' not among {models_file} IDs {model_ids}")
        bad = True
    else:
        print(f"ok   {config_file} default '{default_id}' matches {models_file}")

sys.exit(1 if bad else 0)
PY

echo
if [ "$fail" -ne 0 ]; then
  echo "lint: FAILED"
  exit 1
fi
echo "lint: all checks passed"
