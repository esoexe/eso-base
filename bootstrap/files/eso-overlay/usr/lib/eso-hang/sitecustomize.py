# ESO hang detector loader: with PYTHONPATH=<this dir> and ESO_HANGLOG=1 every Python program watches its own
# interface for freezes (see esohang.py, next to this file or one folder up).
import os, sys
_here = os.path.dirname(os.path.abspath(__file__))
_add = [_here, os.path.dirname(_here)]
sys.path[:0] = _add
try:
    import esohang
    esohang.start()
except Exception:
    pass
finally:
    for _p in _add:
        try:
            sys.path.remove(_p)
        except ValueError:
            pass
