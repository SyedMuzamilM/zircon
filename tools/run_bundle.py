#!/usr/bin/env python3
"""Run the executable inside the development application bundle."""
import os
import sys

os.execv(sys.argv[1], [sys.argv[1], *sys.argv[2:]])
