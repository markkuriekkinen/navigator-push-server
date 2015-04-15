mongoose = require 'mongoose'
crypto   = require 'crypto'


# Expiration time in milliseconds for messages without end
# time. Should be larger than maximum age of typical such message.
DEFAULT_MSG_EXPIRATION = 1000*60*60*24*366

MONGODB_URI =
    process.env.MONGODB_URI ?   # user configured URI
    process.env.MONGOLAB_URI ?  # MongoDB URI of MongoLab Heroku plugin
    process.env.MONGOHQ_URI ?  # MongoDB URI of Compose MongoDB Heroku plugin
    'mongodb://localhost/clients'


connect = (cb) ->
    mongoose.connect MONGODB_URI
    promise = new mongoose.Promise(cb)
    db = mongoose.connection
    db.on 'error', (err) ->
        console.error 'ERROR in connecting to database: ' + err
        promise.reject err
    db.on 'open', promise.fulfill.bind(promise)
    promise


subscriptionSchema = mongoose.Schema
    clientId:  # Google Cloud Messaging register_id for the client
        type: String
        index: true
        required: true
        minLength: 1
    
    category:
        type: String
        required: true
    line:
        type: String
        required: true
    startTime:
        type: Date
        required: true
    endTime:
        type: Date
        expires: 60*30  # autoremove after this many seconds after endTime
        required: true

subscriptionSchema.index
    category: 1
    line: 1
    startTime: 1
    endTime: 1

subscriptionSchema.pre 'validate', (next) ->
    now = Date.now()
    min = now - 1000*60*60*24*2
    max = now + 1000*60*60*24*2

    unless @startTime > min
        @invalidate "startTime", "startTime invalid or too far in the past", @startTime
    unless @endTime < max
        @invalidate "endTime", "endTime invalid or too far in the future", @endTime
    unless @startTime <= @endTime
        @invalidate "startTime", "startTime invalid or > endTime", @startTime
        @invalidate "endTime", "endTime invalid or < startTime", @endTime
    next()


sentMessageHashSchema = mongoose.Schema {
    _id:  # binary sha1 hash of client id and message data
        type: Buffer
        unique: true
    expirationTime:  # MongoDB will autoremove this after this time
        type: Date
        # delete after this many seconds after expirationTime (should
        # be >0 to guard against clock skew and other weirdness)
        expires: 60*60*24
}

# Calculate message hash and store it in the database. Return
# promise. If the hash is not yet in the database, the hash document
# is passed to promise and callback as argument. If the hash is
# already in the DB, the argument is null.
sentMessageHashSchema.statics.storeHash = (message, callback) ->
    # calculate hash
    lines = message.lines
    lines.sort()
    sha1 = crypto.createHash 'sha1'
    sha1.update message.clientId, 'utf8'
    sha1.update "\0", 'ascii'
    for line in lines
        sha1.update line, 'utf8'
        sha1.update "\0", 'ascii'
    sha1.update message.category, 'utf8'
    sha1.update "\0", 'ascii'
    sha1.update message.message, 'utf8'
    hash = sha1.digest()

    # try to store, handle duplicates
    promise = new mongoose.Promise(callback)
    @create(
        {
            _id: hash
            expirationTime:
                message.validThrough ? (Date.now() + DEFAULT_MSG_EXPIRATION)
        },
        (err, hashDoc) ->
            if err
                # MongoDB returns error code 11000 (or possibly 11001,
                # it's poorly documented) when trying to insert
                # duplicate keys. If this error occurs, the message
                # has already been sent.
                if err.code in [11000, 11001]
                    promise.fulfill null
                else
                    promise.reject err
            else
                promise.fulfill hashDoc
    )
    promise


module.exports =
    dbConnect: connect
    Subscription: mongoose.model 'Subscription', subscriptionSchema
    SentMessageHash: mongoose.model 'SentMessageHash', sentMessageHashSchema
    ValidationError: mongoose.Error.ValidationError
