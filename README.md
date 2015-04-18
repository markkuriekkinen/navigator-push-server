# navigator-push-server

Server for pushing traffic disruption notifications to navigator
clients.

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


# Heroku deployment

TODO: sleeping web dyno note

1.  `heroku login`
2.  Create Heroku application: `heroku apps:create --region eu`
3.  Add [MongoLab][] plugin: `heroku addons:add mongolab`
    (see [MongoLab documentation][] for more information)
4.  Set Google Cloud Messaging API key: `heroku config:set GCM_PUSH_API_KEY=...`
5.  `git push heroku master`
6.  `heroku ps:scale web=1 worker=1`


[MongoLab]: https://addons.heroku.com/mongolab
[MongoLab documentation]: https://devcenter.heroku.com/articles/mongolab
