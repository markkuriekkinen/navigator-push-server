#!/usr/bin/env coffee

express     = require 'express'
app         = express()
bodyParser  = require 'body-parser'
xml2js      = require 'xml2js'

{dbConnect, Subscription, ValidationError} = require './db'


HTTP_PORT = process.env.HTTP_PORT ? 8080


app.use bodyParser.json()
app.use bodyParser.urlencoded(extended: true)  # extended allows nested objects


# clients send HTTP POST to this URL in order to register for push notifications
app.post '/registerclient', (req, res) ->
    # client info in JSON: push client id, routes (lines)
    if req.body.registration_id? and req.body.sections? and Array.isArray(req.body.sections)
        # remove possible old client route data
        promise = Subscription.remove(clientId: req.body.registration_id).exec()

        # make subscription objects (concurrently with remove operation)
        subscriptions =
            for sec in req.body.sections
                doc = { clientId: req.body.registration_id }
                for k,v of sec
                    doc[k] = v
                doc

        promise
            .then ->
                # create subscriptions in database
                Subscription.create subscriptions
            .onFulfill ->
                res.status(200).end()
            .onReject (err) ->
                if err instanceof ValidationError
                    # request POST data failed validation
                    res.status(400).end()
                else
                    console.error err
                    res.status(500).end()
    else
        # request POST data is invalid
        res.status(400).end()

# clients should be able to deregister from all push notifications
app.post '/deregisterclient', (req, res) ->
    # body should contain GCM registration_id, 
    if req.body.registration_id?
        # remove client's subscriptions from database
        Subscription.remove(clientId: req.body.registration_id).exec()
            .onFulfill ->
                res.status(200).end()
            .onReject (err) ->
                console.error err
                res.status(500).end()
    else
        # request POST data is invalid
        res.status(400).end()


start = ->
    console.log "Listening on port #{ HTTP_PORT }"
    app.listen HTTP_PORT

module.exports =
    start: start

if require.main == module
    dbConnect()
        .onFulfill(start)
        .onReject ->
            process.exit 2
