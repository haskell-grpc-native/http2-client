# http2-client

An native-Haskell HTTP2 client library based on `http2` and `tls` packages.

Hackage: https://hackage.haskell.org/package/http2-client .

## General design

HTTP2 is a heavy protocol. HTTP2 features pipelining, query and responses
interleaving, server-pushes, pings, stateful compression and flow-control,
priorization etc. This library aims at exposing these features so that library
users can integrate `http2-client` in a variety of applications. In short, we'd
like to expose as many HTTP2 features as possible. Hence, the `http2-client`
programming interface can feel low-level for users with expectations to get an
API as simple as in HTTP1.x.

Exposing most HTTP2 primitives as a drawback: the library allows a client to
behave abnormally with-respect to the HTTP2 spec. That said, we try to prevent
notoriously-difficult errors such as concurrency bugs by coercing users with
the programming API following Haskell's philosophy to factor-out errors at
compile time. For instance, a client can send DATA frames on a stream after
closing it with a RST (easy to spot). However, a multi-threaded client will not
be able to interleave DATA frames with HEADERS and their CONTINUATIONs and the
locking required to achieve this invariant is hidden (hard to implement).

Following this philosophy, we prefer to offer a somewhat low-level API in
`Network.HTTP2.Client` and higher-level APIs (with a different performance
trade-off) in `Network.HTTP2.Client.Helpers`. For instance,
`Network.HTTP2.Client.Helpers.waitStream` will consume a whole stream in memory
before returning whereas `Network.HTTP2.Client` users will have to take chunks
one at a time. We look forward to the linear arrows extension for improving the
library design.

### Versioning and GHC support

We try to follow https://pvp.haskell.org/ as `a.b.c.d` with the caveat that if
`a=0` then we are still slightly unhappy with some APIs and we'll break things
arbitrarily.

We aim at supporting GHC-8.x, contributions to support GHC-7.x are welcome.

### Installation

This package is a standard `Stack` project, please also refer to Stack's
documentation if you have trouble installing or using this package.  Please
also have a look at the Hackage Matrix CI:
https://matrix.hackage.haskell.org/package/http2-client .

## Usage

First, make sure you are somewhat familiar with HTTP and HTTP2 standards by
reading RFCs or Wikipedia pages. If you use the library, feel free to shoot me
an e-mail (cf. commits) or a tweet @lucasdicioccio .

### Help and examples

Please see some literate Haskell documents in the `examples/` directory.  For
a more involved usage, we currently provide a command-line example client:
`http2-client-exe` which I use as a test client and you could use to test
various flow-control parameters. This binary lives in a separate package
at https://github.com/lucasdicioccio/http2-client-exe .

The Haddocks, at https://hackage.haskell.org/package/http2-client, should have
plenty implementation details, so please have a look.  Otherwise, you can ask
help by creating an Issue on the bug-tracker.

### Opening a stream

First, you open a (TLS-protected) connection to a server and configure the
initial SETTINGS to advertise. Then you can open and consume streams. Opening
streams takes a stream-definition and expresses two sequential parts. First,
sending the HTTP headers, which reserves an increasing stream-ID with the
server. Second, you consume a stream by sending DATA chunk or receiving DATA
chunks. One thing that can prevent concurrency is if you have too many opened
streams for the server. The `http2-client` library tracks server's max
concurrency preference and will prevent you from opening too many streams.

### Sending chunked data

Sent data must be chunked according to server's preferences. A function named
`sendData` performs the chunking but this chunking could have some suboptimal
overhead if you want to repeatedly call sendData with a buffer size that is not
a multiple of the server's preferred chunk size.

### Flow control

HTTP2 mandates a flow-control system that cannot be disabled. DATA chunks
consume credit from the flow-control system. The standard defines a
flow-control context per stream plus one global per-connection. 

** Received DATA flow control ** In order to keep receiving data you need to
periodically transfer credit to the server. One transfers credit to server by
calling `_updateWindow`, which transfers locally-accumulated credit (you
accumulate credit with `addCredit`). The current implementation already follows
a "zero-sum" credit where received DATA is immediately consumed and
re-credited.  That is, if you only keep calling `_updateWindow` at some
frequency the stream will progress. You can also `_addCredit` to permit
receiving more DATA on a stream/connection (e.g., if you want to implement
something like TCP slow-start).

** Sent DATA flow control ** A server following the HTTP2 specification
strictly will kick you for sending too much data. The `http2-client` library
allows you to be more aggressive than the server allows and you have to care
for your streams. We provide an incoming flow-control context that will allow
you to call `_withdrawCredit` to wait until some credit is available. At the
time of this writing, the `sendData` function does not call `_withdrawCredit`
and we provide no equivalent. Note that the chunking and flow-control
mechanisms have interesting interactions in HTTP2 in a multi-threaded context.
Pay attention to always take credit in the per-stream flow-control context
before taking it from the global per-connection flow-control context.
Otherwise, you risk starving the global per-connection flow-control with no
guarantee that you'll be allowed to send a DATA frame.

## Settings changes

The HTTP2 RFC acknowledges the inherent race conditions that may occur when
changing SETTINGS. The `http2-client` library should be rather permissive and
accept rather than reject frames caught violating inconsistent settings once
client settings are made stricter. Conversely, the `http2-client` library tries
to enforce server-SETTINGS strictly before ACKnowledging the setting changes.
This configuration can lead to problems if the server send more-permissive
SETTINGS (e.g., allowing a large default window size -> which recredits all
streams) but if the server applies this change locally only after receiving the
client ACK. One way to be double-sure the `http2-client` library is always
strict would be to apply settings changes in two steps: settings that move in
the "stricter direction" (e.g., fewer concurrency, smaller initial window)
should be applied _before_ ACK-ing the SETTING frame. Meanwhile settings that
move in the "looser direction" (e.g., more concurrency) should be applied
_after_ ACK-ing the SETTINGS frame.

The current design apply SETTINGS:
- (client prefs) after receiving a ACK for sent SETTINGS, you get the choice to
  wait for an ACK or wait in a thread, but you must wait for an ACK to apply
  changed settings (the `_settings` function will return an IO to wait for the
  ACK and apply settings). Note that the initial SETTINGS change frame is
  waited for in a thread without library's user intervention (if you feel
  strongly against this choice, please open a bug).
- (server prefs) immediately after receiving and hence before sending ACK-SETTINGS

Fortunately, changing settings mid-stream is probably a rare behavior and the
default SETTINGS are large enough to avoid creating fatal errors before
sending/receiving the initial SETTINGS frames.

## Things that are hardcoded

A number of HTTP2 features are currently hardcoded:
- PINGs are replied-to immediately (i.e., a server could hog a connection with PINGs)
- the initial SETTINGS frame sent to the server is waited-for in a separate
  thread, settings are applied to the connection when the server ACKs the frame
- flow-control from DATA frames is decremented immediately when received (in a
  separate thread) rather than when consumed from the client
- similarly, flow-control re-increment every DATA received as soon as it is
  received

## Contributing

Contributions are welcome. As I start integrating external contribution I plan
to follow the following procedure:
- stop pushing directly into master
- develop any patch in a new branch, branched from master
- merge requests target master

Please pay attention to the following:
- avoid introducing external dependencies, especially if dependencies are not in stackage
- avoid reformatting-only merge requests
- please verify that you can `stack clean` and `stack build --pedantic`

General mindset to have during code-reviews:
- be kind
- be patient
- surpass egos and bring data if there is a disagreement

## Bugtracker

Most of the following points have their own issues on the issue tracker at
GitHub: https://github.com/lucasdicioccio/http2-client/issues .

### Things that will likely change the API

I think the fundamentals are right but the following needs tweaking:

- function to reset a stream will likely be blocking until a RST/EndStream is
  received so that all DATA frames are accounted for in the flow-control system
- need a way to hook custom flow-control algorithms

### Support of the HTTP2 standard

The current implementation follows the HTTP2 standard except for the following:
- does not handle `PRIORITY`
- does not expose padding
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
