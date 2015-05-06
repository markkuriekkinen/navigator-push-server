# navigator-push-server

Server for pushing traffic disruption notifications to navigator
clients (<https://github.com/jannesuo/navigator-proto>).

The server consists of two parts: HTTP server and message sender. They
can be run in the same process or as two separate applications that
share the database. In the latter case, it is possible to run multiple
HTTP servers. However, there should be only one message sender
instance.


# Installing and running

Install Node.js and MongoDB. Downloading and unzipping pre-compiled 
binaries could be the easiest way to get up-to-date versions.

You may need to modify your `PATH` so that you can use the commands 
without specifying the full path to the binary.

Install `coffeescript` globally (a node module): `npm install -g coffee-script`

Install local node modules for this project. Run in this directory: `npm install`

Start Mongo server before starting this server: `mongod`

You can start HTTP server and message sender either separately or
together in a single process.

* Start separately: `coffee http-server.coffee`, `coffee message-sender.coffee`
* Start together: `coffee start-both.coffee`

If you want to compile CoffeeScript to JavaScript, use the command
`coffee -c *.coffee`. Then, start the program or programs using
commands of the form `node <file>.js` instead of the coffee commands
above.

## Environment variables

*  `MONGODB_URI` (optional): MongoDB URI. Not needed with MongoLab
   Heroku plugin.
*  `HTTP_PORT` (HTTP server only, optional): HTTP server port. Not
   needed with Heroku.
*  `UPDATE_INTERVAL` (message sender only, optional): The interval in
   milliseconds for fetching updates from HSL servers.
*  `GCM_PUSH_API_KEY` (message sender only, required): Google Cloud
   Messaging API key.
*  `TEST_PUSH` (HTTP server only, optional): if set to anything except
   `false`, `no`, `off`, or `0`, enable sending test messages. See
   below.

## Sending test messages

The HTTP server has a test message sending functionality, which can
be enabled by setting the environment variable `TEST_PUSH` to anything
except `false`, `no`, `off`, or `0`. To send a test message, send a
HTTP POST request to the path `/send-test-message` with the following
fields in the body as either form data or JSON:

*  `msg`: message
*  `category` (optional): category of the lines in text form
*  `lines` (optional): lines (in JSON as array; in form data in the
   form `lines[]=11&lines[]=22&...`)

Note that duplicate message detection works as with normal messages:
Messages identical to any previously sent message are not sent to
clients that have already received the message.


# Heroku deployment

The server can be deployed to Heroku as described below. However, note
that if there is only one 1X or 2X web dyno, Heroku puts it into sleep
mode after 1 hour of no HTTP requests. As a consequence, it is not
possible to use `start-both.coffee` in production with Heroku, because
there can be only one message sender instance, and if it goes to
sleep, messages are not sent. For testing and development, there is a
separate branch, `shared-heroku-dyno`, with Procfile that runs
`start-both.coffee` in a single shared dyno that can go to sleep.

Deployment instructions:

1.  `heroku login`
2.  Create Heroku application: `heroku apps:create --region eu`
3.  Add [MongoLab][] plugin: `heroku addons:add mongolab`
    (see [MongoLab documentation][] for more information)
4.  Set Google Cloud Messaging API key: `heroku config:set GCM_PUSH_API_KEY=...`
5.  `git push heroku master`
6.  `heroku ps:scale web=1 worker=1` (there can be many web dynos, but
    there should be only one worker dyno)


[MongoLab]: https://addons.heroku.com/mongolab
[MongoLab documentation]: https://devcenter.heroku.com/articles/mongolab

# Terms of use
All the source code in this repository is licensed with MIT open source
license. The software code is provided "as is" and is free for use in
any open source applications.

