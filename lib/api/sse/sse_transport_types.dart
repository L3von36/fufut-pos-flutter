/// Shared SSE transport types. Platform implementations are selected by
/// `sse_transport.dart`'s conditional export:
///  * web    → `sse_transport_web.dart` (browser EventSource — cookies flow
///             automatically, exactly like the PWA's `useSSE.js`);
///  * native → `sse_transport_io.dart` (streamed `package:http` GET carrying
///             the `session` cookie header, same as every other API call).
library;

/// A live server-sent-events connection. Implementations hand every named
/// event to [SseTransportConfig.onEvent] and signal state through
/// [SseTransportConfig.onOpen] / [SseTransportConfig.onError].
///
/// Contract: after [SseTransportConfig.onError] fires the transport is
/// finished — callers must [SseTransport.close] it and open a fresh one if
/// they still want the stream. The web implementation additionally kills the
/// browser's built-in auto-reconnect before reporting the error, so the
/// channel's own backoff ladder is the single source of retries (otherwise
/// EventSource and the channel would race each other into a double
/// connection).
abstract class SseTransport {
  Future<void> close();
}

class SseTransportConfig {
  /// Absolute (`https://…/api/events/kitchen`) or, on web, relative
  /// (`/api/events/kitchen`) — EventSource accepts both.
  final Uri url;

  /// Extra request headers. Only honored by the native (IO) transport — the
  /// browser's EventSource cannot set headers, it sends its own cookies.
  final Map<String, String> headers;

  /// Event names to listen for. The web transport must register a listener
  /// per name up front (a DOM EventSource only dispatches to listeners
  /// registered for that exact event type); the IO transport ignores this —
  /// its parser surfaces whatever the wire carries.
  final Set<String> eventNames;

  final void Function() onOpen;
  final void Function(Object error) onError;
  final void Function(String event, String data) onEvent;

  const SseTransportConfig({
    required this.url,
    this.headers = const {},
    this.eventNames = const {},
    required this.onOpen,
    required this.onError,
    required this.onEvent,
  });
}
