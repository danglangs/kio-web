#!/usr/bin/env python3
"""Print the rows of a SQL query on a SQLite file, columns joined by `|`: `db.py FILE SQL`."""
import sqlite3
import sys

for row in sqlite3.connect(sys.argv[1]).execute(sys.argv[2]):
    print("|".join(map(str, row)))
