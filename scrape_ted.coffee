#!/usr/local/bin/coffee
# download TED talks in parallel
#
# the iteratable URL
#     http://www.ted.com/talks/view/id/#{id}
# redirects to
#     http://www.ted.com/talks/#{slug}.html
# which provides in JavaScript
#     talkDetails.id = id
#     talkDetails.mediaSlug = "#{speaker}_#{eventid}"
#     talkDetails.htmlStreams[1] =
#         id:'high'
#         file:"http://download.ted.com/talks/#{mediaSlug}-950k.mp4?apikey=TEDDOWNLOAD"
# leading to final product
#     http://download.ted.com/talks/#{mediaSlug}-#{quality}.mp4?apikey=TEDDOWNLOAD

fs = require 'fs'
stream = require 'stream'
events = require 'events'
util = require 'util'
async = require 'async'
jsdom = require 'jsdom'
request = require 'request'
multimeter = require 'multimeter'
#emitter.setMaxListeners

toMegs = (bytes) ->
    (bytes / 1000000).toFixed(1)

pad = ({left, right, width, padding}) ->
    left ?= ''
    right ?= ''
    width ?= 80
    padding ?= ' '
    if right < 0
        pad(left + '-', -right, width, padding)
    else
        filler = Array(width).join(padding).substring(left.length + right.length - 1, width - 1)
        (left + filler + right).substring(0, width)

multi = multimeter(process)
{ charm } = multi
multi.on '^C', () ->
    charm.write('\n')

# reposition active multimeter bars
scrollBars = (dy, dx) ->
    for bar in multi.bars
        bar.y += (dy or 0)
        bar.x += (dx or 0)

# forget about a bar
closeBar = (bar) ->
    i = multi.bars.indexOf(bar)
    if i >= 0
        multi.bars.splice(i, 1)

# screen serializer
screen = async.queue (task, cb) ->
    task cb
, 1

# cursor-preserving screen task
excursion = (task, cb) ->
    screen.push (cb) ->
        charm.position (before_x, before_y) ->
            task (args...) ->
                charm.position(before_x, before_y)
                cb(args...)
    , cb

# get coordinates of extreme bottom right cursor position
screenSize = (cb) ->
    excursion (cb) ->
        charm.move(9999, 9999)
        charm.position cb
    , cb

# measure dy of this message
newLineCount = (message, screen_width=80, cursor_x=1) ->
    lines = message.split('\n')
    add = (a, b) -> a + b
    # XXX add cursor_x to first line
    (Math.floor(line.length / screen_width) for line in lines)
        .reduce(add, lines.length - 1)

# upon each linefeed at bottom of screen, emit 'scroll'
class ScrollPredictingWriter extends events.EventEmitter
    write: (message, cb) =>
        screenSize (width, height) =>
            screen.push (cb) ->
                charm.position (before_x, before_y) ->
                    charm.write(message)
                    charm.erase('end')
                    charm.position (_, after_y) ->
                        cb(Math.max(0, newLineCount(message, width, before_x) + before_y - after_y))
            , (scrolls) =>
                @emit('scroll', scrolls) if scrolls > 0
                cb?()

write = new ScrollPredictingWriter()
    .on('scroll', (n) -> scrollBars(-n))
    .write

class Progress extends stream.Transform
    constructor: (options) ->
        super(options)
        { @id, @title } = options
        # adjust content_length upon reading HTTP headers
        @content_length = 0
        @cumulative_length = 0
        @on 'end', =>
            #process.nextTick =>
            excursion (cb) =>
                charm.position(@bar.x, @bar.y)
                charm.erase('line')
                @bar.after = "] #{@id}: #{@title.substring 0, 54}"
                @bar.solid =
                    background: 'white'
                    foreground: 'black'
                    text: '='
                @bar.draw(@bar.width, '')
                closeBar(@bar)
                cb()
    drop: (cb) =>
        bar_options =
            width: 16
            before: '['
            after: "] #{@id}: #{pad left:@title, width:40}  "
            text: '='
        multi.drop bar_options, (@bar) =>
            write('\n')
            charm.erase('line')
            cb?()
    _transform: (chunk, encoding, cb) =>
        @cumulative_length += chunk.length
        if @content_length > 0
            n = toMegs(@cumulative_length)
            d = toMegs(@content_length)
            @bar?.ratio(n, d, "#{n} of #{d}M")
        @push(chunk)
        cb()

class Talk
    constructor: (@id) ->
        @default_title = 'Untitled'
        @default_event = 'TED'
        @bitrate = '1500k'
    fetchDetails: (cb) =>
        request.get "http://www.ted.com/talks/view/id/#{@id}", (err, res, body) =>
            return cb?(err) if err
            return cb?(new Error("HTTP status #{res.statusCode}")) if res.statusCode >= 400
            jsdom.env html: body, (err, window) =>
                return cb?(err) if err
                @title = window.document.getElementsByTagName('title')?[0]?.textContent or @default_title
                @title = @title.replace(/\s*\|.*/, '')
                @event_name = window.document.getElementsByClassName('event-name')?[0]?.textContent or @default_event
                for script in window.document.getElementsByTagName('script')
                    if script.textContent.match(/talkDetails/)
                        # slighly scary way to parse talkDetails from JavaScript
                        eval(script.textContent)
                        { mediaSlug } = talkDetails
                        @media_slug = mediaSlug
                        break
                cb?(false)

    videoStream: (cb) =>
        url = "http://download.ted.com/talks/#{@media_slug}-#{@bitrate}.mp4?apikey=TEDDOWNLOAD"
        req = request.get(url)
        req.end()
        cb?(false, req)

    fetch: (cb) =>
        async.waterfall [
            @fetchDetails
            (cb) =>
                clean = (s) ->
                    s.replace(/[: \/]+/g, ' ')
                @dest_path = "TEDTalks #{pad right:@id, width:4, padding:'0'} #{clean @title} (#{clean @event_name}).mp4"
                fs.exists @dest_path, (exists) =>
                    exists and= new Error("#{@dest_path} already exists")
                    cb(exists)
            @videoStream
            (req, cb) =>
                req.on 'response', (res) =>
                    progress.content_length = parseInt(res.headers['content-length'], 10)
                    progress.drop =>
                        cb(false, res)
                req.on('error', cb)
                progress = new Progress({@id, @title})
                req.pipe(progress).pipe(fs.createWriteStream(@dest_path))
            (res, cb) =>
                res.on('error', cb)
                res.on('end', cb)
        ], (err) =>
            if err
                write("#{err}\n")
                charm.erase('line')
            cb?(err)

download = async.queue (task, cb) ->
    task(cb)
, 3
download.drain = () ->
    setTimeout ->
        process.exit()
    , 100

for arg in process.argv[2..]
    match = arg.match(/^(\d+)-(\d+)$/)
    if match
        [ _, start, end ] = match
        for i in [parseInt(start, 10)..parseInt(end, 10)]
            download.push(new Talk(i).fetch)
    else if arg.match(/^\d+$/)
        download.push(new Talk(parseInt(arg, 10)).fetch)
    else
        console.log "Usage: scrape_ted [ { TALK_ID | START_TALK_ID-END_TALK_ID } ... ]"
