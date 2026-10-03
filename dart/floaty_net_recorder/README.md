# floaty_net_recorder

Dev-only, full-fidelity HTTP recorder for Dart and Flutter apps. Streams every
request to FloatyTerm's loopback relay, where `floaty net export` turns it into
JSON, HAR or Markdown — with a runnable `curl` per request.

**Never ship this.** It records `Authorization` headers, cookies and full
bodies, unredacted, so that the export can replay the request.

## Install

```yaml
dev_dependencies:
  floaty_net_recorder:
    path: ../FloatyTerm/dart/floaty_net_recorder
```

No transitive dependencies — it is `dart:io` and `dart:async` only.

## Use

```dart
void main() {
  // The body of an assert is stripped from release builds, so the recorder
  // cannot reach production by accident.
  assert(() { FloatyNet.start(label: 'admin-app'); return true; }());
  runApp(const MyApp());
}
```

The `label` must match the terminal's:

```bash
floaty net start --label admin-app
# … drive the app …
floaty net stop
floaty net export --format md
```

Nothing is written unless a session is recording, so leaving it installed in a
dev build costs one rejected POST per request.

### Context — what the VM profiler cannot know

```dart
FloatyNet.tag('screen', 'checkout');
FloatyNet.tag('action', 'tapped Pay');
```

Every request recorded after this carries those tags, and the export leads each
detail section with them.

### Traffic no HttpClient owns

```dart
FloatyNet.record({
  'method': 'GRPC', 'url': 'orders.Create', 'status': 200, 'ms': 12,
  'req_body': request.writeToJson(),
});
```

### When it does not fire

The event is emitted when the **response body stream ends**. A caller that
never drains the response never produces an event — the same rule the response
itself follows. Set `FloatyNet.debug = true` to print what the recorder is
capturing and sending; a recorder that cannot reach the relay is otherwise
indistinguishable from one with nothing to send.

## Do you even need this?

Often not. `floaty net start --vm <uri>` records all `dart:io` traffic with **no
code in the app at all**, using the same VM Service profiler as DevTools. Reach
for this package when that cannot work:

- a release/profile build on a real device (no VM Service),
- user-action context,
- traffic outside `dart:io`.

Both can run at once; each event records its `source`.

## Coverage

Wraps `HttpClient` through `HttpOverrides`, so it sees `package:http`,
Dio's default adapter, and anything else built on `dart:io` — and it chains to
any overrides your app already installed rather than replacing them. It does
not see Flutter web (no `dart:io`) or native platform-channel traffic.
