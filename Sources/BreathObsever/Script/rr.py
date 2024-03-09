import os
import sys

arr = sys.argv[1].split(',')
command = f'echo {arr}'
os.system(command)
