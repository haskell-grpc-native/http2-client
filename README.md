# http2-client

An native-Haskell HTTP2 client library based on `http2` and `tls` packages.

## TODO

* a Simple module for simple and sane behaviors
* change location where to consume/add-credit to expose some knobs to flow-control
* modify client SETTINGS only when acknowledged
* consider a beter frame-subscription mechanism than broadcast wake-up
* consider most performant functions for HTTP2.HPACK encoding/decoding
* implement more protocol checks on server errors
  * unwanted frames on idle/closed streams
  * increasing IDs only
  * invalid settings
  * invalid window in flow-control
  * invalid frame sizes
  * data-consumed out of flow-control limits
  * authority of push promise https://tools.ietf.org/html/draft-ietf-httpbis-http2-17#section-10.1
  * ...
* decide on a proper way to handle/throw exceptions
* handle PRIORITY
