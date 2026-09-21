# Tester Channel — iOS client

One private conversation between a company and each of its testers, as a SwiftUI
view you drop into a screen you already have.

Open source, like the web client (D15), because this is the file your team reads
before agreeing to ship it. No dependencies: Foundation and SwiftUI, iOS 16+.

## Install

Either point Swift Package Manager at this directory:

```swift
.package(path: "../sdk/ios")            // or a URL, once this repo is somewhere
```

…or drag `Sources/TesterChannel/` into your target. It is seven files and there
is nothing clever in the build: `Generated/Strings.swift` is checked in rather
than produced by an SPM plugin, so what you compile is what you can read.

## The three parties

The panel never holds the HMAC secret. It cannot: anyone with it can impersonate
any tester of your app.

1. **Your backend** holds the secret and exposes an endpoint, authenticated by
   your own session, that returns `HMAC-SHA256(userId, hmacSecret)` in hex for
   *the logged-in user*. Never for a user id that arrived in the request.
2. **Your app** asks that endpoint for the hash and hands both to `identify`.
3. **Tester Channel** verifies the pair and returns a session.

`userId` must be your own immutable internal id — never an email address. An
address changes, and this id is what a tester's entire history hangs off: change
it and they are a different person with an empty thread. Names and addresses go
in `traits`.

## Use

```swift
import TesterChannel

@MainActor
final class FeedbackModel: ObservableObject {
    let channel = TesterChannelClient(
        publishableKey: "pk_live_…",          // ships in your binary; not a secret
        baseUrl: "https://your-deployment.example.com"
    )

    func start(user: User) async throws {
        let hash = try await myBackend.testerChannelHash(for: user.id)
        try await channel.identify(
            userId: user.id,
            userHash: hash,
            traits: ["name": user.fullName, "plan": user.plan],
            build: Bundle.main.version
        )
    }
}
```

```swift
struct FeedbackScreen: View {
    @StateObject private var model = FeedbackModel()

    var body: some View {
        TesterChannelView(client: model.channel)
            .padding()
            .task { try? await model.start(user: session.user) }
    }
}
```

Give the view a height if the container does not already bound it. A thread is
permanent and unbounded, so it will fill whatever it is given.

Call `reset()` when somebody signs out, or the next person on the device inherits
the thread.

## A badge while the panel is shut

`unreadCount` is the service's own number, not a guess, and it keeps working when
the view is not on screen — the client drops to polling one integer every thirty
seconds instead of the conversation.

```swift
TabView {
    FeedbackScreen()
        .badge(model.channel.unreadCount)      // @Published, so this updates
}
```

Hiding the view is not signing out. `TesterChannelView` handles that itself via
`onAppear`/`onDisappear`; you only need `setVisible(_:)` if you are drawing your
own interface.

## Things that will bite you otherwise

- **A replayed send answers 200 with `duplicate: true`, and a second answer to a
  card answers 409 `already_answered`. Both mean the write is recorded.** The
  client already treats them as success; if you call the endpoints yourself,
  match that or you will double-post, or show somebody a failure for a tap that
  worked.
- **Branch on `code`, never on the message.** `TesterChannelError` carries
  `status` and `code`; the prose is written for a developer reading a log and is
  reworded whenever somebody finds a better sentence.
- **A 401 means identify again**, which costs a round trip to your backend for a
  fresh hash. The session carries no expiry, so store it and expect this rarely —
  but do expect it.
- **A 403 `removed` is final.** An operator has taken that tester out of the
  programme. The panel stops offering to write and keeps showing the
  conversation, because removal is not erasure.
- **Four images to a message**, and a fifth is refused by the service rather than
  dropped. The panel caps it where somebody can still un-stage one.
- **Attachment URLs expire after thirty minutes.** Do not cache them; re-reading
  the window mints fresh ones, which is what the poll already does.

## Colours, type and words

All of it is configuration, not code. Your colours, team name, avatar and
translations come down in the identify response and are set in the console —
restyle the thread there and nothing in your app changes. Testers pick it up at
their next handshake.

**The panel already speaks four languages before you configure anything:** Czech,
Slovak, German and — for whoever asks for it by name — Huttese. Pass your own
app's idea of what language it is in, rather than leaving it to the phone:

```swift
try await channel.identify(userId: id, userHash: hash, locale: "cs-CZ")
channel.setLocale("de")   // if your app has its own language switch
```

`locale` is your claim about this session, not the device's preference — an app
with a language switch has already answered the question, and a thread that
disagrees with the screen it sits in is the failure this avoids. Anything you or
the console have not translated falls back to English, key by key, so half a
translation is half a translation rather than a broken panel.

A CSS font stack means nothing to UIKit, so `fontFamily` is read as a list and
the first family the device actually has wins; otherwise it is the system face.

Override any single word without taking on the rest — this layer wins over both
the console and the shipped packs, because it is the one nearest your own code:

```swift
channel.stringOverrides = ["composer": "Tell us what broke…"]
```

## What is not here

**Push.** There is no device-token endpoint and no APNs delivery yet, so a tester
learns about a broadcast when they next open your app. Nothing in your
integration has to change when it arrives — it will be an additional call, not a
different one — but plan the first version around a thread people open rather
than a notification that taps them on the shoulder.

**Anything that names us.** The panel wears your name and your colours, and a
tester should experience it as part of the app they were already using.
