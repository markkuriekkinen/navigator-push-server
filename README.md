# navigator-push-server – single Heroku dyno version

This branch contains modifications that allow the server to run in a
single Heroku dyno. Note that Heroku will automatically shut the
server down after one hour of no HTTP requests, which means that push
messages are not sent.

For more information, see README.md in master branch.
