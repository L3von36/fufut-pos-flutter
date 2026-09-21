/// Platform-selection stub for the SSE transport.
///
/// `sse_transport.dart` conditionally replaces this file with the web
/// (EventSource) or native (streamed http) implementation. If neither
/// condition matched we are on a platform the app does not ship SSE for —
/// the channel treats the throw as a permanent disconnect and the board's
/// 15s poll keeps it honest.
library;

import 'sse_transport_types.dart';

SseTransport createSseTransport(SseTransportConfig config) =>
    throw UnsupportedError('SSE is not supported on this platform');
