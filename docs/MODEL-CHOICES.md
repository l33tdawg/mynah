# Which model Mynah picks, and why

The owner picks a **provider**. Mynah offers **two models**, and defaults to the
quick one.

This file is the reasoning behind those picks. Model names age out within
months — three of ours already have, see *Stale names found* below — so the
reasoning is written down here rather than left as a string constant with no
explanation next to it.

## Why the owner does not pick out of a catalogue

A model name is not a choice a person can make well. It is a lookup against a
catalogue that changes without notice, in a vocabulary the owner has no reason
to have learned, where a wrong answer does not fail loudly — it fails as an
appliance that takes a question and never answers. The owner who types a model
name a year from now is not making a mistake anybody could have warned them
about at the moment they made it.

What the owner does know, and can be asked, is who they hold an account with.
That is the whole of what setup asks.

## Why they still get a choice of two

For a while this file said the owner picked nothing at all, and the settings
screen offered no button. That went one step too far. It reasoned from *"they
cannot rank nine ids by benchmark"* — true — to *"they cannot want a slower,
better answer"*, which does not follow. Quick or careful is a judgement about
the question in front of them, and they are the only one who can make it.

So each provider offers exactly two: **Quick**, the default, and **Careful**.
The same two everywhere, in the owner's words rather than the vendor's — "flash",
"turbo", "instant" and "sol" all mean the same thing to four different companies
and nothing at all to the person choosing.

Two, not three. `gpt-5.6-terra` sits between OpenAI's pair at $2/$12 and is left
out on purpose: a middle option is the one the owner has no basis to choose.

**The pair is enforced by the type.** `CloudBrainModelCatalog.Pick` has no
single-model initialiser, so a provider cannot be added with one tier and
quietly offer half of what every other provider offers. The previous table held
one id per provider and grew a second tier nowhere — a table that merely *ought*
to stay uniform is the same class of promise as the comment that started this
file.

## What gets offered

**Offer what we have measured. Omit what we have not.**

Not a flat catalogue of everything that could work, and not a curation based on
*"providers a non-technical owner has plausibly heard of"* — that earlier rule
encoded an assumption about who the owner is, produced a US-shaped list, and was
self-fulfilling, because you cannot choose a provider you are never shown.

The replacement curates on evidence we can gather rather than on taste. A voice
appliance whose picker offers a brain it then refuses to call through is the
picker and the caller disagreeing about what the product is.

## What "the right model" means here

This is an appliance you talk to. In that order:

1. **It has to hold a conversation at conversational speed.** A reply that
   arrives after twenty seconds is not a reply, it is a timeout with text
   attached. This rules out the top of every vendor's range regardless of how
   much better it reasons.
2. **It has to route tools correctly.** Mynah's answers come from SAGE — its
   memory, its tasks, its agents. A model that talks fluently and never calls a
   tool is worse than one that refuses, because it will confidently answer from
   nothing. This is the property that fails silently and therefore the one worth
   testing.
3. **Then, and only then, cheapest.** The owner pays per token for a device that
   sits there all day. Cost is a real constraint, but it is the tiebreak.

(1) and (3) point the same way; (2) does not. Cheap fast models are exactly
where tool routing gets unreliable, so (2) has to be checked rather than assumed.

## What "measured" has to mean

**Not a vibe and not a vendor claim.** Time to first token and time to a
complete short answer, on the owner's machine, against the same prompt — the
thing that decides whether a call works.

This is worth stating plainly because vendor speed figures are seductive and
several appear in the notes below. Groq publishes 560 tokens/sec for
`llama-3.1-8b-instant`. That number is a reason to *go and measure*; it is not a
measurement, and it is not what this table records.

## The picks

| Provider | Quick (default) | Careful | Offered in setup | Grounded |
|---|---|---|---|---|
| Anthropic | `claude-haiku-4-5` | `claude-sonnet-5` | **yes** — in use and known | 2026-08-01 |
| OpenAI | `gpt-5.6-luna` | `gpt-5.6-sol` | **yes** — in use and known | 2026-08-01 |
| DeepSeek | `deepseek-v4-flash` | `deepseek-v4-pro` | **yes** — owner's own evidence | 2026-08-01 |
| Groq | `llama-3.1-8b-instant` | `llama-3.3-70b-versatile` | no — unmeasured | 2026-08-01 |
| Kimi (Moonshot) | `kimi-k2.6` | `kimi-k3` | no — unmeasured | 2026-08-01 |
| Gemini (Google) | `gemini-3.6-flash` | `gemini-2.5-pro` | no — legacy resolution only | 2026-08-01 |
| GLM (Zhipu) | *not confirmed on our endpoint* | — | no | 2026-07-29 |

**Grounded** means both ids were read off the vendor's own current documentation
on the date shown, not recalled. **Offered** is a separate question and a higher
bar: naming a model is not measuring it.

### Anthropic — `claude-haiku-4-5` / `claude-sonnet-5`

$1/$5 per million tokens against $3/$15, both with full tool use. 200K context,
far more than a spoken conversation reaches. The quick one is the cheapest thing
in the range that meets (1) and (2), which is the rule applied exactly.

### OpenAI — `gpt-5.6-luna` / `gpt-5.6-sol`

$0.20/$1.20 against $5/$30 — the cost-optimised and frontier ends of one family,
both with function calling. `gpt-5.6-terra` at $2/$12 is the middle option left
out for the reason given above.

*(An earlier revision of this file put luna at $1/$6 and terra at $2.50/$15,
recalled rather than read. Corrected against the vendor's page on 2026-08-01 —
which is the whole argument for the "Grounded" column existing.)*

### DeepSeek — `deepseek-v4-flash` / `deepseek-v4-pro`

$0.14/$0.28 per million on a cache miss against $0.435/$0.87 — an order of
magnitude below everything else here at both ends. 1M context, 384K output.
Offered on the owner's direct evidence: he uses it and reports it fast. That
counts, and it is better evidence than a spec sheet.

The legacy aliases `deepseek-chat` and `deepseek-reasoner` were **discontinued
on 2026-07-24**. Neither may come back; a test asserts it.

### Gemini — `gemini-3.6-flash` / `gemini-2.5-pro`, and why that looks wrong

**There is no `gemini-3.6-pro`.** The naming convention every other provider here
follows does not hold for Google: the 3.6 family ships Flash, and the newest Pro
is `gemini-3.1-pro-preview`. A preview id has no business in a shipped
appliance — previews get withdrawn without a deprecation window — so the careful
tier is the current stable `gemini-2.5-pro`, deliberately an older family than
its own quick tier.

This is the pick most likely to be "tidied up" by someone who notices the
mismatch. Doing so produces a 404 on the owner's key. Recorded here and asserted
in `CloudBrainModelCatalogTests` for that reason.

### Kimi (Moonshot) — `kimi-k2.6` / `kimi-k3`

`kimi-k3` is the flagship at $3/$15 with a 1M context and documented tool calls.
The quick tier is **not** the faster-sounding `kimi-k2.7-code-highspeed`: that is
a coding specialist, and this is something you hold a conversation with — the
right speed and the wrong shape. `kimi-k2.6` is the general-purpose model.

This replaces `kimi-k2-0905-preview`, which Moonshot had already deprecated and
which this repo was still carrying.

### Groq — `llama-3.1-8b-instant`, named but not offered

Groq's whole proposition is speed and the published figure is 560 tokens/sec,
with tool use explicitly supported. It would be easy to wave this through on
that basis. It stays out because a vendor's tokens/sec is not the measurement
this table requires, and expecting is what this project has repeatedly been
wrong about. **This is the row most likely to move**, and moving it is one
measurement's work, not an implementation's.

### Kimi and GLM — not settled

**Kimi:** settled on 2026-08-01, see above. Named, still not measured, still not
offered in setup.

**GLM — and it is now costing something.** GLM used to be *offered in setup*
with this row blank, which meant an owner could read the instructions, open the
Zhipu console, put credit on a card, paste a working key, and be refused —
because `BrainFactory.defaultModelName` fell through to its `?? "local-model"`
and asked Zhipu for a model by that name. The planner now refuses to offer a
provider it has no pick for, so GLM is absent from the menu until this row is
filled.

**That is an unfinished job, not a decision.** It is not the US-bias problem the
offer list was rewritten to fix: that was about hiding providers that *worked*.
Bringing GLM back needs exactly one thing — a `glm-*` id verified against
`open.bigmodel.cn/api/paas/v4`, ideally two so it can carry a Quick and a
Careful tier like everything else. `glm-5` is confirmed on that endpoint with
function calling (2026-08-01) but is documented as reachable through the GLM
Coding Plan rather than plain pay-per-token, and no cheap tier has been
confirmed there at all. The vendor's pricing page renders in JavaScript and
returns nothing to fetch, so this wants an account and five minutes rather than
more reading.

Previously recorded here, still true and still not enough:
`GLM-5-Turbo` exists and is described as optimised for agent workflows
and tool use, at roughly $1.20/$4. But our backend talks to
`open.bigmodel.cn/api/paas/v4`, and the id confirmed above was on a third-party
router with its own namespace. **An id that is correct somewhere else is not a
grounded id here**, so the row stays blank.

A blank row is not an unfinished doc. It is the reason that provider is absent
from the picker, and it should be read that way.

## Which of them can see a photo

Vision is a **second, independent question** about the same ids, and it is asked
the same way: read it off the vendor's own current documentation, one id at a
time, and leave out anything nobody could confirm. The table lives in
`CloudBrainModelCatalog.sighted`.

**The two errors are not symmetric, and that decides the default.** Omitting a
model that can see costs one lost description and an honest sentence — *"saved,
and I have not looked at it"*. Including a model that cannot see ships a
confident description of a photo the model never received, because
`AttachmentArrivalNote` tells it *"You can see it — say what it is,
specifically"*. The owner cannot tell that apart from the appliance working.
So a model missing from the table reads as **blind**, there is no prefix
matching, and an unconfirmed id stays out.

Read on 2026-08-17:

| Model | Sees a photo | Source |
| --- | --- | --- |
| `claude-haiku-4-5` | yes | Anthropic's vision guide prices its image tokens by name |
| `claude-sonnet-5` | yes | documented as the first Sonnet-tier model with high-resolution image support |
| `gpt-5.6-luna` | yes | model page: *"Input modalities: text, image"* |
| `gpt-5.6-sol` | yes | model page: *"Input modalities: text, image"* |
| `kimi-k2.6` | yes | listed in Moonshot's own "Configure Kimi Vision Models" guide |
| `kimi-k3` | yes | same guide, with the base64 `image_url` example |
| `gemini-3.6-flash` | yes | Google's OpenAI-compatibility guide uses this id for its image example |
| `gemini-2.5-pro` | **not confirmed** | its model page does not state input modalities |
| `deepseek-v4-flash` | no | the chat-completions schema documents no image part |
| `deepseek-v4-pro` | no | same — the V4 family exposes no image input on the public API |
| `llama-3.1-8b-instant` | no | Groq lists no image modality; vision is the 3.2-vision and 4 families |
| `llama-3.3-70b-versatile` | no | same |

The Gemini row is the one to watch. Its **Quick** tier can see and its
**Careful** tier is treated as blind, which looks like an inconsistency and is
not: it is the difference between an id confirmed through the exact surface this
product speaks and an id nobody has confirmed at all. An owner who picks Careful
on Gemini and sends a photo is told plainly that it was kept and not looked at.
One reading of Google's model page fixes that; guessing would not.

Local models are a separate table (`LocalVisionModels`) because their ids carry
tags an exact match cannot enumerate, and it deliberately omits families whose
vision depends on the size tag — `gemma3:1b` is text-only and `gemma3:4b` is
not, so a family match would claim sight for the small one.

## Stale names found while doing this

Three model names already in the codebase have expired. Recording them because
they are the argument for this file existing:

| Name in repo | Status | Now |
|---|---|---|
| `kimi-k2-0905-preview` | **deprecated** by Moonshot | replaced by `kimi-k2.6` |
| `gpt-5` | superseded by the `gpt-5.6-*` family | gone |
| `llama-3.3-70b-versatile` | serves tools at 280 tok/s — half `llama-3.1-8b-instant` | kept, as Groq's *careful* tier |
| `deepseek-chat`, `deepseek-reasoner` | **discontinued 2026-07-24** | gone |

None of these caused a visible failure, because none is on a path an owner
reaches today. That is exactly how the next one will arrive too.

`llama-3.3-70b-versatile` is worth noting as the one that moved rather than
died: half the speed was disqualifying when there was one pick per provider and
that pick had to be fast. With two tiers it is exactly what the careful tier is
for. A stale name and a name in the wrong slot are different problems.

## What catches it when a name here goes stale

Two mechanisms, both running against the owner's own key rather than against a
measurement somebody took once:

- **`BrainKeyValidator` (`Setup/APIKeyOnboarding.swift`)** sends one real request
  carrying one real tool and checks the model actually called it. If it replies
  but ignores the tool, the verdict is `.unusable` and the owner is told so in
  the sheet, at the moment they paste the key — not hours later as silence.
  That is criterion (2), tested per owner, per provider, against the provider's
  catalogue as it is that day.

- **`BrainAvailability` via `OpenAICompatBackend.availability()`** lists
  `/v1/models` and reports `modelNotOffered(model:offered:)` when our pick is not
  in the account's catalogue — carrying what *was* offered, which is what turns
  the failure into something the next maintainer can act on.

When a vendor retires a name in this table, `Verdict.modelGone` fires at
selection time and says so plainly: *the key is fine, this build's model is
gone, this needs a Mynah update rather than anything from you.* No retry button,
because there is nothing for the owner to retry.

That check used to exist and return a bare `Bool`, so a retired model was
indistinguishable from a bad key, an expired card, and dropped Wi-Fi. That is
the failure this table is the first line of defence against and the validator is
the second.

## When you change a pick

Change the reasoning too. If a row says a model was chosen for speed and tool
routing and you swap it, the next person needs to know whether the old one was
withdrawn, was too slow, or stopped calling tools — three different next moves.

And if you cannot verify an id against **the endpoint we actually call**, leave
the row blank and say so. That is what the blanks above are.
