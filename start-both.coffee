#!/usr/bin/env coffee

db          = require './db'
httpServer  = require './http-server'
msgSender   = require './message-sender'

db.dbConnect()
    .onFulfill ->
        httpServer.start()
        msgSender.start()
    .onReject ->
        process.exit 2
