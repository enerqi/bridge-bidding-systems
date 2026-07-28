import os
import sys

# quiz.py / bidfilter.py are flat modules at the repo root, not a package
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
