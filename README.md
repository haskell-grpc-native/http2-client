# http2-client

An native-Haskell HTTP2 client library based on `http2` and `tls` packages.

## Things that will likely change the API

I think the fundamental are right but the following needs tweaking:

- onPushPromise handlers will be requested when opening new streams rather than
  when opening new connections
- function to reset a stream will likely be blocking until a RST/EndStream is
  received so that all DATA frames are accounted for in the flow-control system
- need a way to hook custom flow-control algorithms

## Support of the HTTP2 standard

The current implementation follows the HTTP2 standard except for the following:
- does not handle `PRIORITY`
- does not handle `SETTINGS_MAX_HEADER_LIST_SIZE`
  * it's unclear to me whether this limitation is applied per frame or in total
  * the accounting is done before compression with 32 extra bytes per header
- does not implement most of the checks that should trigger protocol errors
  * unwanted frames on idle/closed streams
  * increasing IDs only
  * invalid settings
  * invalid window in flow-control
  * invalid frame sizes
  * data-consumed out of flow-control limits
  * authority of push promise https://tools.ietf.org/html/draft-ietf-httpbis-http2-17#section-10.1
  * ...

## TODO

- modify client SETTINGS only when acknowledged
  * currently make use of new client settings before the server has time to
    know them, this can lead to errors due to inconsistent view of settings
    between sender/receiver
- consider a beter frame-subscription mechanism than broadcast wake-up
  * current system of dupChan everything is prone to errors and may be costly
    CPU/latency-wise if the concurrency is high
- consider most performant functions for HTTP2.HPACK encoding/decoding
  * currently using naive function 'Network.HPACK.encodeHeader'
- consider using a typeclass or a way to change the frame client
- we need a story for IO exceptions
- we need a story for instrumentation
