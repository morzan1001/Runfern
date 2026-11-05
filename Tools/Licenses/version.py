"""App version from Version.xcconfig, shared by the license tools."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VERSION = re.search(r"^MARKETING_VERSION = (\S+)$", (ROOT / "Version.xcconfig").read_text(), re.M).group(1)
SOURCE_ARCHIVE = f"Runfern-{VERSION}-source-inputs.tar.gz"
