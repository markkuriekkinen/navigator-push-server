express     = require 'express'
app         = express()
bodyParser  = require 'body-parser'
xml2js      = require 'xml2js'
mongoose    = require 'mongoose'
http        = require 'http'
https       = require 'https'

# API key from Google (Don't save this in the public repo!)
GCM_PUSH_API_KEY = require('./secret_keys').GCM_PUSH_API_KEY

NEWS_URL = 'https://www.hsl.fi/en/newsApi/all'
DISRUPTIONS_URL = 'http://www.poikkeusinfo.fi/xml/v2/en'
PUSH_URL = 'https://android.googleapis.com/gcm/send'
PUSH_HOST = 'android.googleapis.com'
PUSH_URL_PATH = '/gcm/send'

mongoose.connect 'mongodb://localhost/clients', (err) ->
    if err
        console.log 'ERROR in connecting to database: ' + err
    #else
    #    mongoose.connection.db.dropDatabase() # delete old values

# Database schemas
clientSchema = mongoose.Schema {
    clientId: String  # Google Cloud Messaging register_id for the client
    
    # OLD style: these fields are supposed to be removed later. Keeping them until new version is polished.
    # array of routes the client is interested in
    helsinkiIntLines: [String] # Helsinki internal
    espooIntLines: [String]
    vantaaIntLines: [String]
    regionalLines: [String]
    trams: [String]
    trains: [String] # commuter trains
    ferries: [String] # usually only one line "lautta" (to Suomenlinna island)
    Ulines: [String] # with or without U char in the line?
    metro: [String]
    
    # NEW style
    # each section represents one vehicle in the complete route
    # (e.g, if the client must switch buses once in the route, there are two sections)
    sections: [{
        startTime: Date
        endTime: Date
        line: String
        category: String # similar to the categories as seen in the old fields above
    }]
}
messageSchema = mongoose.Schema {
    clientId: String
    message: String
    lines: [String] # line list from the original HSL message, 
    # the client is using at least one of these lines
    category: String
    sentToClient: Boolean
    clientHasRead: Boolean # currently unused
}

Client = mongoose.model 'Client', clientSchema
Message = mongoose.model 'Message', messageSchema

# Database test data
dbAddTestValues = () -> 
    c1 = new Client
            clientId: 1
            helsinkiIntLines: ['20', '14']
            sections: [{
                startTime: new Date()
                endTime: new Date(new Date().getTime() + 30*60000)
                line: '14'
                category: 'helsinkiIntLines'
            }]
    c2 = new Client
            clientId: 2
            espooIntLines: ['11']
    c3 = new Client
            clientId: 3
            trams: ['4']
    c1.save (err) -> console.log err if err
    #c2.save (err) -> console.log err if err
    #c3.save (err) -> console.log err if err

#dbAddTestValues()


# clients send HTTP POST to this URL in order to register for push notifications
app.post '/registerclient', (req, res) ->
    # client info in JSON: push client id, routes (lines)
    console.log(req.body) # test print
    if req.body.registration_id? and req.body.sections? and Array.isArray(req.body.sections)
        # remove possible old client route data
        Client.remove { clientId: req.body.registration_id }, ->
        # create a client in database
        c = new Client
                clientId: req.body.registration_id
                sections: req.body.sections # TODO validate request req.body.sections format?
                
        c.save (err) -> console.log err if err
        res.status(200).end()
    else
        # request POST data is invalid
        res.status(400).end()
    
# clients should be able to deregister from all push notifications
app.post '/unregisterclient', (req, res) ->
    # body should contain GCM registration_id, 
    if req.body.registration_id?
        # remove client from database
        Client.remove { clientId: req.body.registration_id }, ->
        Message.remove { clientId: req.body.registration_id }, ->
        
        res.status(200).end()
    else
        # request POST data is invalid
        res.status(400).end()

# Push a message to the client. msgId is Message._id value in our message database.
pushToClient = (msgId) ->
    # Send HTTP POST request to the GCM push server that will then send it to the client
    # http://developer.android.com/google/gcm/server-ref.html
    options = 
        hostname: PUSH_HOST
        path: PUSH_URL_PATH
        method: 'POST'
        headers: 
            'Authorization': "key=#{ GCM_PUSH_API_KEY }"
            'Content-Type': 'application/json'
            
    Message.findById msgId, (err, msg) ->
        if err
            console.log err
            return
        else if msg == null
            console.log "pushToClient: message not found (id #{ msgId })"
            return
        postData = 
            registration_ids: [msg.clientId] # The clientId is used by GCM to identify the client device.
            time_to_live: 60 * 60 * 24 # TODO could use time values from the client, set time_to_live till the end of the journey
            #dry_run: true # TESTING, no message sent to client device, TODO turn off
            data: # payload to client, data values should be strings
                disruption_message: msg.message
                disruption_lines: msg.lines.join() # array to comma-separated string
                disruption_category: msg.category
        request = https.request options, (response) ->
            # response from GCM push server
            response.setEncoding 'utf8'
            responseData = ''
            # gather the whole response body into one string before parsing JSON
            response.on 'data', (chunk) ->
                responseData += chunk
                
            response.on 'end', ->
                console.log responseData # TODO test
                if response.statusCode == 401
                    console.log "pushToClient: GCM auth error 401"
                else if response.statusCode == 400
                    console.log "pushToClient: GCM bad request JSON error"
                else if 500 <= response.statusCode <= 599
                    console.log "pushToClient: GCM server error, could retry later but retry not implemented"
                else if response.statusCode == 200
                    # success, but nonetheless there may be errors in delivering messages to clients
                    jsonObj = JSON.parse responseData
                    if jsonObj.failure > 0 or jsonObj.canonical_ids > 0
                        # there were some problems
                        for resObj in jsonObj.results
                            if resObj.message_id? and resObj.registration_id?
                                # must replace the client registration id with the new resObj id (canonical id)
                                # modify database
                                Client.update { clientId: msg.clientId }, 
                                        { clientId: resObj.registration_id }, 
                                        (err, numberAffected, rawResponse) -> console.log err if err
                                Message.update { clientId: msg.clientId }, 
                                        { clientId: resObj.registration_id }, 
                                        (err, numberAffected, rawResponse) -> console.log err if err
                                # TODO resend push?
                            else if resObj.error?
                                if resObj.error == 'Unavailable'
                                    console.log "pushToClient: GCM server unavailable, could retry later but retry not implemented"
                                else if resObj.error == 'NotRegistered'
                                    console.log "pushToClient: GCM client not registered, removing client from database"
                                    Client.remove { clientId: msg.clientId }, (err) -> console.log err if err
                                    Message.remove { clientId: msg.clientId }, (err) -> console.log err if err
                                else
                                    console.log "pushToClient: GCM response error: #{ resObj.error }"
                    else
                        # push message successfully sent to GCM servers, no errors
                        msg.sentToClient = true
                        msg.save (err) -> console.log "pushToClient: cannot modify message in db" if err
                    
        # write data to request body
        request.write JSON.stringify postData
        request.end()

# find clients that are using lines (given as array) in the area
findClients = (lines, areaField, message) ->
    createMessages = (err, clients) -> 
        if err
            console.log err
        else
            for client in clients # create messages to database to be sent to clients later
                msg = new Message
                        clientId: client.clientId
                        message: message
                        lines: lines
                        category: areaField # TODO areaField is not very human-readable (should it be?)
                        sentToClient: false
                        clientHasRead: false
                msg.save (err, savedMsg) -> 
                    if err
                        console.log err
                    else
                        pushToClient savedMsg.id

    if lines[0] == 'all'
        # find clients that are using any line in the area
        #Client.where(areaField).ne(null).exec createMessages # OLD SCHEMA
        Client.find "sections.category": areaField, createMessages  # TODO check areaField, must use the same kind of strings everywhere ("helsinkiInt", "helsinkiInternal" ...)
    else
        # find clients that are using at least one of the lines in the area
        #Client.where(areaField).in(lines).exec createMessages  # for OLD client schema
        Client.find "sections.line": lines, createMessages

# newsObj is the JS object parsed from the HSL news response
parseNewsResponse = (newsObj) -> 
    for node in newsObj.nodes
        node = node.node
        lines = node.Lines.split ','
        cat = node['Main category']
        if cat == 'Helsinki internal bus'
            findClients lines, 'helsinkiIntLines', node.title
        else if cat == 'Espoo internal bus'
            findClients lines, 'espooIntLines', node.title
        else if cat == 'Vantaa internal bus'
            findClients lines, 'vantaaIntLines', node.title
        else if cat.lastIndexOf('Regional', 0) == 0 # cat.startsWith("Regional")
            findClients lines, 'regionalLines', node.title
        else if cat == 'Tram'
            findClients lines, 'trams', node.title
        else if cat == 'Commuter train'
            findClients lines, 'trains', node.title
        else if cat == 'Ferry'
            findClients lines, 'ferries', node.title
        else if cat == 'U line'
            findClients lines, 'Ulines', node.title
        else
            console.log "parseNewsResponse: unknown Main category: #{ cat }"
            # Sipoo internal line
        
DISRUPTION_API_LINETYPES = 
    '1': 'helsinkiIntLines'
    '2': 'trams'
    '3': 'espooIntLines'
    '4': 'vantaaIntLines'
    '5': 'regionalLines'
    '6': 'metro'
    '7': 'ferries'
    '12': 'trains'
    #'14': 'all'

parseDisruptionsResponse = (disrObj) ->
    # TODO validity time stamps are not being used yet
    # HSL API description in Finnish (no pdf in English)
    # http://developer.reittiopas.fi/media/Poikkeusinfo_XML_rajapinta_V2_2_01.pdf
    for key, value of disrObj.DISRUPTIONS
        if key == '$' # XML attributes for root element DISRUPTIONS
        
        else if key == 'DISRUPTION'
            for disrObj in value
                isValid = false
                message = ''
                linesByArea = {
                    helsinkiIntLines: []
                    espooIntLines: []
                    vantaaIntLines: []
                    regionalLines: []
                    trams: []
                    trains: []
                    ferries: []
                    Ulines: []
                    metro: []
                }
                for dkey, dval of disrObj
                    if dkey == 'VALIDITY'
                        isValid = true if dval[0]['$'].status == '1'
                        # .from, .to
                    else if dkey == 'INFO'
                        message = dval[0]['TEXT'][0]['_'].trim()
                    else if dkey == 'TARGETS'
                        targets = dval[0] # only one TARGETS element
                        if targets.LINETYPE?
                            # all lines within the area/scope/type affected
                            linetype = targets.LINETYPE[0]['$'].id
                            if linetype of DISRUPTION_API_LINETYPES
                                linesByArea[DISRUPTION_API_LINETYPES[linetype]].push 'all'
                            #else if linetype == '14' # all areas
                            
                        else if targets.LINE?
                            for lineElem in targets.LINE
                                if lineElem['$'].linetype of DISRUPTION_API_LINETYPES
                                    linesByArea[DISRUPTION_API_LINETYPES[lineElem['$'].linetype]].push lineElem['_']
                                #else if lineElem['$'].linetype == '14' # all areas
                                
                    #else if dkey == '$' # xml attributes
                    
                if isValid
                    for area, lines of linesByArea
                        findClients lines, area, message if lines.length > 0
                    

setInterval( ->
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
            jsonObj = JSON.parse responseData
            parseNewsResponse jsonObj
            
    
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
                    console.log "Error in parsing XML response from #{ DISRUPTIONS_URL }: " + err
                else
                    if not result.DISRUPTIONS.INFO?
                        # disruptions exist
                        parseDisruptionsResponse result
            
    requestDisr.end()
, 3000)

port = 8080
console.log "Listening on port #{ port }"
app.listen port

