# navigator-push-server
Server for pushing traffic disruption notifications to navigator clients.

# Installing and running
Install Node.js and MongoDB. Downloading and unzipping pre-compiled 
binaries could be the easiest way to get up-to-date versions.

You may need to modify your `PATH` so that you can use the commands 
without specifying the full path to the binary.

Install `coffeescript` globally (a node module): `npm install -g coffee-script`

Compile CoffeeScript to JavaScript: `coffee -c server.coffee`

Install local node modules for this project. Run in this directory: `npm install`

Start Mongo server before starting this server: `mongod`

Start this server: `node server.js`

