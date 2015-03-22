express = require 'express'
app = express()
bodyParser = require 'body-parser'
mongoose = require 'mongoose'
http = require 'http'
https = require 'https'

NEWS_URL = 'https://www.hsl.fi/en/newsApi/all'
DISRUPTIONS_URL = 'http://www.poikkeusinfo.fi/xml/v3'

mongoose.connect 'mongodb://localhost/clients', (err) ->
    console.log 'ERROR in connecting to database: ' + err if err
# TODO define schema for keeping clients
clientSchema = mongoose.Schema {
    clientId: String  # Google Cloud Messaging register_id for the client
    routes: [String] # array of routes the client is interested in
}

Client = mongoose.model 'Client', clientSchema

app.post '/registerclient', (req, res) ->
    # client info in JSON: push client id, routes (lines), Helsinki/Espoo/Vantaa internal/Regional
    console.log(req.body)
    

# TODO poll poikkeusinfo etc every minute/second
# TODO push to clients if necessary by using Google Cloud Messaging
setInterval( ->
    request = https.request NEWS_URL, (response) ->
        # response from HSL server
        console.log('STATUS: ' + response.statusCode)
        response.setEncoding 'utf8'
        responseData = ''
        # gather the whole response body into one string before parsing JSON
        response.on 'data', (chunk) ->
            responseData += chunk
            
        response.on 'end', ->
            #console.log('BODY: ' + responseData)
            # object with key nodes, its value is an array, array contains objects 
            # with key node, and that is an object with keys title, body, Lines, Main category
            jsonObj = JSON.parse responseData
            console.log(jsonObj.nodes.length)
            
    
    request.end()
    requestDisr = http.request DISRUPTIONS_URL, (response) ->
        # response from HSL server
        console.log('STATUS: ' + response.statusCode)
        response.setEncoding 'utf8'
        responseData = ''
        # gather the whole response body into one string before parsing XML
        response.on 'data', (chunk) ->
            responseData += chunk
            
        response.on 'end', ->
            #console.log('BODY: ' + responseData)
            # TODO parse XML
            
    
    requestDisr.end()
, 5000)


console.log("Listening on port 8080")
app.listen 8080

