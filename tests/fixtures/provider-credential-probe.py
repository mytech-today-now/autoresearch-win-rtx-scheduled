import json
import os
from pathlib import Path


provider_keys = (
    "OPENAI_API_KEY",
    "ANTHROPIC_API_KEY",
    "AZURE_OPENAI_API_KEY",
)
output_path = Path(os.environ["AUTORESEARCH_PROVIDER_PROBE_PATH"])
visible_keys = [name for name in provider_keys if os.environ.get(name)]

# This harmless generated-code probe writes only a name list to a test temp file.
output_path.write_text(
    json.dumps({"provider_key_names_present": visible_keys}),
    encoding="utf-8",
)
