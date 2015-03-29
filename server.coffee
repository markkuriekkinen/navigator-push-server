express     = require 'express'
app         = express()
bodyParser  = require 'body-parser'
xml2js      = require 'xml2js'
mongoose    = require 'mongoose'
http        = require 'http'
https       = require 'https'

NEWS_URL = 'https://www.hsl.fi/en/newsApi/all'
DISRUPTIONS_URL = 'http://www.poikkeusinfo.fi/xml/v2/en'

mongoose.connect 'mongodb://localhost/clients', (err) ->
    if err
        console.log 'ERROR in connecting to database: ' + err
    #else
    #    mongoose.connection.db.dropDatabase() # delete old values

clientSchema = mongoose.Schema {
    clientId: String  # Google Cloud Messaging register_id for the client
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
}
messageSchema = mongoose.Schema {
    clientId: String
    message: String
    lines: [String]
    category: String
    sentToClient: Boolean
    clientHasRead: Boolean
}

Client = mongoose.model 'Client', clientSchema
Message = mongoose.model 'Message', messageSchema

dbAddTestValues = () -> 
    c1 = new Client
            clientId: 1
            helsinkiIntLines: ['20', '14']
    c2 = new Client
            clientId: 2
            espooIntLines: ['11']
    c3 = new Client
            clientId: 3
            trams: ['4']
    c1.save (err) -> console.log err if err
    c2.save (err) -> console.log err if err
    c3.save (err) -> console.log err if err

dbAddTestValues()



app.post '/registerclient', (req, res) ->
    # client info in JSON: push client id, routes (lines), Helsinki/Espoo/Vantaa internal/Regional
    console.log(req.body)
    # { helsinkiInt: [1, 2], regional: [6,7] }
    

# find clients that are using lines (given as array) in the area
findClients = (lines, areaField, message) ->
    createMessages = (err, results) -> 
        if err
            console.log err
        else
            for client in results # create messages to database to be sent to clients later
                msg = new Message
                        clientId: client.clientId
                        message: message
                        lines: lines.join()
                        category: areaField # TODO areaField is not very human-readable
                        sentToClient: false
                        clientHasRead: false
                msg.save (err) -> console.log err if err

    if lines[0] == 'all'
        # find clients that are using any line in the area
        Client.where(areaField).ne(null).exec createMessages
    else
        # find clients that are using at least one of the lines in the area
        Client.where(areaField).in(lines).exec createMessages

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
            console.log "parseNewsResponse unknown Main category: #{ cat }"
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
                    

# TODO push to clients if necessary by using Google Cloud Messaging
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
                    console.log err
                else
                    if not result.DISRUPTIONS.INFO?
                        # disruptions exist
                        parseDisruptionsResponse result
            
    
    requestDisr.end()
, 3000)


console.log("Listening on port 8080")
app.listen 8080

