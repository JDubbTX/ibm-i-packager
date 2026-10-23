set -euo pipefail
ACTION_ROOT="$(cd "$ACTION_ROOT" && pwd)"
image="ibmi-packager:${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${RANDOM}"
trap 'docker image rm "$image" >/dev/null' EXIT
docker build --tag "$image" --build-arg USER_ID="$(id -u)" \
  --file "$ACTION_ROOT/.github/actions.Dockerfile" "$ACTION_ROOT/.github"
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --volume "$ACTION_ROOT:/action:ro" \
  --volume "$GITHUB_WORKSPACE:/workspace" \
  --workdir /workspace \
  --env ACTION_INPUTS --env GITHUB_SHA --env GITHUB_RUN_ID --env GITHUB_RUN_ATTEMPT \
  "$image"
python3 - <<'PY'
import json
import os
from pathlib import Path
inputs = json.loads(os.environ["ACTION_INPUTS"])
directory = inputs.get("artifact-dir") or "artifacts"
operation = inputs.get("operation") or os.environ.get("ACTION_OPERATION", "pack")
manifest = inputs.get("manifest-name") or ("unpack-manifest.html" if operation == "unpack" else "pack-manifest.html")
package = "" if operation == "unpack" else str(Path(directory) / (inputs.get("stmf-name") or "package.savf"))
with open(os.environ["GITHUB_OUTPUT"], "a") as output:
    output.write("artifact-dir={}\npackage-path={}\nmanifest-path={}\n".format(
        directory, package, Path(directory) / manifest))
PY
