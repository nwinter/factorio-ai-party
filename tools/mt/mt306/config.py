"""Local paths only; importing this module never contacts imac2 or reads credentials."""
import os
import sys
from pathlib import Path
CODE = Path(__file__).resolve().parent
TREE = CODE.parents[2]
HERE = Path(os.environ.get('MT306_ART', Path.home() / 'code/pog-operator/mt306-artifacts/after')).expanduser().resolve()
CLAIM = Path(os.environ.get('MT306_CLAIM', Path.home() / 'code/pog-operator/server-claim.txt')).expanduser()
PASSWORD_FILE = Path(os.environ.get('MT306_PASSWORD_FILE', Path.home() / '.config/pog/rcon-imac2.pw')).expanduser()
PYTHON = sys.executable
LABEL = os.environ.get('MT306_LABEL', 'after')
