#!/usr/local/bin/coffee
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
util = require 'util'
async = require 'async'
jsdom = require 'jsdom'
request = require 'request'
multimeter = require 'multimeter'
#emitter.setMaxListeners

clean = (s) ->
    s.replace(/[: \/]+/g, ' ')

megs = (b) ->
    (b / 1000000).toFixed(1)

#zeropad = (v, w) -> (v + 1e15 + '').slice(-w)
pad = (v, width, padding='0') ->
    if v < 0
        '-' + pad(-v, width - 1, padding)
    else
        Array(width).join(padding).substring("#{v}".length - 1, width - 1) + v

pad2 = (v, width, padchar='0', prefix='') ->
    if v < 0
        pad -v, width - 1, padchar, prefix + '-'
    else if (prefix + v).length >= width
        prefix + v
    else
        pad(padchar + v, width, padchar, prefix)

multi = multimeter(process)
multi.on '^C', () ->
    multi.charm.write '\n'

scrollBars = (dy, dx) ->
    for bar in multi.bars
        bar.y += (dy or 0)
        bar.x += (dx or 0)

closeBar = (bar) ->
    i = multi.bars.indexOf bar
    if i >= 0
        multi.bars.splice(i, 1)

class Talk
    constructor: (@id) ->
        @default_title = 'Untitled'
        @default_event = 'TED'
        @bitrate = '1500k'
    fetchDetails: (cb) =>
        request.get "http://www.ted.com/talks/view/id/#{@id}", (err, res, body) =>
            return cb?(err) if err
            return cb?(new Error("HTTP status #{res.statusCode}")) if res.statusCode >= 400
            jsdom.env html:body, (err, window) =>
                return cb?(err) if err
                @title = (window.document.getElementsByTagName 'title')?[0]?.textContent or @default_title
                @title = @title.replace(/\s*\|.*/, '')
                @event_name = (window.document.getElementsByClassName 'event-name')?[0]?.textContent or @default_event
                for script in window.document.getElementsByTagName 'script'
                    if script.textContent.match /talkDetails/
                        eval script.textContent
                        { mediaSlug } = talkDetails
                        @media_slug = mediaSlug
                        break
                cb?(false)

    videoStream: (cb) =>
        url = "http://download.ted.com/talks/#{@media_slug}-#{@bitrate}.mp4?apikey=TEDDOWNLOAD"
        req = request.get url
        req.on 'response', (res) =>
            @content_length = parseInt(res.headers['content-length'])
        req.end()
        cb?(false, req)

    progressMeter: (res, cb) =>
        @cumulative_length = 0
        res.on 'data', (data) =>
            @cumulative_length += data.length
        multi.drop width:16, before:'[', after:"] #{@id}: #{@title.substring 0, 40} ", text:'=', (bar) =>
            res.on 'data', (data) =>
                bar.ratio megs(@cumulative_length), megs(@content_length)
            res.on 'end', () =>
                process.nextTick =>
                    bar.after = "] #{@id}: #{@title.substring 0, 54}"
                    bar.solid =
                        background: 'white'
                        foreground: 'black'
                        text: '='
                    bar.draw bar.width, ''
                    closeBar bar
            multi.charm.write('\n')
            multi.charm.position (previous_x, previous_y) =>
                if bar.y == previous_y
                    scrollBars(-1)
                    multi.charm.erase('line')
                cb?(false, res)

    fetch: (cb) =>
        async.waterfall [
            @fetchDetails
            (cb) =>
                @dest_path = "TEDTalks #{pad @id, 4} #{clean @title} (#{clean @event_name}).mp4"
                fs.exists @dest_path, (exists) =>
                    exists and= new Error("#{@dest_path} already exists")
                    cb(exists)
            @videoStream
            (req, cb) =>
                req.on 'response', (res) =>
                    cb(false, res)
                req.on 'error', cb
                req.pipe fs.createWriteStream @dest_path
            @progressMeter
            (res, cb) =>
                res.on 'error', cb
                res.on 'end', cb
        ], (err) =>
            if err
                scrollBars(-1 * Math.ceil(err.length / 80))
                multi.charm.write "#{err}\n"
            cb?(err)

q = async.queue (task, cb) ->
    task cb
, 3
q.drain = () ->
    process.nextTick ->
        process.exit()

for arg in process.argv[2..]
    match = arg.match /^(\d+)-(\d+)$/
    if match
        [ _, start, end ] = match
        for i in [parseInt(start, 10)..parseInt(end, 10)]
            q.push new Talk(i).fetch
    else if arg.match /^\d+$/
        q.push new Talk(parseInt(arg, 10)).fetch
