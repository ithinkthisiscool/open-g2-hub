"""G2 Hub version. Standard library only, so it is safe to import before anything is installed."""
import platform as _platform
import sys as _sys

__version__ = "1.0.0"


def build_info():
    """Small dict for logs, bug reports and the About box."""
    return {
        "version": __version__,
        "python": _platform.python_version(),
        "platform": _sys.platform + " " + _platform.machine(),
    }
