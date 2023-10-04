#!/usr/bin/env python
##
#
# Based on Rosetta Code recursive dir walk example
# http://rosettacode.org/wiki/Walk_a_directory/Recursively#Python
#
# Blake Golliher - blakegolliher@gmail.com
#
##

import fnmatch
import sys,os

rootPath = sys.argv[1]
pattern = '*'
fullSize = 0

for root, dirs, files in os.walk(rootPath):
    for filename in fnmatch.filter(files, pattern):
        fullpathname = os.path.join(root, filename)
        size = os.path.getsize(fullpathname)
        ## print "SIZE = %s  -> %s" % (size,fullpathname)
        fullSize = fullSize + size

def sizeof_fmt(num):
    for x in ['Bytes','KB','MB','GB','TB']:
        if num < 1024.0:
            return "%3.1f %s" % (num, x)
        num /= 1024.0

print "Whole size of path %s is %s." % (rootPath,sizeof_fmt(fullSize))
