# Publishing the site

`docs/index.html` is the public page for Mynah. This is how it becomes a live URL, and how
you take the screenshots that go on it without publishing the owner's life.

The page is deliberately self-contained: the stylesheet is inline, the wordmark is an inline
`<svg>`, and the file contains no `href` at all — not an external one, and not an in-page
anchor. Nothing is fetched from anywhere. Its own footer makes that a claim to the reader —
*"This page loads nothing from anywhere — no fonts, no scripts, no analytics"* — so anything
you add later, screenshots included, has to be committed under `docs/` and referenced by a
relative path. The moment one asset is hotlinked, the footer is a lie.

## Before you touch Settings: the repository is private

`gh repo view l33tdawg/sage-voice-bridge --json isPrivate` currently answers `true`.

GitHub Pages on a private repository requires a paid plan on the account that owns it. If the
Pages settings panel tells you to upgrade, you have two honest options, and they are a decision
rather than a step: make the repository public, or upgrade the account. Do not assume which one
the owner wants.

Also worth being clear with yourself before enabling it: publishing a Pages site makes the
built output **publicly readable on the internet**, whether or not the repository stays private.
Everything in `docs/` is served, not just `index.html` — `RELEASE.md` and `MODEL-CHOICES.md`
included. Read them before you publish and decide whether they should be there.

## Settings → Pages

1. Open <https://github.com/l33tdawg/sage-voice-bridge/settings/pages>. That URL goes straight
   to the panel and skips the sidebar entirely.
   If you would rather navigate: repository → **Settings** tab → find **Pages** in the left
   sidebar. It has lived under a "Code and automation" grouping for a while, but the groupings
   get reshuffled — look for the entry named *Pages* rather than counting positions.
2. Under **Build and deployment**, set **Source** to **Deploy from a branch**.
   (The other choice is *GitHub Actions*. Do not pick it. It expects a workflow that uploads a
   Pages artifact, and this repository has exactly one workflow, `.github/workflows/release.yml`,
   which is tag-driven and builds the DMG. It has nothing to do with this site.)
3. A **Branch** row appears once *Deploy from a branch* is selected. Set the branch dropdown to
   **`main`** and the folder dropdown next to it to **`/docs`**.
4. Press **Save**. Nothing happens until you do; the folder dropdown does not autosave.

`main` is the repository's default branch, so this publishes what is on `main` — not whatever
branch you happen to have checked out. `docs/` already differs between `main` and the other
branch in this repository — on `sage-11.16.1-activation-countdown`, `index.html` and
`MODEL-CHOICES.md` are not the same file and this one does not exist at all. Merge first, then
expect the site to change.

## The URL

```
https://l33tdawg.github.io/sage-voice-bridge/
```

That is a project site, so the repository name is part of the path and the trailing slash
matters. Any link you ever add inside `index.html` to another file in `docs/` must be relative
(`RELEASE.md`, not `/RELEASE.md`) — a leading slash resolves to `l33tdawg.github.io/` and 404s.

## How long it takes

Saving the setting queues a build. You can watch it: the repository's **Actions** tab gets a
run named *pages build and deployment*, and the Pages settings panel itself changes to
*"Your site is live at …"* with a **Visit site** button when it finishes.

GitHub documents that a change can take **up to 10 minutes** to appear. Treat that as the
budget, not the expectation. If it is still not up after ten minutes, the build failed — open
the run in Actions and read it rather than reloading the URL hopefully.

## Verifying it is live

From any machine:

```sh
curl -sI https://l33tdawg.github.io/sage-voice-bridge/ | head -1
```

Expect `HTTP/2 200`. A `404` means the build has not landed yet, or the folder is set to
`/ (root)` instead of `/docs`.

Then confirm you are looking at *this* page and not a stale or generated one:

```sh
curl -s https://l33tdawg.github.io/sage-voice-bridge/ | grep -c '<title>Mynah'
```

Expect `1`. And confirm the page is still self-contained — this must print nothing at all:

```sh
curl -s https://l33tdawg.github.io/sage-voice-bridge/ | grep -oE '(src|href)="https?://[^"]*"'
```

The API tells you the same thing without a browser. It answers `404 Not Found` today, because
Pages has never been enabled on this repository:

```sh
gh api repos/l33tdawg/sage-voice-bridge/pages --jq '.status, .html_url, .source'
```

Once it is live, `status` reads `built` and `source` reports the branch and path you set.

One thing to decide on purpose: `index.html` carries no `robots` meta tag, so once Pages is
enabled the site is public **and** indexable. If it is meant to be unlisted, add
`<meta name="robots" content="noindex">` to the `<head>` before you publish.

### Updating it later

Push to `main`. Pages rebuilds on every push to the configured branch — there is no second
button and no release to cut. The DMG release workflow and this site are independent.

## Do you need `.nojekyll`?

**Yes — keep it.** `docs/.nojekyll` already exists, is zero bytes, and is tracked (committed in
`e525227`). Do not delete it, and do not "clean it up" as an empty file.

The honest detail, because "keep it" without a reason gets undone by the next person:

- `index.html` would survive without it. Jekyll only runs Liquid over files that have YAML front
  matter; this one starts at `<!doctype html>` and contains no `{{` or `{%` anywhere, so Jekyll
  would copy it through byte for byte.
- What `.nojekyll` actually changes here is the rest of the folder. Without it, Jekyll converts
  `docs/*.md` into HTML pages — `MODEL-CHOICES.md` would be served at `/MODEL-CHOICES.html` and
  the `.md` URL would 404. With it, every file is served exactly as committed.
- And it is insurance for the screenshots. Jekyll silently excludes anything whose name begins
  with `_` or `.`. There is nothing underscore-prefixed in `docs/` today, but an image folder
  someone names `_shots/` would vanish from the built site with no error anywhere. `.nojekyll`
  makes that class of failure impossible instead of merely unlikely.

## Screenshots

`index.html` currently references **no images at all** — there is not a single `<img>` in it.
Adding screenshots therefore means committing the files under `docs/` and writing the `<img>`
tags yourself. Give every one a real `alt` describing what the screen shows, and explicit
`width`/`height` so the page does not reflow as they load.

### Which screens

The sidebar has four destinations, defined in `MainSection` in
`Sources/MynahMac/RootView.swift`. Capture them in sidebar order:

| Screen | What it is for | Why it is on the site |
| --- | --- | --- |
| **Home** | "What's on your plate" | The conversation and the task list in one window |
| **Memories** | "What Mynah remembers" | The thing the page's first paragraph promises |
| **Privacy** | "What leaves this Mac" | The page's whole argument, shown rather than asserted |
| **Settings** | "How Mynah is set up" | Where the model choice actually lives |

If you want a fifth, take the onboarding brain picker (`Sources/MynahMac/Setup/BrainPickerView.swift`) —
it is the screen where the owner chooses between a model on the Mac and an API key — the
decision that determines whether the thinking leaves the machine. It is not the only thing that
leaves: web search, the call relay and the update check are on the list too.

### Window size

The app opens at **1180 × 820** points (`.defaultSize(width: 1180, height: 820)`,
`Sources/MynahMac/MynahApp.swift`). Use that. It is what the layout was designed against, and
it is what the owner sees on first launch.

The window will not go below **980 × 640** (`RootView`'s `.frame(minWidth: 980, minHeight: 640)`),
so anything narrower is not a screenshot of this app.

Capture the window, not the screen:

```sh
screencapture -o -w ~/Desktop/mynah-home.png
```

`-w` waits for you to click the window; `-o` omits the drop shadow, which otherwise bakes a huge
transparent margin into the file and makes the image look mis-sized on the page. On a Retina Mac
this writes 2360 × 1640 pixels for an 1180 × 820 window — that is correct, keep it, and set the
displayed size in the `<img>` tags.

### The warning that matters more than any of the above

**Never publish a screenshot taken from the owner's running instance.**

Home and Memories are not mock-ups. They read the live SAGE node on this Mac, and what is in
them is the owner's own material: what he asked Mynah to remember, his task list, travel plans,
and research he has not published. The Signal linking screen puts his phone number on screen.
A screenshot of any of those is a disclosure, and it is permanent the moment it is pushed —
deleting the file later does not delete it from the repository's history or from anyone's cache.

Take them with demo content instead. The fixtures already exist in the repository, and they
exist precisely for this — `TalkPreview` in `Sources/MynahMac/Main/TalkView.swift` says so in as
many words: *"a preview must not open the developer's own saved conversation and draw it in a
screenshot."*

- **Memories** — `PreviewMemoryStore.sample` in `Sources/MynahMac/Main/MemoriesView.swift`.
  Three invented memories across two subjects, one at each certainty level.
- **Home** — `TalkPreviewFixtures.plate()` and `TalkPreviewFixtures.earlierConversation()` in
  `Sources/MynahMac/Main/TalkView.swift`.
- **Privacy** and **Settings** — `#Preview("Privacy — an API brain")` and the five
  `#Preview("Settings — …")` blocks. These render claim text and a model name rather than
  personal content, but read what is on screen before you shoot: Settings can show a linked
  phone number and a real model name.

Render those previews in Xcode's canvas and capture from there. Two things to watch:

1. Several previews draw **light and dark side by side** — `MemoriesPreviewPair` at 1500 × 760,
   `TalkPreview` at 1180 × 760. That is a pair, not a window. Crop to one side, or capture each
   scheme separately, before you claim it is a picture of the app.
2. A preview is not the window chrome. If you want the traffic lights and the toolbar, you need
   the real app — in which case run it against a scratch configuration with demo content, not the
   owner's live one. See the memory note about isolating any node experiment on this Mac.

One related trap, now fixed but worth knowing: opening *"Change where your words go"* to
photograph the provider list used to tear down both LaunchAgents and take the owner's phone
bridge with it. `AnsweringIntent` in `Sources/MynahMac/MynahApp.swift` now returns `cannotTell`
while setup is in progress, which changes nothing, so browsing the picker is safe. Finishing
setup is still a real decision that reconciles the running service.

### What must never appear in a committed image

Check every file before `git add`, at full size, not as a thumbnail:

- phone numbers, in the Signal linking screen or anywhere else
- real memories, notes, backlog items or tasks
- travel plans, purchases, or anything from the owner's own research
- API keys, even partially masked ones
- agent names and node addresses from the live SAGE node
