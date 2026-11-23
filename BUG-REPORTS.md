# Reporting a bug

Something broke, crashed, or showed a number that looks wrong? Tell us. You don't need a GitHub
account or any developer knowledge. This page covers where to send a report, what to put in it,
and how to get a crash log from your iPhone or iPad.

## Where to send it

Pick whichever is easiest for you. They all reach the same person.

| You have | Send it to |
|---|---|
| Discord | **[#bug-reports](https://discord.gg/hbpMZhPSdx)** on the Piru Discord. Start a new post with a short title ("crash when I open Journal"). The easiest option, and you can attach screenshots and files. |
| Piru from TestFlight on iPhone | **TestFlight feedback.** Take a screenshot in Piru and tap *Share Beta Feedback*, or open TestFlight → Piru → *Send Beta Feedback*. After a crash, iOS often asks whether to share it: say yes and add one line about what you were doing. |
| A GitHub account | **[A new issue](https://github.com/kageroumado/piru/issues/new/choose)** with the *Bug report* template. "Issue" is just GitHub's word for a bug report. |

Security or privacy problems (anything that could expose someone's journal) go privately, never
in public: see [SECURITY.md](SECURITY.md).

## What to write

Four things make a report fixable:

1. **What you did**, step by step: "Opened Settings → Your Body, deleted the weight, the app closed."
2. **What happened**, and what you expected instead.
3. **When** it happened (the time, roughly). Crash logs are stamped with the time, so this is how a
   report is matched to its log.
4. **Your device**: model, iOS, iPadOS, or watchOS version, and Piru's version (Settings → About).

Screenshots and screen recordings help a lot. For a wrong curve, dose or timer, also share the
session: open it and tap **Share → Markdown**, then paste the result. It shows exactly what you
logged and what Piru calculated. Remove anything you'd rather keep to yourself.

## Crash logs on iPhone and iPad

- **TestFlight users**: share the crash when TestFlight offers to; that sends the log for you.
- **Otherwise**: Settings → Privacy & Security → Analytics & Improvements → **Analytics Data**.
  Find entries starting with `Piru` and dated around the crash, open one, tap the share button,
  and attach it to your report. (This list only fills if *Share iPhone Analytics* is on.)
