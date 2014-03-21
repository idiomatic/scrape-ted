#!/usr/local/bin/coffee
# download TED talks
#
# the iteratable URL
#     http://www.ted.com/talks/view/id/#{id}
# redirects to
#     http://www.ted.com/talks/#{slug}.html
# which provides in JavaScript
#     q(event, data)
# which contains
#     data.talks[0].nativeDownloads.high =
#       "http://download.ted.com/talks/#{mediaSlug}-480p.mp4?apikey=TEDDOWNLOAD"
# leading to final product
#     http://download.ted.com/talks/#{mediaSlug}-#{quality}.mp4?apikey=TEDDOWNLOAD

fs = require 'fs'
stream = require 'stream'
events = require 'events'
util = require 'util'
async = require 'async'
jsdom = require 'jsdom'
request = require 'request'
#emitter.setMaxListeners

toMegs = (bytes) ->
    (bytes / 1000000).toFixed(1)

pad = ({left, right, width, padding}) ->
    left ?= ''
    right ?= ''
    width ?= 80
    padding ?= ' '
    filler = Array(width + 1)
        .join(padding)
        .substr(left.toString().length, width - right.toString().length)
    (left + filler + right).substr(0, width)

class Progress extends stream.Transform
    constructor: (options) ->
        super(options)
        { @id, @title } = options
        @screen_width = 80
        # adjust content_length upon reading HTTP headers
        @content_length = 0
        @cumulative_length = 0
        @on 'end', =>
            process.stdout.write("\r#{@status()}\n")

    status: =>
        if @cumulative_length < @content_length
            progress = " (#{toMegs @cumulative_length} of #{toMegs @content_length}M)"
        else
            progress = ''
        gauge = pad width:Math.round(@cumulative_length / @content_length * 10), padding:'='
        "[#{pad left:gauge, width:10}] #{pad right:@id, width:4, padding:'0'} #{pad left:@title, width:@screen_width - 19 - progress.length}#{progress}"

    _transform: (chunk, encoding, cb) =>
        @cumulative_length += chunk.length
        if @content_length > 0
            next_status = @status()
            if @last_status isnt next_status
                process.stdout.write("\r#{next_status}")
                @last_status = next_status
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
            jsdom.env html: body, (err, {document}) =>
                return cb?(err) if err
                @title = document.getElementsByTagName('title')?[0]?.textContent.trim() or @default_title
                @title = @title.replace(/\s*\|.*/, '')
                for script in document.getElementsByTagName('script')
                    if script.textContent.match(/^q\("talkPage.init",/)
                        # slighly scary way to parse talk details from JavaScript
                        { talks } = eval("function q(a,b){return b;}" + script.textContent)
                        { high } = talks[0].nativeDownloads
                        @media_slug = high.match(/\/talks\/(.*?)(?:-480p)?\.mp4/)[1]
                        @event_name = talks[0].event
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
                req.on 'error', cb
                progress = new Progress({@id, @title})
                req.pipe(progress).pipe(fs.createWriteStream("#{@dest_path}.new"))
                    .on 'finish', cb
                    .on 'error', cb
            (cb) =>
                fs.rename("#{@dest_path}.new", @dest_path, cb)
        ], (err) =>
            if err
                process.stdout.write("\n")
                process.stderr.write("#{err}\n")
            cb?(err)

download = async.queue (task, cb) ->
    task(cb)
, 1
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
