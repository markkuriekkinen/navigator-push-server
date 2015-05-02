#!/usr/bin/env coffee

xml2js  = require 'xml2js'
http    = require 'http'
https   = require 'https'

{dbConnect, Subscription, SentMessageHash} = require './db'


NEWS_URL = 'https://www.hsl.fi/en/newsApi/all'
DISRUPTIONS_URL = 'http://www.poikkeusinfo.fi/xml/v2/en'
PUSH_URL = 'https://android.googleapis.com/gcm/send'
PUSH_HOST = 'android.googleapis.com'
PUSH_URL_PATH = '/gcm/send'

# The interval in milliseconds for fetching updates from HSL servers.
UPDATE_INTERVAL = process.env.UPDATE_INTERVAL ? 1000*60


# API key from Google (Don't save this in the public repo!)
GCM_PUSH_API_KEY =
    process.env.GCM_PUSH_API_KEY ?
    try
        require('./secret_keys').GCM_PUSH_API_KEY
    catch
        console.error("""
            Google Cloud Messaging API key not set. The key can be
            given in the environment variable GCM_PUSH_API_KEY or in a
            file named secret_keys.js as follows:

                module.exports = { GCM_PUSH_API_KEY: "..." };

            The file MUST NOT be stored in a public repository!
            """)
        process.exit 1


# Push a message to the client using Google Cloud Messaging (GCM).
# Parameter msg is a plain JS object with keys:
# clientId, message, lines, category, validThrough
pushToClient = (msg, retryTimeout = 1000) ->
    # The message is only pushed to the client if it has not been yet pushed earlier
    SentMessageHash.storeHash msg, (err, msgHashDoc) ->
        if err
            console.error err
        else if not msgHashDoc?  # if null, the message has already been sent
            console.log "GCM request already sent, skipping: %j", msg
        else
            
            # Send HTTP POST request to the GCM push server that will
            # then send it to the client
            # http://developer.android.com/google/gcm/server-ref.html
            options =
                hostname: PUSH_HOST
                path: PUSH_URL_PATH
                method: 'POST'
                headers:
                    'Authorization': "key=#{ GCM_PUSH_API_KEY }"
                    'Content-Type': 'application/json'
            
            timeTillEnd =
                if msg.validThrough?
                    (msg.validThrough.getTime() - new Date().getTime()) / 1000
                else
                    0
            timeToLive =
                if timeTillEnd > 0
                    # set time_to_live till the end of the journey in seconds
                    timeTillEnd
                else
                    60 * 60 * 24 # 24 h
            postData =
                registration_ids: [msg.clientId] # The clientId is used by GCM to identify the client device.
                time_to_live: timeToLive
                data: # payload to client, data values should be strings
                    title: "Traffic disruption"
                    message: msg.message
                    disruption_lines: msg.lines.join() # array to comma-separated string
                    disruption_category: msg.category
            
            console.log "sending GCM request: %j", postData
            
            request = https.request options, (response) ->
                # response from GCM push server
                response.setEncoding 'utf8'
                responseData = ''
                # gather the whole response body into one string before parsing JSON
                response.on 'data', (chunk) ->
                    responseData += chunk
                    
                response.on 'end', ->
                    try
                        if response.statusCode == 401
                            throw "GCM auth error 401"
                        else if response.statusCode == 400
                            throw "GCM bad request JSON error"
                        else if 500 <= response.statusCode <= 599
                            # GCM server error, retry later
                            # remove the message document before trying to push it again
                            msgHashDoc.remove (err) ->
                                console.error err if err
                                timeout =
                                    if 'retry-after' of response.headers
                                        parseHttpRetryAfter response.headers['retry-after']
                                    else
                                        retryTimeout
                                scheduleMessagePush msg, timeout
                        else if response.statusCode == 200
                            # success, but nonetheless there may be
                            # errors in delivering messages to clients
                            try
                                jsonObj = JSON.parse responseData
                            catch
                                throw "GCM response JSON parse error"
                            
                            if jsonObj.failure > 0 or jsonObj.canonical_ids > 0
                                # there were some problems
                                for resObj in jsonObj.results
                                    if resObj.message_id? and resObj.registration_id?
                                        # must replace the client registration id with
                                        # the new resObj id (canonical id)
                                        console.log "GCM client id changed. Updating database."
                                        # modify database
                                        Subscription.update { clientId: msg.clientId },
                                            { clientId: resObj.registration_id },
                                            (err) -> console.error err if err
                                        SentMessageHash.update { clientId: msg.clientId },
                                            { clientId: resObj.registration_id },
                                            (err) -> console.error err if err
                                        # no need to resend, GCM just informed us
                                        # that the registration id was changed
                                    else if resObj.error?
                                        if resObj.error == 'Unavailable'
                                            # GCM server unavailable, retry
                                            # remove the message hash document before trying to push it again
                                            msgHashDoc.remove (err) ->
                                                console.error err if err
                                                timeout =
                                                    if 'retry-after' of response.headers
                                                        parseHttpRetryAfter response.headers['retry-after']
                                                    else
                                                        retryTimeout
                                                scheduleMessagePush msg, timeout
                                        else if resObj.error == 'NotRegistered'
                                            Subscription.remove { clientId: msg.clientId },
                                                (err) -> console.error err if err
                                            throw "GCM client not registered,
                                                   removing client from database"
                                        else
                                            throw "GCM response error: #{ resObj.error }"
                        else
                            throw "unknown GCM response status code: #{response.statusCode}"
                    
                    catch errMsg
                        console.error "pushToClient: #{errMsg}"
                        msgHashDoc.remove (err) -> console.error err if err
                    return
                
                response.on 'error', (err) -> console.error "pushToClient: #{err}"
            
            request.on 'error', (err) -> console.error "pushToClient: #{err}"
            
            # write data to request body
            request.write JSON.stringify postData
            request.end()

# Find clients that are using lines (given as array) in the area.
# Push notification messages to the affected clients.
findClients = (lines, areaField, message, disrStartTime, disrEndTime) ->
    createMessages = (err, clientIds) -> 
        if err
            console.error err
        else
            for id in clientIds
                pushToClient
                    clientId: id
                    message: message # human-readable text
                    lines: lines
                    category: areaField
                    validThrough: disrEndTime
        return

    criteria = {}
    criteria.category = areaField if areaField != 'all'
    # if lines[0] == 'all', find clients that are using any line in the area
    criteria.line = { $in: lines } if lines[0] != 'all' # add lines criteria if searching only for specific lines
    criteria.startTime = { $lt: disrEndTime } if disrEndTime
    criteria.endTime = { $gt: disrStartTime } if disrStartTime

    Subscription.distinct 'clientId', criteria, createMessages

# Set a message push to occur in millisecs time. The push message will be
# sent to the GCM servers but it is still up to them to decide when
# the message is really sent to client devices.
scheduleMessagePush = (msg, inmillisecs) ->
    action = ->
        # remove this timeout from list
        i = scheduledMessagePushes.indexOf timeout
        scheduledMessagePushes.splice(i, 1)  if i >= 0

        # double the timeout for the possible next retry after this one
        # (exponential back-off)
        pushToClient msg, 2 * inmillisecs

    timeout = setTimeout action, inmillisecs
    scheduledMessagePushes.push timeout

scheduledMessagePushes = []

# HTTP retry-after header may be a date string or a decimal integer in seconds.
# Return the timeout in milliseconds from this moment.
parseHttpRetryAfter = (retryAfterValue) ->
    if isNaN retryAfterValue
        # header contains a date string,
        # get time in milliseconds from this moment to that moment
        timeout = new Date(retryAfterValue).getTime() - new Date().getTime()
        if timeout > 0
            timeout
        else
            5000 # arbitrary default if retry-after header date is in the past
    else
        # header is integer in seconds
        1000 * parseInt retryAfterValue, 10

# Return true if daylight saving is currently in use.
isDstOn = () ->
    # Modified from http://javascript.about.com/library/bldst.htm
    dateStdTimezoneOffset = (date) ->
        jan = new Date date.getFullYear(), 0, 1
        jul = new Date date.getFullYear(), 6, 1
        Math.max jan.getTimezoneOffset(), jul.getTimezoneOffset()
    
    dateDst = (date) ->
        date.getTimezoneOffset() < dateStdTimezoneOffset(date)

    dateDst new Date()

# mapping from HSL news API Main category values to the categories we use here
NEWS_API_CATEGORIES =
    'Helsinki internal bus': 'helsinkiInternal'
    'Espoo internal bus':    'espooInternal'
    'Vantaa internal bus':   'vantaaInternal'
    'Regional':              'regional'
    'Regional night line':   'regional'
    'Tram':                  'tram'
    'Commuter train':        'train'
    'Ferry':                 'ferry'
    'U line':                'Uline'
    'Sipoo internal line':   'sipooInternal'
    'Kerava internal bus':   'keravaInternal'

# newsObj is the JS object parsed from the HSL news response
parseNewsResponse = (newsObj) -> 
    for node in newsObj.nodes
        node = node.node
        lines = node.Lines.split ','
        cat = node['Main category']
        # the news do not contain easily parsable dates for the validity period
        if cat of NEWS_API_CATEGORIES
            findClients lines, NEWS_API_CATEGORIES[cat], node.title
        else
            console.log "parseNewsResponse: unknown Main category: #{ cat }"
    return

# mapping from poikkeusinfo linetypes to the categories we use here
DISRUPTION_API_LINETYPES = 
    '1': 'helsinkiInternal'
    '2': 'tram'
    '3': 'espooInternal'
    '4': 'vantaaInternal'
    '5': 'regional'
    '6': 'metro'
    '7': 'ferry'
    '12': 'train' # commuter trains
    #'14': 'all' # handled separately
    '36': 'kirkkonummiInternal'
    '39': 'keravaInternal'

# Parse XML response from poikkeusinfo server.
# Parameter disrObj is a JS object parsed from XML.
parseDisruptionsResponse = (disrObj) ->
    # HSL API description in Finnish (no pdf in English)
    # http://developer.reittiopas.fi/media/Poikkeusinfo_XML_rajapinta_V2_2_01.pdf
    for key, value of disrObj.DISRUPTIONS
        if key == 'DISRUPTION'
            for disrObj in value
                # disrObj is one disruption message (one DISRUPTION element from the original XML)
                isValid = false
                disrStartTime = null
                disrEndTime = null
                message = ''
                linesByArea = {
                    # these keys must match the values of the object DISRUPTION_API_LINETYPES
                    helsinkiInternal: []
                    espooInternal: []
                    vantaaInternal: []
                    regional: []
                    tram: []
                    train: []
                    ferry: []
                    Uline: []
                    metro: []
                    kirkkonummiInternal: []
                    keravaInternal: []
                }
                for dkey, dval of disrObj
                    if dkey == 'VALIDITY'
                        # the message may be active or cancelled
                        isValid = true if dval[0]['$'].status == '1'
                        # the HSL poikkeusinfo server does not have timezones in the date values,
                        # so we manually set the Finnish timezone here
                        timezone =
                            if isDstOn()
                                '+03:00'
                            else
                                '+02:00'
                        disrStartTime = new Date(dval[0]['$'].from + timezone)
                        disrEndTime = new Date(dval[0]['$'].to + timezone)
                    else if dkey == 'INFO'
                        # human-readable description
                        englishElemIdx = 0
                        for textElem, elemIdx in dval[0]['TEXT']
                            # language attributes fi, se, en
                            englishElemIdx = elemIdx if textElem['$'].lang == 'en'
                        message = dval[0]['TEXT'][englishElemIdx]['_'].trim()
                        # key '_' means the XML element content (normal text)
                    else if dkey == 'TARGETS'
                        targets = dval[0] # only one TARGETS element
                        # TARGETS contains either a LINETYPE or 1-N LINE elements
                        if targets.LINETYPE?
                            # all lines within the area/scope/type affected
                            # assume there is only one LINETYPE element
                            # linetype numeric id that maps to regions/categories
                            linetype = targets.LINETYPE[0]['$'].id
                            if linetype of DISRUPTION_API_LINETYPES
                                linesByArea[DISRUPTION_API_LINETYPES[linetype]].push 'all'
                            else if linetype == '14' # all areas
                                for area, lines of linesByArea
                                    lines.push 'all'
                        else if targets.LINE?
                            # list of line elements that specify single affected lines
                            # parsed XML: $ for attributes, _ for textual element content
                            for lineElem in targets.LINE
                                if lineElem['$'].linetype of DISRUPTION_API_LINETYPES
                                    linesByArea[DISRUPTION_API_LINETYPES[lineElem['$'].linetype]].push lineElem['_']
                                else if lineElem['$'].linetype == '14' # all areas
                                    for area, lines of linesByArea
                                        lines.push lineElem['_']
                if isValid
                    for area, lines of linesByArea
                        findClients lines, area, message, disrStartTime, disrEndTime if lines.length > 0
    return


# Function that fetches disruption news updates from HSL servers, parses them
# and searches the database for affected clients. The clients are sent
# push notifications if necessary. The same message is only sent once to a client.
update = ->
    console.log "Fetching news and disruptions updates"
    
    # Abort all scheduled GCM message push retry attempts so that the
    # number of requests doesn't keep growing if GCM server is down
    for timeout in scheduledMessagePushes
        clearTimeout timeout
    scheduledMessagePushes = []
    
    request = https.request NEWS_URL, (response) ->
        # response from HSL server
        response.setEncoding 'utf8'
        responseData = ''
        # gather the whole response body into one string before parsing JSON
        response.on 'data', (chunk) ->
            responseData += chunk
            
        response.on 'end', ->
            # object with key nodes, its value is an array, array contains objects 
            # with key node, and that is an object with keys title, body, Lines, Main category
            try
                jsonObj = JSON.parse responseData
                parseNewsResponse jsonObj
            catch error
                console.error "JSON parse error in news response: #{ error }"
        
        response.on 'error', (err) -> console.error err
    
    request.on 'error', (err) -> console.error err
    request.end()
    
    requestDisr = http.request DISRUPTIONS_URL, (response) ->
        # response from HSL server
        response.setEncoding 'utf8' # 'ISO-8859-1' not supported
        responseData = ''
        # gather the whole response body into one string before parsing XML
        response.on 'data', (chunk) ->
            responseData += chunk
            
        response.on 'end', ->
            xml2js.parseString responseData, (err, result) ->
                if err
                    console.error "Error in parsing XML response from #{ DISRUPTIONS_URL }: " + err
                else
                    if not result.DISRUPTIONS.INFO?
                        # disruptions exist
                        parseDisruptionsResponse result
        
        response.on 'error', (err) -> console.error err
    
    requestDisr.on 'error', (err) -> console.error err
    requestDisr.end()


# Send a test message to all registered clients. Note that messages
# identical to any previously sent message are not sent to clients
# that have already received the message.
sendTestMessage = (message, lines, category) ->
    findClients lines ? ['all'], category ? 'all', message


start = ->
    console.log "Starting update fetcher, update interval #{ UPDATE_INTERVAL / 1000 }s"
    process.nextTick update
    setInterval update, UPDATE_INTERVAL

module.exports =
    start: start
    sendTestMessage: sendTestMessage

if require.main == module
    dbConnect()
        .onFulfill(start)
        .onReject ->
            process.exit 2
