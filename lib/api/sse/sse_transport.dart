/// SSE platform plumbing for the fufut-api event channels.
///
/// Export order matters: on web, `dart.library.io` is unavailable so the
/// EventSource implementation wins; everywhere else the streamed-http
/// implementation applies. On any other target the stub throws, which the
/// channel treats as a permanent disconnect (poll fallback carries on).
library;

export 'sse_transport_types.dart';
export 'sse_transport_stub.dart'
    if (dart.library.js_interop) 'sse_transport_web.dart'
    if (dart.library.io) 'sse_transport_io.dart';
