#!/usr/bin/env coffee

express     = require 'express'
app         = express()
bodyParser  = require 'body-parser'
xml2js      = require 'xml2js'

{dbConnect, Subscription, SentMessageHash, ValidationError} = require './db'


HTTP_PORT = process.env.HTTP_PORT ? process.env.PORT ? 8080


app.use bodyParser.json()
app.use bodyParser.urlencoded(extended: true)  # extended allows nested objects


# clients send HTTP POST to this URL in order to register for push notifications
app.post '/registerclient', (req, res) ->
    console.log "registerclient from #{ req.ip }: %j", req.body

    # client info in JSON: push client id, routes (lines)
    if req.body.registration_id? and req.body.sections? and Array.isArray(req.body.sections)
        # remove possible old client route data
        promise = Subscription.remove(clientId: req.body.registration_id).exec()
        # remove also old sent messages, which means that the messages
        # can be sent again to the client if it registers again
        SentMessageHash.remove(clientId: req.body.registration_id).exec (err) ->
            console.error err if err

        # make subscription objects (concurrently with remove operation)
        subscriptions =
            for sec in req.body.sections
                clientId: req.body.registration_id
                category:  sec.category
                line:      sec.line
                startTime: sec.startTime
                endTime:   sec.endTime

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
                    console.warn "POST data failed validation:", err
                else
                    console.error err
                    res.status(500).end()
    else
        # request POST data is invalid
        res.status(400).end()
        console.warn "invalid POST data"

# clients should be able to deregister from all push notifications
app.post '/deregisterclient', (req, res) ->
    console.log "deregisterclient from #{ req.ip }: %j", req.body

    # body should contain GCM registration_id, 
    if req.body.registration_id?
        # remove client's subscriptions from database
        Subscription.remove(clientId: req.body.registration_id).exec()
            .onFulfill ->
                # remove also old sent messages, which means that the messages
                # can be sent again to the client if it registers again
                SentMessageHash.remove(clientId: req.body.registration_id).exec (err) ->
                    console.error err if err
                res.status(200).end()
            .onReject (err) ->
                console.error err
                res.status(500).end()
    else
        # request POST data is invalid
        res.status(400).end()
        console.warn "invalid POST data"


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
