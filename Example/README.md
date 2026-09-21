# TesterChannelDemo

A host app with the 1000 Fans panel in it, for trying the iOS client on a
simulator. It talks to a fake service inside the app (`FakeService.swift`), so
it needs no server, database, network or signing.

## Run it

1. Open `sdk/ios/Example/TesterChannelDemo.xcodeproj` in Xcode.
2. Choose any iPhone simulator as the run destination.
3. Press **⌘R**.

The project uses the SDK straight from `sdk/ios` as a local package, so an edit
to the SDK is in the next run with nothing to update.

From a terminal:

```bash
cd sdk/ios/Example
xcodebuild -project TesterChannelDemo.xcodeproj -scheme TesterChannelDemo \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

## What is in it

- **Feedback tab:** the panel, in a thread of 80 messages, 30 of them loaded.
  The messages are numbered, so you can see where you are.
- **App tab:** stands in for the rest of the host app. While it is showing, the
  panel is hidden and the client polls only the unread count. That is the case
  the tab badge is for.
- **Director** (the masks button, top right): plays the operator and changes the
  tester's circumstances:
  - Operator sends: a message, five messages two seconds apart, a poll, a
    multi-select poll, a test request, a card type this build doesn't know, or
    a system notice.
  - Tester: go offline, be removed from the programme (takes effect on the next
    send), be asked for their name again, change language.
  - Reset demo.

The client polls every 2 seconds here (the SDK's default is 4), so anything the
Director sends appears within 2 seconds.

## Checks worth making

| Do this | Expect |
|---|---|
| Open the Feedback tab | The thread opens at the newest message |
| Scroll up, then Director → 5 messages | You stay where you are |
| Stay at the bottom, then Director → a message | The thread follows it down |
| Scroll up, type something, press Send | The thread follows your message down |
| Tap Load older messages | Older messages appear above; the one you were reading stays in view |
| Director → a poll, answer it | The card collapses to your choice; your answer appears below |
| Director → Offline, send something | It shows "Not sent yet — will retry"; it sends when you go back online |
| Director → Removed, then send | The composer is replaced by the removal notice |

## What it does not prove

The fake copies the service's routes and JSON from `src/routes/client.ts`. It
tests the client, not the service. If the two ever disagree, the service is
right and the fake is out of date.
