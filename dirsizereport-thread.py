#!/usr/bin/env python
##
# Blake Golliher
# blakegolliher@gmail.com
##

from threading import Thread
import time
import os,sys,subprocess

rootPath = sys.argv[1]

def sizeof_fmt(num):
    for x in ['Bytes','KB','MB','GB','TB']:
        if num < 1024.0:
            return "%3.1f %s" % (num, x)
        num /= 1024.0

def get_subdirs(dir):
    return [name for name in os.listdir(dir)
            if os.path.isdir(os.path.join(dir, name))]

class GetDirThread(Thread):
    def __init__(self, dir):
        self.dir = dir
        super(GetDirThread, self).__init__()

    def run(self):
  for root, dirs, files in os.walk(self.dir):
    		for filename in files:
			rawsize = 0
			dusize = 0
        		fullpathname = os.path.join(root, filename)
        		rawsize = os.path.getsize(fullpathname)
			dusize = subprocess.Popen(['du', '-s', fullpathname],stdout=subprocess.PIPE).communicate()[0].split()[0]
                        rawsize += rawsize
                        dusize = int(dusize) + int(dusize)
        	print self.dir, sizeof_fmt(rawsize), sizeof_fmt(dusize)
       		return self.dir, sizeof_fmt(rawsize), sizeof_fmt(dusize)

def get_responses():
    dirs= get_subdirs(rootPath)
    start = time.time()
    threads = []
    for dir in dirs:
        t = GetDirThread(dir)
        threads.append(t)
        t.start()
    for t in threads:
        t.join()
    print "Elapsed time: %s" % (time.time()-start)

total_files = sum([len(files) for (root, dirs, files) in os.walk(rootPath)])
print 'Total Files: 	%s' % total_files
get_responses()
