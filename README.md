# TevioCallModule

Shared Swift Package for Tevio voice calling across Customer, Vendor, and Courier apps.

## What it includes

- `CallManager` as the package entrypoint
- PushKit registration
- CallKit incoming call handling
- Shared incoming and active call SwiftUI screens
- Socket/backend/host adapters through protocols
- Built-in 15-second unanswered call timeout
- Optional `AgoraCallAudioEngine` when `AgoraRtcKit` is available to the consuming app
- `SocketManager` for Socket.IO-based status emit/listen flows

## Platform support

- `iOS 15+`
- `iPadOS 15+`
- `Mac Catalyst 15+`

### Mac Catalyst notes

- the package now builds for Mac Catalyst
- `CallKit` and `PushKit` integrations are disabled on Mac Catalyst because those iPhone-specific flows are not used there
- the bundled `AgoraCallAudioEngine` only uses the Agora binary when that SDK is available for the current platform
- the current `AgoraRtcEngine_iOS` package in this project does not ship a Mac Catalyst slice, so real call audio on Mac Catalyst still requires a Catalyst-compatible `CallAudioEngining` implementation

## Host app integration

1. Add `TevioCallModule` as a local package dependency.
2. Provide a backend object conforming to `CallBackendProviding`.
3. Provide a host coordinator conforming to `CallHostCoordinating`.
4. Create either:
   - `SocketManager`
   - or your own custom object conforming to `CallTransporting`
5. Create `CallManager` at app launch.
6. Call `start()` to register for VoIP pushes.
7. Forward outgoing-call actions into `startOutgoingCall(request:)`.
8. If the host already receives PushKit events itself, forward payloads into `handleIncomingPush(payload:completion:)`.

## Required app responsibilities

Your app must provide:

- a valid VoIP push payload with:
  - `thread_id`
  - `uid`
  - `agora_token` or `token`
  - `app_id`
- a backend that can:
  - start outgoing calls
  - fetch display details like `name`, `roleDescription`, and `imageURL`
- a host coordinator that can:
  - present incoming call UI in foreground
  - switch from incoming UI to active-call UI
  - dismiss call UI cleanly
  - expose whether the app is in foreground
- a socket transport that can:
  - emit call statuses
  - listen for remote call statuses for the current `thread_id`

## SocketManager

`SocketManager` is the built-in `CallTransporting` implementation.

It supports two server patterns:

1. Event-based status sync:
   - emit and listen on one shared event like `call:status-1`
   - optionally subscribe and unsubscribe with `call-subscribe` and `call-unsubscribe`

2. Channel-based status sync:
   - listen on a per-thread channel like `call:status-{threadId}`
   - this matches the older app pattern where each call thread has its own listener channel

### Event-based example

```swift
let socketManager = SocketManager(
    configuration: .init(
        socketURL: URL(string: "https://prod-notification.tevioapp.com")!,
        path: "/socket.io/",
        namespace: "/",
        headers: [:],
        connectParams: ["token": token],
        statusEventName: "call:status-1",
        subscribeEventName: "call-subscribe",
        unsubscribeEventName: "call-unsubscribe"
    )
)
```

### Channel-based example

```swift
let socketManager = SocketManager(
    configuration: .init(
        socketURL: URL(string: "https://prod-notification.tevioapp.com")!,
        connectParams: ["token": token],
        statusEventName: "call:status-1",
        statusChannelNameProvider: { threadId in
            "call:status-\(threadId)"
        },
        subscribeEventName: nil,
        unsubscribeEventName: nil
    )
)
```

### SocketManager behavior

- `connectIfNeeded()` opens the socket automatically
- `establishConnection(onConnected:)` can be called explicitly if you want to connect early
- `emit(status:threadId:)` buffers status events until the socket is connected
- `startListening(threadId:)` stores the handler and auto-resubscribes after reconnect
- `closeConnection()` marks the disconnect as manual and avoids reconnect loops
- `listen(on:)` and `removeListener(for:)` are available for app-specific socket channels outside the calling flow

## Call flow behavior

### Incoming call in foreground

- `handleIncomingPush(payload:completion:)` creates a session
- the package starts listening for remote status updates for that `thread_id`
- if the app is in foreground, the package stays on the custom in-app flow
- `presentIncomingCall(_:)` is called on your host coordinator
- the incoming SwiftUI screen is shown
- CallKit is not reported for that same foreground call, which avoids duplicate surfaces
- ringtone starts if `ringtoneURL` is configured

### Incoming call in background or on the lock screen

- `handleIncomingPush(payload:completion:)` creates a session
- CallKit is informed through `reportNewIncomingCall`
- the package starts listening for remote status updates for that `thread_id`
- if the app later returns to foreground, the host can still present the package UI as needed

### Accept flow

- tapping Accept in the incoming screen triggers `answerCurrentCall()`
- for a foreground custom call, the package answers immediately without going through `CXAnswerCallAction`
- for a background / lock-screen CallKit call, `CXAnswerCallAction` is still used
- ringtone stops
- your host coordinator is asked to prepare for answered state
- the active-call screen is presented
- the Agora audio engine is configured
- `call-accepted` is emitted so the remote side can sync the answer state
- audio joins immediately for the foreground custom flow
- audio joins when CallKit activates the audio session for the CallKit flow
- when a remote user joins, the package starts the elapsed timer and updates the active screen

### Decline flow

- tapping Decline in the incoming screen triggers `declineCurrentCall()`
- a `CXEndCallAction` is requested
- the package finalizes the call with `.declined`
- the socket emits:
  - `call-declined`
  - then `call-no-status`
- ringtone stops
- the incoming screen is dismissed
- CallKit is ended and cleared

### End active call flow

- tapping End in the active screen triggers `endCurrentCall()`
- the package finalizes with `.ended`
- the socket emits:
  - `call-ended`
  - then `call-no-status`
- the active screen is dismissed
- the Agora engine leaves the channel
- CallKit is ended and cleared only when that call was actually reported to CallKit

### Remote accept flow

- if socket status for the current `thread_id` becomes `call-accepted`
- the outgoing side moves from ringing to connecting
- the local screen stays in the package UI flow and does not redirect into CallKit

### Remote termination flow

- if socket status for the current `thread_id` becomes:
  - `call-ended`
  - `call-declined`
  - `call-not-answered`
  - `call-busy`
- the package dismisses the current call UI
- stops timers and ringtone
- leaves the Agora channel
- clears the current session
- reports the call ended to CallKit with the appropriate reason

### Unanswered flow

- the package starts a 15-second timer as soon as an incoming call is reported
- if still ringing after 15 seconds:
  - the call is ended locally
  - the incoming UI is dismissed
  - `call-not-answered` is emitted
  - `call-no-status` is emitted after it to clear remote status
  - CallKit is cleared

## Example setup

```swift
let socketManager = SocketManager(
    configuration: .init(
        socketURL: URL(string: "https://prod-notification.tevioapp.com")!,
        connectParams: ["token": token]
    )
)

let callManager = CallManager(
    transport: socketManager,
    backend: backendProvider,
    host: hostCoordinator,
    audioEngine: AgoraCallAudioEngine(),
    configuration: CallUIConfiguration(
        appName: "Tevio",
        ringtoneURL: ringtoneURL
    )
)

socketManager.establishConnection()
callManager.start()
```


## Screen data

Incoming and active screens support:

- caller name
- role / subtitle
- image URL through `CallThreadDetails.imageURL`
- status text
- native light and dark mode
- iPhone and iPad adaptive layout
- asset-based call controls

## Unanswered call behavior

The package starts a 15-second timer as soon as an incoming call is reported. If the call is still ringing at 15 seconds:

- the call is ended locally
- CallKit is cleared
- the incoming UI is dismissed
- `call-not-answered` is emitted to the remote app through `CallTransporting`
- `call-no-status` is emitted after that to clear the remote record

This timer is cancelled immediately on answer, decline, or remote termination.
