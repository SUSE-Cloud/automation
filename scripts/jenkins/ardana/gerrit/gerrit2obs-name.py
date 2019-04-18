#!/usr/bin/env python
import os
import sys

sys.path.append(os.path.dirname(__file__))
from gerrit_settings import gerrit_project_map  # noqa: E402


def main():
    parts = sys.argv[1].split('/')
    subproject = parts[1]
    branch = sys.argv[2]
    print(gerrit_project_map(branch)[subproject])


if __name__ == '__main__':
    main()
