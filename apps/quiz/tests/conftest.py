import os
import sys

# quiz.py / bidfilter.py are flat modules in apps/quiz, not a package
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
