#!/usr/bin/python2.6
# TODO: use urllib2.urlretrieve?

import urllib2
import os
import re
import time
import urlparse
import zipfile
import StringIO
import cPickle as pickle
from UserDict import DictMixin

"""
import sys
sys.path.append('/Users/brie/bin')
from scrape_ted import *
ted = open_database()
"""


# HACK because shelve is unreliable
class FakeShelve(DictMixin):
    def __init__(self, database_directory):
        self.dbdir = database_directory
        if not os.path.exists(database_directory):
            os.makedirs(database_directory)
    def path(self, key):
        return os.path.join(self.dbdir, str(key))
    def file(self, key, mode="rb", suffix=""):
        return open(self.path(key) + suffix, mode)
    def keys(self):
        files = os.listdir(self.dbdir)
        files.sort
        return files
    def __contains__(self, key):
        return os.path.exists(self.path(key))
    def __getitem__(self, key):
        try:
            return pickle.load(self.file(key))
        except IOError:
            raise AttributeError
    def __setitem__(self, key, value):
        pickle.dump(value, self.file(key, "wb", ".new"))
        os.rename(self.path(key) + ".new", self.path(key))
    def __delitem__(self, key):
        os.unlink(self.path(key))
    def sync(self):
        pass
    def close(self):
        pass

class BadResourcePath(Exception):
    def __init__(self, url):
        self.url = url

class resource:
    def __init__(self, url, filename=None):
        self.url = url
        self.effective_url = None
        self.content = None
        self.filename = filename
        self.fetched = filename and os.path.exists(filename)
    def debug(self, message):
        print '%s: %s' % (os.path.split(self.url)[1], message)
    def fetch(self):
        if self.url is None:
            return
        self.debug("fetching resource %s" % (self.url,))
        u = urllib2.urlopen(self.url)
        self.effective_url = u.geturl()
        self.content_length = u.headers.get('Content-length', None)
        self.debug("--> %s%s" % (self.effective_url, (' [%s]' % self.content_length) if self.content_length else ''))
        self.content = u.read()
        if self.content_length is None:
            self.content_length = len(self.content)
        if u.headers['Content-type'] == 'application/zip':
            z = zipfile.ZipFile(StringIO.StringIO(self.content))
            for n in z.namelist():
                if '/' in n or n.startswith('.'):
                    raise BadResourcePath(n)
                self.debug("----> %s" % (n,))
                self.filename = n
                self.content = z.read(n)
                fi = z.getinfo(n)
                t = time.mktime(tuple(list(fi.date_time) + [ 0, 0, -1 ]))
                self.mtime = t
                break
        else:
            self.filename = os.path.split(self.effective_url)[1]
        self.fetched = True
        return self
    def save(self, filename=None):
        if self.content is None:
            return
        open(filename or self.filename, 'wb').write(self.content)
        if hasattr(self, 'mtime'):
            os.utime(filename or self.filename, (self.mtime, self.mtime))
        return self
        

class episode(resource):
    def __init__(self, tid):
        self.tid = tid
        url = 'http://www.ted.com/index.php/talks/view/id/%s' % tid
        resource.__init__(self, url)
        self.renditions = { }
    def title(self):
        title = re.search('<span [^>]*id="altHeadline"\s*>([^<]*)</span>', self.content).group(1)
        title = title.replace(":", " ")
        title = title.replace("/", " ")
        title = title.replace("  ", " ")
        title = title.strip()
        #year = re.search('fd:"[A-Z]\w\w (\d\d\d\d)",', self.content).group(1)
        m = re.search('\sen:"([^"]+)",', self.content)
        if not m:
            m = re.search('\sfd:"[A-Z]\w\w (\d\d\d\d)",', self.content)
        if m:
            event_name = m.group(1)
        elif re.search('<span class="botw">', self.content):
            m = re.search("<strong>Filmed</strong> [A-Z]\w\w (\d\d\d\d)", self.content)
            event_name = m.group(1)
            """
            event_name = { '720': "BotW 2005",
                           '721': "BotW 2005",
                           '722': "BotW 2009",
                           '730': "BotW 2007" }[self.tid]
            """
        tid = int(self.tid)
        return 'TEDTalks %04d %s (%s)' % (tid, title, event_name)

    def video_to_desktop_url(self):
        m = re.search('<a href="([^"]*)">Download to desktop', self.content)
        if m:
            url = urlparse.urljoin(self.url, m.group(1))
            return url

    def high_res_video_url(self):
        m = re.search('<a href="([^"]*)">High-res video', self.content)
        if m:
            url = urlparse.urljoin(self.url, m.group(1))
            return url

    def fetch(self):
        resource.fetch(self)
        title = self.title()
        url = self.video_to_desktop_url()
        if url and 'small' not in self.renditions:
            self.renditions['small'] = video(url, 'small', title)
        url = self.high_res_video_url()
        if url and 'big' not in self.renditions:
            self.renditions['big'] = video(url, 'big', title)


class video(resource):
    def __init__(self, url, rendition, title):
        resource.__init__(self, url)
        self.rendition = rendition
        self.title = title
    def save(self):
        #prefix, suffix = os.path.split(self.filename)
        ext = os.path.splitext(self.filename)[1]
        self.filename = os.path.join(self.rendition, self.title + ext)
        resource.save(self, self.filename)
        del self.content


ted_db = None
def open_database():
    global ted_db
    if ted_db is None:
        ted_db = FakeShelve('teddb')
    return ted_db

def close_database():
    global ted_db
    if ted_db:
        ted.close()
    ted_db = None

MIN_TED = 1
MAX_TED = 1241 #1326 #1210 #1205 #1200 #1173 #1140 #1134 #1109 #972 #866 #848 #766
SKIP_TEDS = set((48, 639))

def missing_ted_ids(ted):
    for i in range(MIN_TED, MAX_TED+1):
        tid = str(i)
        if tid not in ted and i not in SKIP_TEDS:
            yield tid

def missing_teds(ted):
    for tid in missing_ted_ids(ted):
        yield tid, episode(tid)

def cleanup_objects():
    # migration from older representations
    ted = open_database()
    for tid in ted.keys():
        e = ted[tid]
        changed = False
        '''
        if hasattr(e, 'small_video') and e.small_video and os.sep not in e.small_video:
            e.small_video = os.path.join('small', e.small_video)
            changed = True
        if not hasattr(e, 'tid'):
            e.tid = e.id
            del e.id
            changed = True
        if not hasattr(e, 'renditions'):
            e.renditions = { }
            changed = True
        if hasattr(e, 'small_video'):
            e.renditions['small'] = e.small_video
            del e.small_video
            changed = True
        if hasattr(e, 'big_video'):
            e.renditions['big'] = e.big_video
            del e.big_video
            changed = True
        for rendition in [ r for r, p in e.renditions.items() if p is None ]:
            del e.renditions[rendition]
            changed = True
        if 'small' in e.renditions and 'big' not in e.renditions:
            if isinstance(e.renditions['small'], basestring):
                big_video = e.renditions['small'].replace('small', 'big')
                if os.path.exists(big_video):
                    e.renditions['big'] = big_video
                    changed = True
        if 'small' in e.renditions:
            path = e.renditions['small']
            if isinstance(path, basestring):
                small_video = video(e.video_to_desktop_url(), 'small', e.title())
                small_video.filename = path
                small_video.fetched = True
                e.renditions['small'] = small_video
                changed = True
            small_video = e.renditions['small']
            if small_video.filename and os.path.exists(small_video.filename):
                e.renditions['small'].fetched = True
                try:
                    del small_video.content
                    changed = True
                except AttributeError:
                    pass
                changed = True
        if 'big' in e.renditions:
            path = e.renditions['big']
            if isinstance(path, basestring):
                big_video = video(e.high_res_video_url(), 'big', e.title())
                big_video.filename = path
                big_video.fetched = True
                e.renditions['big'] = big_video
                changed = True
            big_video = e.renditions['big']
            if big_video.filename and os.path.exists(big_video.filename):
                e.renditions['big'].fetched = True
                try:
                    del big_video.content
                except AttributeError:
                    pass
                changed = True
        '''
        if changed:
            ted[tid] = e

def fetch_pages():
    ted = open_database()
    for tid, e in missing_teds(ted):
        try:
            e.fetch()
            e.debug("fetched page %s" % (e.effective_url,))
        except urllib2.HTTPError:
            e.debug("HTTPError")
            e = episode(tid)
        ted[tid] = e
        ted.sync()
        time.sleep(1)

def fetch_videos(rendition="small"):
    ted = open_database()
    for tid in ted.keys():
        e = ted[tid]
        if e.fetched:
            if rendition in e.renditions:
                #v = e.fetch_video(u, rendition)
                v = e.renditions[rendition]
                if not v.fetched:
                    try:
                        v.fetch()
                        v.save()
                        v.fetched = True
                        ted[tid] = e
                        ted.sync()
                    except urllib2.HTTPError:
                        pass
                

def process_titles():
    ted = open_database()
    for tid in ted.keys():
        e = ted[tid]
        changed = False
        for rendition, v in e.renditions.items():
            original_video = v.filename
            ext = os.path.splitext(original_video)[1]
            title = e.title()
            new_video = os.path.join(rendition, title + ext)
            if original_video != new_video:
                print "mv %s \\\n   %s" % (original_video, new_video)
                if os.path.exists(new_video):
                    e.debug("warning: %s already exists" % new_video)
                else:
                    os.rename(original_video, new_video)
                    #e.original_small_video = e.small_video
                    v.filename = new_video
                    changed = True
            if changed:
                ted[tid] = e

def main():
    print "=== cleanup ==="
    cleanup_objects()
    print "=== fetch pages ==="
    fetch_pages()
    print "=== fetch small videos ==="
    fetch_videos("small")
    print "=== fetch big videos ==="
    fetch_videos("big")
    print "=== process titles ==="
    process_titles()


if __name__ == '__main__':
    main()

