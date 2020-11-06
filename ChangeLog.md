# Changelog for http2-client

## Unreleased changes

## v0.10.0.0

- Export frameHttp2RawConnection to convert an RawHttp2Connection into an Http2FrameConnection.
- Add newRawHttp2ConnectionUnix to create a RawHttp2Connection from a unix domain socket.

## v0.9.0.0

- introduce ClientIO as an error-carrying IO-monad for performing http2-calls

## v0.8.0.2

- first Changelog!
- performance improvement: use `TCP_NODELAY`
- performance improvement: change stream-initialization functions to make less work under the HEADER-protection lock
